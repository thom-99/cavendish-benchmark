#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM_NAME=${0##*/}
DEFAULT_COVERAGE=30
DEFAULT_TECHNOLOGY=ont
DEFAULT_SEED=123
DEFAULT_THREADS=8
DEFAULT_OUTDIR=simulated_data

REF=
CONFIG=
PLOIDY=
COVERAGE=$DEFAULT_COVERAGE
TECHNOLOGY=$DEFAULT_TECHNOLOGY
SEED=$DEFAULT_SEED
THREADS=$DEFAULT_THREADS
OUTDIR=$DEFAULT_OUTDIR

PIPELINE_LOG=
COMMANDS_FILE=
TMP_DIR=
COMPLETED=0
START_TIME=$SECONDS

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME --ref REF.fa --config CONFIG.yaml --ploidy N [options]

Simulate structural variants with inSVert, generate ONT reads with Badread,
and align the reads to the original reference.

Required arguments:
  --ref PATH             Uncompressed .fa or .fasta haploid reference
  --config PATH          inSVert YAML configuration
  --ploidy N             Number of edited genome copies

Optional arguments:
  --coverage FLOAT       Aggregate coverage across all copies (default: $DEFAULT_COVERAGE)
  --technology NAME      ont, hifi, or clr; only ont is currently validated
                         (default: $DEFAULT_TECHNOLOGY)
  --seed INTEGER         Simulation and read-generation seed (default: $DEFAULT_SEED)
  --threads N            Approximate shared mapping/sorting budget (default: $DEFAULT_THREADS)
  -o, --outdir PATH      Empty or nonexistent output directory
                         (default: $DEFAULT_OUTDIR)
  -h, --help             Show this help and exit
EOF
}

argument_error() {
    printf 'Error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

while (($#)); do
    case "$1" in
        --ref)
            (($# >= 2)) || argument_error "--ref requires a path"
            REF=$2
            shift 2
            ;;
        --config)
            (($# >= 2)) || argument_error "--config requires a path"
            CONFIG=$2
            shift 2
            ;;
        --ploidy)
            (($# >= 2)) || argument_error "--ploidy requires an integer"
            PLOIDY=$2
            shift 2
            ;;
        --coverage)
            (($# >= 2)) || argument_error "--coverage requires a number"
            COVERAGE=$2
            shift 2
            ;;
        --technology)
            (($# >= 2)) || argument_error "--technology requires a name"
            TECHNOLOGY=$2
            shift 2
            ;;
        --seed)
            (($# >= 2)) || argument_error "--seed requires an integer"
            SEED=$2
            shift 2
            ;;
        --threads)
            (($# >= 2)) || argument_error "--threads requires an integer"
            THREADS=$2
            shift 2
            ;;
        -o|--outdir)
            (($# >= 2)) || argument_error "$1 requires a path"
            OUTDIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            (($# == 0)) || argument_error "unexpected positional arguments: $*"
            ;;
        -* )
            argument_error "unknown option: $1"
            ;;
        *)
            argument_error "unexpected positional argument: $1"
            ;;
    esac
done

[[ -n $REF ]] || argument_error "--ref is required"
[[ -n $CONFIG ]] || argument_error "--config is required"
[[ -n $PLOIDY ]] || argument_error "--ploidy is required"
[[ $PLOIDY =~ ^[1-9][0-9]*$ ]] || argument_error "--ploidy must be a positive integer"
[[ $THREADS =~ ^[1-9][0-9]*$ ]] || argument_error "--threads must be a positive integer"
[[ $SEED =~ ^-?[0-9]+$ ]] || argument_error "--seed must be an integer"
[[ $COVERAGE =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] \
    || argument_error "--coverage must be a positive number"
case "$TECHNOLOGY" in
    ont|hifi|clr) ;;
    *) argument_error "--technology must be one of: ont, hifi, clr" ;;
esac

[[ -f $REF && -r $REF && -s $REF ]] || argument_error "reference is not a readable, nonempty file: $REF"
[[ -f $CONFIG && -r $CONFIG && -s $CONFIG ]] || argument_error "config is not a readable, nonempty file: $CONFIG"
case "$REF" in
    *.fa|*.fasta) ;;
    *) argument_error "reference must be uncompressed and end in .fa or .fasta" ;;
esac

command -v realpath >/dev/null 2>&1 || argument_error "required utility not found: realpath"
REF=$(realpath -- "$REF")
CONFIG=$(realpath -- "$CONFIG")
OUTDIR=$(realpath -m -- "$OUTDIR")

case "$REF" in
    "$OUTDIR"/*) argument_error "output directory must not contain the reference input" ;;
esac
case "$CONFIG" in
    "$OUTDIR"/*) argument_error "output directory must not contain the config input" ;;
esac

if [[ -e $OUTDIR && ! -d $OUTDIR ]]; then
    argument_error "output path exists and is not a directory: $OUTDIR"
fi
if [[ -d $OUTDIR ]]; then
    shopt -s nullglob dotglob
    existing_entries=("$OUTDIR"/*)
    shopt -u nullglob dotglob
    ((${#existing_entries[@]} == 0)) \
        || argument_error "output directory is not empty: $OUTDIR"
fi

mkdir -p -- "$OUTDIR"/{run,logs,tmp,simulation,reads,alignment}
PIPELINE_LOG=$OUTDIR/logs/pipeline.log
COMMANDS_FILE=$OUTDIR/run/commands.sh
TMP_DIR=$OUTDIR/tmp
: > "$PIPELINE_LOG"
: > "$COMMANDS_FILE"

timestamp() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

log() {
    printf '[%s] %s\n' "$(timestamp)" "$*" | tee -a "$PIPELINE_LOG"
}

on_exit() {
    local exit_code=$?
    if ((exit_code != 0)); then
        log "Pipeline failed with exit code $exit_code; scratch retained at $TMP_DIR"
    elif ((COMPLETED == 0)); then
        log "Pipeline stopped before completion; scratch retained at $TMP_DIR"
    fi
}
trap on_exit EXIT

record_command() {
    local argument
    for argument in "$@"; do
        printf '%q ' "$argument" >> "$COMMANDS_FILE"
    done
    printf '\n' >> "$COMMANDS_FILE"
}

record_pipeline() {
    printf '%s\n' "$1" >> "$COMMANDS_FILE"
}

run_stage() {
    local number=$1
    local name=$2
    local function_name=$3
    local stage_log=$4
    local failure_code=$5
    local stage_status
    local stage_start=$SECONDS

    log "Stage $number: $name (details: $stage_log)"
    set +e
    (set -Eeuo pipefail; "$function_name") >> "$stage_log" 2>&1
    stage_status=$?
    set -e

    if ((stage_status == 0)); then
        log "Stage $number complete in $((SECONDS - stage_start))s"
        return 0
    fi

    log "Stage $number failed after $((SECONDS - stage_start))s (details: $stage_log)"
    exit "$failure_code"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        return 1
    }
}

read_config_ploidy() {
    python3 - "$CONFIG" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as config_file:
    config = yaml.safe_load(config_file)

try:
    ploidy = config["genome"]["ploidy"]
except (KeyError, TypeError):
    raise SystemExit("config must define genome.ploidy")

if isinstance(ploidy, bool) or not isinstance(ploidy, int) or ploidy < 1:
    raise SystemExit("config genome.ploidy must be a positive integer")

print(ploidy)
PY
}

capture_version() {
    local label=$1
    shift
    local version_output
    version_output=$("$@" 2>&1 || true)
    printf '## %s\n%s\n\n' "$label" "$version_output"
}

stage_preflight() {
    local dependency
    local config_ploidy
    local reference_bases
    local target_bases

    for dependency in python3 inSVert badread minimap2 samtools bcftools gzip \
        sha256sum awk tee date cp ln mv rm; do
        require_command "$dependency"
    done
    python3 -c 'import yaml' >/dev/null

    [[ $TECHNOLOGY == ont ]] || {
        printf '%s simulation is not validated: Badread 0.4.2 is configured here only for ONT\n' \
            "$TECHNOLOGY" >&2
        return 1
    }
    awk -v coverage="$COVERAGE" 'BEGIN { exit !(coverage > 0) }' \
        || { printf '%s\n' '--coverage must be greater than zero' >&2; return 1; }

    config_ploidy=$(read_config_ploidy)
    [[ $config_ploidy == "$PLOIDY" ]] || {
        printf 'Ploidy mismatch: --ploidy=%s but config genome.ploidy=%s\n' \
            "$PLOIDY" "$config_ploidy" >&2
        return 1
    }

    cp -- "$CONFIG" "$OUTDIR/run/config.yaml"
    ln -s -- "$REF" "$OUTDIR/run/reference.fa"
    record_command samtools faidx "$OUTDIR/run/reference.fa"
    samtools faidx "$OUTDIR/run/reference.fa"
    [[ -s $OUTDIR/run/reference.fa.fai ]]

    reference_bases=$(awk '{ total += $2 } END { printf "%.0f", total }' \
        "$OUTDIR/run/reference.fa.fai")
    [[ $reference_bases =~ ^[1-9][0-9]*$ ]] || {
        printf '%s\n' 'Reference contains no sequence bases' >&2
        return 1
    }
    target_bases=$(awk -v bases="$reference_bases" -v coverage="$COVERAGE" \
        'BEGIN { printf "%d", (bases * coverage) + 0.5 }')
    [[ $target_bases =~ ^[1-9][0-9]*$ ]] || {
        printf '%s\n' 'Requested coverage rounds to zero read bases' >&2
        return 1
    }

    {
        printf 'parameter\tvalue\n'
        printf 'reference\t%s\n' "$REF"
        printf 'config\t%s\n' "$CONFIG"
        printf 'ploidy\t%s\n' "$PLOIDY"
        printf 'coverage\t%s\n' "$COVERAGE"
        printf 'technology\t%s\n' "$TECHNOLOGY"
        printf 'seed\t%s\n' "$SEED"
        printf 'threads\t%s\n' "$THREADS"
        printf 'reference_bases\t%s\n' "$reference_bases"
        printf 'requested_read_bases\t%s\n' "$target_bases"
        printf 'badread_error_model\tnanopore2023\n'
        printf 'badread_qscore_model\tnanopore2023\n'
        printf 'badread_identity\t20,3\n'
        printf 'badread_length\t15000,13000\n'
        printf 'badread_glitches\t10000,10,10\n'
        printf 'badread_junk_reads_percent\t0.1\n'
        printf 'badread_random_reads_percent\t0.1\n'
        printf 'badread_chimeras_percent\t0.1\n'
    } > "$OUTDIR/run/settings.tsv"

    record_command sha256sum "$REF" "$CONFIG"
    sha256sum "$REF" "$CONFIG" > "$OUTDIR/run/input_checksums.sha256"

    {
        capture_version Bash bash --version
        capture_version Python python3 --version
        capture_version PyYAML python3 -c 'import yaml; print(yaml.__version__)'
        capture_version inSVert inSVert --version
        capture_version Badread badread simulate --version
        capture_version minimap2 minimap2 --version
        capture_version samtools samtools --version
        capture_version bcftools bcftools --version
        capture_version gzip gzip --version
    } > "$OUTDIR/run/versions.txt"
}

stage_simulation() {
    local simulation_dir=$TMP_DIR/simulation
    local command

    mkdir -p -- "$simulation_dir"
    command=(
        inSVert simulate "$OUTDIR/run/config.yaml" "$OUTDIR/run/reference.fa"
        --seed "$SEED" -o "$simulation_dir/simulated.vcf"
    )
    record_command "${command[@]}"
    "${command[@]}"
    [[ -s $simulation_dir/simulated.vcf ]]
    bcftools view --header-only "$simulation_dir/simulated.vcf" >/dev/null
}

write_truth_metadata() {
    local truth_vcf=$1
    local output_tsv=$2
    local sample_count

    sample_count=$(bcftools query --list-samples "$truth_vcf" | awk 'END { print NR }')
    [[ $sample_count == 1 ]] || {
        printf 'Expected exactly one truth sample, found %s\n' "$sample_count" >&2
        return 1
    }

    printf 'truth_id\tevent_id\tmate_id\tchrom\tpos\tsvtype\tsize\tcarrier_dosage\n' \
        > "$output_tsv"
    bcftools query \
        --format '%CHROM\t%POS\t%ID\t%INFO/EVENT\t%INFO/MATEID\t%INFO/SVTYPE\t%INFO/SVLEN[\t%GT]\n' \
        "$truth_vcf" \
        | awk -F '\t' -v OFS='\t' -v ploidy="$PLOIDY" '
            BEGIN { failed = 0 }
            {
                chrom = $1
                pos = $2
                id = $3
                event = $4
                mate = $5
                svtype = $6
                size = $7
                gt = $8

                if (id == "" || id == ".") {
                    print "Truth record lacks a stable ID at " chrom ":" pos > "/dev/stderr"
                    failed = 1
                    next
                }
                if (seen[id]++) {
                    print "Duplicate truth record ID: " id > "/dev/stderr"
                    failed = 1
                    next
                }

                allele_count = split(gt, alleles, /[|\/]/)
                if (allele_count != ploidy) {
                    print "Truth genotype ploidy mismatch for " id ": " gt > "/dev/stderr"
                    failed = 1
                    next
                }
                dosage = 0
                for (allele_index = 1; allele_index <= allele_count; allele_index++) {
                    if (alleles[allele_index] != "0" && alleles[allele_index] != ".") {
                        dosage++
                    }
                }
                if (dosage < 1 || dosage > ploidy) {
                    print "Invalid carrier dosage for " id ": " gt > "/dev/stderr"
                    failed = 1
                    next
                }

                if (event == "" || event == ".") event = id
                if (mate == "") mate = "."
                if (size ~ /^-/) size = -size
                if (size == "") size = "."
                print id, event, mate, chrom, pos, svtype, size, dosage
            }
            END { if (failed) exit 1 }
        ' >> "$output_tsv"
}

stage_insertion() {
    local simulation_dir=$TMP_DIR/simulation
    local final_dir=$OUTDIR/simulation
    local command

    command=(
        inSVert insert "$OUTDIR/run/reference.fa" "$simulation_dir/simulated.vcf"
        --ploidy "$PLOIDY" --sample-name simulated
        --truth-vcf "$simulation_dir/truth.raw.vcf"
        -o "$simulation_dir/mutated.fa"
    )
    record_command "${command[@]}"
    "${command[@]}"
    [[ -s $simulation_dir/mutated.fa ]]
    [[ -s $simulation_dir/truth.raw.vcf ]]

    record_command samtools faidx "$simulation_dir/mutated.fa"
    samtools faidx "$simulation_dir/mutated.fa"

    record_command bcftools sort "$simulation_dir/truth.raw.vcf" \
        --temp-dir "$simulation_dir/bcftools-sort" -Oz \
        -o "$simulation_dir/truth.vcf.gz"
    bcftools sort "$simulation_dir/truth.raw.vcf" \
        --temp-dir "$simulation_dir/bcftools-sort" -Oz \
        -o "$simulation_dir/truth.vcf.gz"
    record_command bcftools index --csi "$simulation_dir/truth.vcf.gz"
    bcftools index --csi "$simulation_dir/truth.vcf.gz"
    [[ $(bcftools index --nrecords "$simulation_dir/truth.vcf.gz") -gt 0 ]] || {
        printf '%s\n' 'No variants were successfully inserted; truth VCF is empty' >&2
        return 1
    }

    write_truth_metadata "$simulation_dir/truth.vcf.gz" \
        "$simulation_dir/truth_metadata.tsv"
    [[ $(awk 'END { print NR }' "$simulation_dir/truth_metadata.tsv") -gt 1 ]]

    mv -- "$simulation_dir/mutated.fa" "$final_dir/mutated.fa"
    mv -- "$simulation_dir/mutated.fa.fai" "$final_dir/mutated.fa.fai"
    mv -- "$simulation_dir/truth.vcf.gz" "$final_dir/truth.vcf.gz"
    mv -- "$simulation_dir/truth.vcf.gz.csi" "$final_dir/truth.vcf.gz.csi"
    mv -- "$simulation_dir/truth_metadata.tsv" "$final_dir/truth_metadata.tsv"
}

stage_read_generation() {
    local target_bases
    local reads_tmp=$TMP_DIR/reads.fastq.gz
    local command

    target_bases=$(awk -F '\t' '$1 == "requested_read_bases" { print $2 }' \
        "$OUTDIR/run/settings.tsv")
    [[ $target_bases =~ ^[1-9][0-9]*$ ]]

    command=(
        badread simulate
        --reference "$OUTDIR/simulation/mutated.fa"
        --quantity "$target_bases"
        --error_model nanopore2023
        --qscore_model nanopore2023
        --identity 20,3
        --length 15000,13000
        --glitches 10000,10,10
        --junk_reads 0.1
        --random_reads 0.1
        --chimeras 0.1
        --seed "$SEED"
    )
    record_pipeline "$(printf '%q ' "${command[@]}")| gzip -c > $(printf '%q' "$reads_tmp")"
    "${command[@]}" | gzip -c > "$reads_tmp"
    [[ -s $reads_tmp ]]
    gzip -t "$reads_tmp"
    mv -- "$reads_tmp" "$OUTDIR/reads/reads.fastq.gz"
}

stage_alignment() {
    local mapper_threads
    local sorter_threads
    local bam_tmp=$TMP_DIR/simulated.bam
    local minimap_command
    local sort_command

    sorter_threads=$((THREADS / 4))
    ((sorter_threads >= 1)) || sorter_threads=1
    mapper_threads=$((THREADS - sorter_threads))
    ((mapper_threads >= 1)) || mapper_threads=1

    minimap_command=(
        minimap2 -a -x map-ont -t "$mapper_threads"
        "$OUTDIR/run/reference.fa" "$OUTDIR/reads/reads.fastq.gz"
    )
    sort_command=(
        samtools sort -@ "$sorter_threads" -m 1G -o "$bam_tmp" -
    )
    record_pipeline "$(printf '%q ' "${minimap_command[@]}")| $(printf '%q ' "${sort_command[@]}")"
    "${minimap_command[@]}" | "${sort_command[@]}"

    [[ -s $bam_tmp ]]
    record_command samtools quickcheck -v "$bam_tmp"
    samtools quickcheck -v "$bam_tmp"
    record_command samtools index -@ "$THREADS" "$bam_tmp"
    if ! samtools index -@ "$THREADS" "$bam_tmp"; then
        rm -f -- "$bam_tmp.bai"
        record_command samtools index -@ "$THREADS" -c "$bam_tmp"
        samtools index -@ "$THREADS" -c "$bam_tmp"
    fi
    [[ -s $bam_tmp.bai || -s $bam_tmp.csi ]]

    mv -- "$bam_tmp" "$OUTDIR/alignment/simulated.bam"
    if [[ -s $bam_tmp.bai ]]; then
        mv -- "$bam_tmp.bai" "$OUTDIR/alignment/simulated.bam.bai"
    else
        mv -- "$bam_tmp.csi" "$OUTDIR/alignment/simulated.bam.csi"
    fi
}

log "Starting simulation: ploidy=$PLOIDY seed=$SEED technology=$TECHNOLOGY aggregate_coverage=${COVERAGE}x"
log "Reference: $REF"
log "Config: $CONFIG"
log "Output: $OUTDIR"

run_stage '1/5' 'Preflight' stage_preflight "$OUTDIR/logs/01_preflight.log" 2
run_stage '2/5' 'SV simulation' stage_simulation "$OUTDIR/logs/02_simulation.log" 1
run_stage '3/5' 'Variant insertion and truth preparation' stage_insertion \
    "$OUTDIR/logs/03_insertion.log" 1
run_stage '4/5' 'ONT read generation' stage_read_generation \
    "$OUTDIR/logs/04_read_generation.log" 1
run_stage '5/5' 'Alignment to original reference' stage_alignment \
    "$OUTDIR/logs/05_alignment.log" 1

rm -rf -- "$TMP_DIR"
COMPLETED=1
log "Simulation complete in $((SECONDS - START_TIME))s"
log "BAM: $OUTDIR/alignment/simulated.bam"
log "Reference: $REF"
log "Truth: $OUTDIR/simulation/truth.vcf.gz"
log "Truth metadata: $OUTDIR/simulation/truth_metadata.tsv"
log "Output: $OUTDIR"
