#!/usr/bin/env bash

set -Eeuo pipefail

# Locate pixi.toml independently of the caller's current directory.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(dirname -- "$SCRIPT_DIR")
PIXI_MANIFEST=$PROJECT_ROOT/pixi.toml

# Output paths remain relative to the caller's current directory.
PROGRAM_NAME=${0##*/}
DEFAULT_OUTDIR=data/simulated
DEFAULT_SEED=42

REFERENCE=
CONFIG=
OUTDIR=$DEFAULT_OUTDIR
SEED=$DEFAULT_SEED
WORK_DIR=

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME --reference REF.fa --config CONFIG.yaml [options]

Create a realized inSVert truth VCF and a simulated polyploid FASTA.

Required arguments:
  --reference PATH      Indexed reference FASTA
  --config PATH         inSVert simulation configuration

Optional arguments:
  --seed INTEGER        Variant-simulation seed (default: $DEFAULT_SEED)
  -o, --outdir PATH     Output directory (default: $DEFAULT_OUTDIR)
  -h, --help            Show this help and exit

Outputs:
  OUTDIR/truth.vcf
  OUTDIR/simulated.fa
EOF
}

fail() {
    printf 'Error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

cleanup() {
    # inSVert may create sorted/indexed copies beside its input VCF.
    # Keeping all intermediates here lets us remove them in one step.
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

while (($#)); do
    case "$1" in
        --reference)
            (($# >= 2)) || fail "--reference requires a path"
            REFERENCE=$2
            shift 2
            ;;
        --config)
            (($# >= 2)) || fail "--config requires a path"
            CONFIG=$2
            shift 2
            ;;
        --seed)
            (($# >= 2)) || fail "--seed requires an integer"
            SEED=$2
            shift 2
            ;;
        -o|--outdir)
            (($# >= 2)) || fail "$1 requires a path"
            OUTDIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ -n $REFERENCE ]] || fail "--reference is required"
[[ -n $CONFIG ]] || fail "--config is required"
[[ -r $REFERENCE && -s $REFERENCE ]] || fail "reference is not readable: $REFERENCE"
[[ -r $CONFIG && -s $CONFIG ]] || fail "config is not readable: $CONFIG"
[[ $SEED =~ ^-?[0-9]+$ ]] || fail "--seed must be an integer"

command -v pixi >/dev/null 2>&1 || fail "pixi is not available on PATH"
[[ -r $PIXI_MANIFEST ]] || fail "Pixi manifest is not readable: $PIXI_MANIFEST"

# Every environment-provided command goes through the repository's Pixi
# manifest, so the script uses the locked tool versions without activation.
PIXI_RUN=(pixi run --locked --manifest-path "$PIXI_MANIFEST")

# Read ploidy from the same config used for simulation so insert cannot drift
# from the genotype width produced by simulate.
PLOIDY=$("${PIXI_RUN[@]}" python - "$CONFIG" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    config = yaml.safe_load(stream)

try:
    ploidy = config["genome"]["ploidy"]
except (KeyError, TypeError):
    raise SystemExit("config must define genome.ploidy")

if isinstance(ploidy, bool) or not isinstance(ploidy, int) or ploidy < 1:
    raise SystemExit("genome.ploidy must be a positive integer")

print(ploidy)
PY
) || fail "could not read ploidy from config"

mkdir -p -- "$OUTDIR"
[[ ! -e $OUTDIR/truth.vcf ]] || fail "output already exists: $OUTDIR/truth.vcf"
[[ ! -e $OUTDIR/simulated.fa ]] || fail "output already exists: $OUTDIR/simulated.fa"

# Use the output filesystem for temporary files, avoiding a large cross-device
# copy when the combined triploid FASTA is moved into its final location.
WORK_DIR=$(mktemp -d "$OUTDIR/.simulate-genome.XXXXXX")

# This VCF contains requested variants; some may later fail during insertion.
printf 'Simulating variants (seed=%s, ploidy=%s)\n' "$SEED" "$PLOIDY"
"${PIXI_RUN[@]}" inSVert simulate "$CONFIG" "$REFERENCE" \
    --seed "$SEED" \
    -o "$WORK_DIR/requested.vcf"

# --truth-vcf records only variants successfully applied to the FASTA, making
# it the appropriate ground truth for downstream caller evaluation.
printf 'Inserting variants and recording realized truth\n'
"${PIXI_RUN[@]}" inSVert insert "$REFERENCE" "$WORK_DIR/requested.vcf" \
    --ploidy "$PLOIDY" \
    --truth-vcf "$WORK_DIR/truth.vcf" \
    -o "$WORK_DIR/simulated.fa"

[[ -s $WORK_DIR/truth.vcf ]] || fail "inSVert did not create truth.vcf"
[[ -s $WORK_DIR/simulated.fa ]] || fail "inSVert did not create simulated.fa"

# Publish final artifacts only after both inSVert stages complete successfully.
mv -- "$WORK_DIR/truth.vcf" "$OUTDIR/truth.vcf"
mv -- "$WORK_DIR/simulated.fa" "$OUTDIR/simulated.fa"

printf 'Created %s and %s\n' "$OUTDIR/truth.vcf" "$OUTDIR/simulated.fa"
