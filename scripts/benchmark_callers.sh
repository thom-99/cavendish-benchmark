#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM_NAME=${0##*/}
DEFAULT_CALLERS=sniffles2,cutesv,dysgu
DEFAULT_TECHNOLOGY=ont
DEFAULT_MIN_SUPPORT=5
DEFAULT_THREADS=8
DEFAULT_OUTDIR=benchmark_results

BAM=
REF=
TRUTH=
CALLERS_CSV=$DEFAULT_CALLERS
TECHNOLOGY=$DEFAULT_TECHNOLOGY
MIN_SUPPORT=$DEFAULT_MIN_SUPPORT
THREADS=$DEFAULT_THREADS
OUTDIR=$DEFAULT_OUTDIR
INCLUDE_BND=0

PIPELINE_LOG=
COMMANDS_FILE=
TMP_DIR=
COMPLETED=0
START_TIME=$SECONDS
declare -a REQUESTED_CALLERS=()
declare -a AVAILABLE_CALLERS=()

usage() {
    cat <<EOF
Usage: $PROGRAM_NAME --bam ALIGNMENT.bam --ref REF.fa --truth TRUTH.vcf.gz [options]

Call structural variants with Sniffles2, cuteSV, and/or dysgu, then evaluate
their genotype-free callsets with Truvari.

Required arguments:
  --bam PATH             Coordinate-sorted BAM with an existing BAI or CSI index
  --ref PATH             Original uncompressed .fa or .fasta reference
  --truth PATH           Matching bgzip-compressed truth VCF with an index

Optional arguments:
  --callers LIST         Comma-separated caller IDs: sniffles2,cutesv,dysgu
                         (default: $DEFAULT_CALLERS)
  --technology NAME      ont, hifi, or clr; only ont is currently validated
                         (default: $DEFAULT_TECHNOLOGY)
  --min-support N        Requested minimum supporting reads (default: $DEFAULT_MIN_SUPPORT)
  --threads N            Caller thread count (default: $DEFAULT_THREADS; dysgu max: 12)
  --include-bnd          Add a separate, experimental BND-record evaluation
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
        --bam) (($# >= 2)) || argument_error "--bam requires a path"; BAM=$2; shift 2 ;;
        --ref) (($# >= 2)) || argument_error "--ref requires a path"; REF=$2; shift 2 ;;
        --truth) (($# >= 2)) || argument_error "--truth requires a path"; TRUTH=$2; shift 2 ;;
        --callers) (($# >= 2)) || argument_error "--callers requires a list"; CALLERS_CSV=$2; shift 2 ;;
        --technology) (($# >= 2)) || argument_error "--technology requires a name"; TECHNOLOGY=$2; shift 2 ;;
        --min-support) (($# >= 2)) || argument_error "--min-support requires an integer"; MIN_SUPPORT=$2; shift 2 ;;
        --threads) (($# >= 2)) || argument_error "--threads requires an integer"; THREADS=$2; shift 2 ;;
        --include-bnd) INCLUDE_BND=1; shift ;;
        -o|--outdir) (($# >= 2)) || argument_error "$1 requires a path"; OUTDIR=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; (($# == 0)) || argument_error "unexpected positional arguments: $*" ;;
        -*) argument_error "unknown option: $1" ;;
        *) argument_error "unexpected positional argument: $1" ;;
    esac
done

[[ -n $BAM ]] || argument_error "--bam is required"
[[ -n $REF ]] || argument_error "--ref is required"
[[ -n $TRUTH ]] || argument_error "--truth is required"
[[ $THREADS =~ ^[1-9][0-9]*$ ]] || argument_error "--threads must be a positive integer"
[[ $MIN_SUPPORT =~ ^[1-9][0-9]*$ ]] || argument_error "--min-support must be a positive integer"
case "$TECHNOLOGY" in ont|hifi|clr) ;; *) argument_error "--technology must be one of: ont, hifi, clr" ;; esac
[[ -n $CALLERS_CSV ]] || argument_error "--callers must not be empty"

IFS=, read -r -a REQUESTED_CALLERS <<< "$CALLERS_CSV"
declare -A SEEN_CALLERS=()
for caller in "${REQUESTED_CALLERS[@]}"; do
    [[ -n $caller ]] || argument_error "--callers contains an empty caller ID"
    case "$caller" in sniffles2|cutesv|dysgu) ;; *) argument_error "unsupported caller ID: $caller" ;; esac
    [[ -z ${SEEN_CALLERS[$caller]+x} ]] || argument_error "duplicate caller ID: $caller"
    SEEN_CALLERS[$caller]=1
done

[[ -f $BAM && -r $BAM && -s $BAM ]] || argument_error "BAM is not a readable, nonempty file: $BAM"
[[ -f $REF && -r $REF && -s $REF ]] || argument_error "reference is not a readable, nonempty file: $REF"
[[ -f $TRUTH && -r $TRUTH && -s $TRUTH ]] || argument_error "truth is not a readable, nonempty file: $TRUTH"
case "$BAM" in *.bam) ;; *) argument_error "alignment must end in .bam" ;; esac
case "$REF" in *.fa|*.fasta) ;; *) argument_error "reference must be uncompressed and end in .fa or .fasta" ;; esac
case "$TRUTH" in *.vcf.gz) ;; *) argument_error "truth must be bgzip-compressed and end in .vcf.gz" ;; esac

command -v realpath >/dev/null 2>&1 || argument_error "required utility not found: realpath"
BAM=$(realpath -- "$BAM")
REF=$(realpath -- "$REF")
TRUTH=$(realpath -- "$TRUTH")
OUTDIR=$(realpath -m -- "$OUTDIR")
for input in "$BAM" "$REF" "$TRUTH"; do
    case "$input" in "$OUTDIR"/*) argument_error "output directory must not contain an input: $input" ;; esac
done
if [[ -e $OUTDIR && ! -d $OUTDIR ]]; then argument_error "output path is not a directory: $OUTDIR"; fi
if [[ -d $OUTDIR ]]; then
    shopt -s nullglob dotglob
    entries=("$OUTDIR"/*)
    shopt -u nullglob dotglob
    ((${#entries[@]} == 0)) || argument_error "output directory is not empty: $OUTDIR"
fi

mkdir -p -- "$OUTDIR"/{run,logs,tmp,callers,evaluation,summary}
PIPELINE_LOG=$OUTDIR/logs/pipeline.log
COMMANDS_FILE=$OUTDIR/run/commands.sh
TMP_DIR=$OUTDIR/tmp
: > "$PIPELINE_LOG"
: > "$COMMANDS_FILE"

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { printf '[%s] %s\n' "$(timestamp)" "$*" | tee -a "$PIPELINE_LOG"; }
record_command() { local arg; for arg in "$@"; do printf '%q ' "$arg" >> "$COMMANDS_FILE"; done; printf '\n' >> "$COMMANDS_FILE"; }
require_command() { command -v "$1" >/dev/null 2>&1 || { printf 'Missing required command: %s\n' "$1" >&2; return 1; }; }
capture_version() { local label=$1; shift; printf '## %s\n' "$label"; "$@" 2>&1 || true; printf '\n'; }

on_exit() {
    local code=$?
    if ((code != 0)); then log "Pipeline failed with exit code $code; scratch retained at $TMP_DIR";
    elif ((COMPLETED == 0)); then log "Pipeline stopped before completion; scratch retained at $TMP_DIR"; fi
}
trap on_exit EXIT

run_stage() {
    local number=$1 name=$2 function_name=$3 stage_log=$4 failure_code=$5 status start=$SECONDS
    log "Stage $number: $name (details: $stage_log)"
    set +e
    (set -Eeuo pipefail; "$function_name") >> "$stage_log" 2>&1
    status=$?
    set -e
    if ((status == 0)); then log "Stage $number complete in $((SECONDS - start))s"; return 0; fi
    log "Stage $number failed after $((SECONDS - start))s (details: $stage_log)"
    exit "$failure_code"
}

find_bam_index() {
    local candidate
    for candidate in "$BAM.bai" "${BAM%.bam}.bai" "$BAM.csi" "${BAM%.bam}.csi"; do [[ -s $candidate ]] && { printf '%s\n' "$candidate"; return; }; done
    return 1
}
find_truth_index() {
    local candidate
    for candidate in "$TRUTH.tbi" "$TRUTH.csi"; do [[ -s $candidate ]] && { printf '%s\n' "$candidate"; return; }; done
    return 1
}

validate_contigs() {
    python3 - "$BAM" "$REF" "$TRUTH" <<'PY'
import sys
import pysam

bam_path, ref_path, truth_path = sys.argv[1:]
with pysam.AlignmentFile(bam_path, "rb") as bam:
    bam_dict = list(zip(bam.references, bam.lengths))
with pysam.FastaFile(ref_path) as ref:
    ref_dict = [(name, ref.get_reference_length(name)) for name in ref.references]
with pysam.VariantFile(truth_path) as truth:
    truth_dict = [(name, rec.length) for name, rec in truth.header.contigs.items()]

if bam_dict != ref_dict:
    raise SystemExit("BAM and reference contig names, order, or lengths differ")
if truth_dict != ref_dict:
    raise SystemExit("truth and reference contig names, order, or lengths differ")
PY
}

normalize_truth_ids() {
    local source=$1 output=$2 map_file=$3
    python3 - "$source" "$output" "$map_file" <<'PY'
import collections
import sys
import pysam

source, output, map_file = sys.argv[1:]
counts = collections.Counter()
with pysam.VariantFile(source) as src:
    for record in src:
        counts[record.id or "."] += 1

seen = collections.Counter()
assigned = set()
with pysam.VariantFile(source) as src, pysam.VariantFile(output, "w", header=src.header) as dst, open(map_file, "w", encoding="utf-8") as mapping:
    mapping.write("evaluation_id\toriginal_id\tallele_number\n")
    for record in src:
        original = record.id or "."
        seen[original] += 1
        if original == ".":
            base = f"TRUTH_{record.contig}_{record.pos}_{record.ref}_{record.alts[0]}"
        else:
            base = original
        assigned_id = f"{base}.A{seen[original]}" if counts[original] > 1 or original == "." else base
        suffix = 1
        candidate = assigned_id
        while candidate in assigned:
            suffix += 1
            candidate = f"{assigned_id}.{suffix}"
        record.id = candidate
        assigned.add(candidate)
        mapping.write(f"{candidate}\t{original}\t{seen[original]}\n")
        dst.write(record)
PY
}

prepare_sites() {
    local source=$1 scope=$2 prefix=$3 expression
    case "$scope" in
        standard) expression='INFO/SVTYPE="INS" || INFO/SVTYPE="DEL" || INFO/SVTYPE="DUP" || INFO/SVTYPE="INV"' ;;
        bnd) expression='INFO/SVTYPE="BND" || ALT~"\\[" || ALT~"\\]"' ;;
        *) return 1 ;;
    esac
    record_command bcftools view -G -i "$expression" -Ov -o "$prefix.view.vcf" "$source"
    bcftools view -G -i "$expression" -Ov -o "$prefix.view.vcf" "$source"
    record_command bcftools reheader --fai "$OUTDIR/run/reference.fa.fai" -o "$prefix.header.vcf" "$prefix.view.vcf"
    bcftools reheader --fai "$OUTDIR/run/reference.fa.fai" -o "$prefix.header.vcf" "$prefix.view.vcf"
    record_command bcftools sort -Oz -o "$prefix.vcf.gz" --temp-dir "$TMP_DIR/bcftools-sort.XXXXXX" "$prefix.header.vcf"
    bcftools sort -Oz -o "$prefix.vcf.gz" --temp-dir "$TMP_DIR/bcftools-sort.XXXXXX" "$prefix.header.vcf"
    record_command bcftools index --csi "$prefix.vcf.gz"
    bcftools index --csi "$prefix.vcf.gz"
    [[ -s $prefix.vcf.gz && -s $prefix.vcf.gz.csi ]]
}

stage_preflight() {
    local dependency caller executable bam_index truth_index has_dysgu=0
    for dependency in python3 samtools bcftools truvari sha256sum awk tee date cp ln mv rm gzip; do require_command "$dependency"; done
    python3 -c 'import pysam' >/dev/null
    [[ $TECHNOLOGY == ont ]] || { printf '%s\n' "Only --technology ont is validated for these caller presets" >&2; return 1; }
    for caller in "${REQUESTED_CALLERS[@]}"; do [[ $caller == dysgu ]] && has_dysgu=1; done
    if ((has_dysgu && THREADS > 12)); then
        printf '%s\n' "dysgu supports at most 12 processes; lower --threads" >&2; return 1
    fi
    bam_index=$(find_bam_index) || { printf '%s\n' "Missing BAM BAI/CSI index" >&2; return 1; }
    truth_index=$(find_truth_index) || { printf '%s\n' "Missing truth TBI/CSI index" >&2; return 1; }
    samtools quickcheck -v "$BAM"
    bcftools index --stats "$TRUTH" >/dev/null
    ln -s -- "$REF" "$OUTDIR/run/reference.fa"
    samtools faidx "$OUTDIR/run/reference.fa"
    validate_contigs

    printf 'caller\tavailability\treason\n' > "$OUTDIR/run/caller_availability.tsv"
    for caller in "${REQUESTED_CALLERS[@]}"; do
        case "$caller" in sniffles2) executable=sniffles ;; cutesv) executable=cuteSV ;; dysgu) executable=dysgu ;; esac
        if command -v "$executable" >/dev/null 2>&1; then
            AVAILABLE_CALLERS+=("$caller")
            printf '%s\tavailable\t\n' "$caller" >> "$OUTDIR/run/caller_availability.tsv"
        else
            printf '%s\tskipped\tmissing executable: %s\n' "$caller" "$executable" >> "$OUTDIR/run/caller_availability.tsv"
            log "Warning: skipping $caller because $executable is not installed"
        fi
    done
    ((${#AVAILABLE_CALLERS[@]} > 0)) || { printf '%s\n' "None of the requested callers is installed" >&2; return 1; }

    {
        printf 'parameter\tvalue\n'
        printf 'bam\t%s\nreference\t%s\ntruth\t%s\n' "$BAM" "$REF" "$TRUTH"
        printf 'bam_index\t%s\ntruth_index\t%s\n' "$bam_index" "$truth_index"
        printf 'callers\t%s\ntechnology\t%s\nmin_support\t%s\nthreads\t%s\ninclude_bnd\t%s\n' "$CALLERS_CSV" "$TECHNOLOGY" "$MIN_SUPPORT" "$THREADS" "$INCLUDE_BND"
    } > "$OUTDIR/run/settings.tsv"
    sha256sum "$BAM" "$bam_index" "$REF" "$TRUTH" "$truth_index" > "$OUTDIR/run/input_checksums.sha256"
    {
        capture_version samtools samtools --version
        capture_version bcftools bcftools --version
        capture_version Truvari truvari version
        capture_version Sniffles2 sniffles --version
        capture_version cuteSV cuteSV --version
        capture_version dysgu dysgu --version
    } > "$OUTDIR/run/versions.txt"

    mkdir -p "$TMP_DIR/truth"
    record_command bcftools norm -m -any -Ov -o "$TMP_DIR/truth/split.vcf" "$TRUTH"
    bcftools norm -m -any -Ov -o "$TMP_DIR/truth/split.vcf" "$TRUTH"
    normalize_truth_ids "$TMP_DIR/truth/split.vcf" "$TMP_DIR/truth/identified.vcf" "$OUTDIR/run/truth_id_map.tsv"
    prepare_sites "$TMP_DIR/truth/identified.vcf" standard "$OUTDIR/run/truth.standard"
    if ((INCLUDE_BND)); then prepare_sites "$TMP_DIR/truth/identified.vcf" bnd "$OUTDIR/run/truth.bnd"; fi
}

call_one() {
    local caller=$1 work=$TMP_DIR/callers/$caller raw=$TMP_DIR/callers/$caller/raw.vcf final_dir=$OUTDIR/callers/$caller
    mkdir -p "$work" "$final_dir"
    case "$caller" in
        sniffles2)
            mkdir -p "$work/work"
            record_command sniffles --input "$BAM" --reference "$OUTDIR/run/reference.fa" --threads "$THREADS" --minsupport "$MIN_SUPPORT" --tmp-dir "$work/work" --vcf "$raw"
            sniffles --input "$BAM" --reference "$OUTDIR/run/reference.fa" --threads "$THREADS" --minsupport "$MIN_SUPPORT" --tmp-dir "$work/work" --vcf "$raw"
            ;;
        cutesv)
            mkdir -p "$work/work"
            record_command cuteSV "$BAM" "$OUTDIR/run/reference.fa" "$raw" "$work/work" --threads "$THREADS" --min_support "$MIN_SUPPORT" --max_cluster_bias_INS 100 --diff_ratio_merging_INS 0.3 --max_cluster_bias_DEL 100 --diff_ratio_merging_DEL 0.3 --max_size -1
            cuteSV "$BAM" "$OUTDIR/run/reference.fa" "$raw" "$work/work" --threads "$THREADS" --min_support "$MIN_SUPPORT" --max_cluster_bias_INS 100 --diff_ratio_merging_INS 0.3 --max_cluster_bias_DEL 100 --diff_ratio_merging_DEL 0.3 --max_size -1
            ;;
        dysgu)
            record_command dysgu call --mode nanopore-r10 --diploid False --min-support "$MIN_SUPPORT" -p "$THREADS" "$OUTDIR/run/reference.fa" "$work/work" "$BAM"
            dysgu call --mode nanopore-r10 --diploid False --min-support "$MIN_SUPPORT" -p "$THREADS" "$OUTDIR/run/reference.fa" "$work/work" "$BAM" > "$raw"
            ;;
    esac
    [[ -s $raw ]]
    record_command bcftools sort -Oz -o "$work/calls.vcf.gz" --temp-dir "$work/sort.XXXXXX" "$raw"
    bcftools sort -Oz -o "$work/calls.vcf.gz" --temp-dir "$work/sort.XXXXXX" "$raw"
    bcftools index --csi "$work/calls.vcf.gz"
    mv "$work/calls.vcf.gz" "$work/calls.vcf.gz.csi" "$final_dir/"
}

stage_calling() {
    local caller availability reason status
    mkdir -p "$TMP_DIR/callers"
    printf 'caller\tcalling\treason\n' > "$OUTDIR/run/call_status.tsv"
    while IFS=$'\t' read -r caller availability reason; do
        [[ $caller != caller ]] || continue
        if [[ $availability != available ]]; then
            printf '%s\tskipped\t%s\n' "$caller" "$reason" >> "$OUTDIR/run/call_status.tsv"
            continue
        fi
        log "Calling with $caller (details: $OUTDIR/logs/$caller.call.log)"
        set +e
        (set -Eeuo pipefail; call_one "$caller") > "$OUTDIR/logs/$caller.call.log" 2>&1
        status=$?
        set -e
        if ((status == 0)); then
            printf '%s\tsuccess\t\n' "$caller" >> "$OUTDIR/run/call_status.tsv"
            log "$caller calling complete"
        else
            printf '%s\tfailed\tcalling failed (exit %s)\n' "$caller" "$status" >> "$OUTDIR/run/call_status.tsv"
            log "Warning: $caller calling failed; continuing"
        fi
    done < "$OUTDIR/run/caller_availability.tsv"
}

extract_metrics() {
    local summary=$1 scope=$2 output=$3
    python3 - "$summary" "$scope" "$output" <<'PY'
import json
import sys

summary_path, scope, output_path = sys.argv[1:]
with open(summary_path, encoding="utf-8") as handle:
    data = json.load(handle)
keys = ["precision", "recall", "f1", "TP-base", "TP-comp", "FP", "FN"]
new = not __import__("os").path.exists(output_path)
with open(output_path, "a", encoding="utf-8") as out:
    if new:
        out.write("scope\t" + "\t".join(keys) + "\n")
    values = [("NA" if data.get(key) is None else str(data.get(key, "NA"))) for key in keys]
    out.write(scope + "\t" + "\t".join(values) + "\n")
PY
}

evaluate_scope() {
    local caller=$1
    local scope=$2
    local call_prefix=$TMP_DIR/evaluation/$caller/$scope/calls
    local eval_dir=$OUTDIR/evaluation/$caller/$scope
    local truth_sites
    mkdir -p "$(dirname "$call_prefix")" "$OUTDIR/evaluation/$caller"
    prepare_sites "$OUTDIR/callers/$caller/calls.vcf.gz" "$scope" "$call_prefix"
    truth_sites=$OUTDIR/run/truth.$scope.vcf.gz
    [[ ! -e $eval_dir ]]
    if [[ $scope == standard ]]; then
        record_command truvari bench -b "$truth_sites" -c "$call_prefix.vcf.gz" -f "$OUTDIR/run/reference.fa" -o "$eval_dir" --pick single --passonly --sizemin 50 --sizefilt 30 --sizemax -1 --refdist 1000 --pctsize 0.5 --pctseq 0 --pctovl 0
        truvari bench -b "$truth_sites" -c "$call_prefix.vcf.gz" -f "$OUTDIR/run/reference.fa" -o "$eval_dir" --pick single --passonly --sizemin 50 --sizefilt 30 --sizemax -1 --refdist 1000 --pctsize 0.5 --pctseq 0 --pctovl 0
    else
        record_command truvari bench -b "$truth_sites" -c "$call_prefix.vcf.gz" -f "$OUTDIR/run/reference.fa" -o "$eval_dir" --pick single --passonly --sizemin 0 --sizefilt 0 --sizemax -1 --bnddist 1000 --pctseq 0
        truvari bench -b "$truth_sites" -c "$call_prefix.vcf.gz" -f "$OUTDIR/run/reference.fa" -o "$eval_dir" --pick single --passonly --sizemin 0 --sizefilt 0 --sizemax -1 --bnddist 1000 --pctseq 0
    fi
    [[ -s $eval_dir/summary.json ]]
    extract_metrics "$eval_dir/summary.json" "$scope" "$OUTDIR/evaluation/$caller/metrics.tsv"
}

stage_evaluation() {
    local caller calling reason status
    printf 'caller\tevaluation\treason\n' > "$OUTDIR/run/eval_status.tsv"
    while IFS=$'\t' read -r caller calling reason; do
        [[ $caller != caller ]] || continue
        if [[ $calling != success ]]; then
            printf '%s\tskipped\t%s\n' "$caller" "$reason" >> "$OUTDIR/run/eval_status.tsv"
            continue
        fi
        log "Evaluating $caller (details: $OUTDIR/logs/$caller.evaluate.log)"
        set +e
        (
            set -Eeuo pipefail
            evaluate_scope "$caller" standard
            if ((INCLUDE_BND)); then evaluate_scope "$caller" bnd; fi
        ) > "$OUTDIR/logs/$caller.evaluate.log" 2>&1
        status=$?
        set -e
        if ((status == 0)); then
            printf '%s\tsuccess\t\n' "$caller" >> "$OUTDIR/run/eval_status.tsv"
            log "$caller evaluation complete"
        else
            printf '%s\tfailed\tevaluation failed (exit %s)\n' "$caller" "$status" >> "$OUTDIR/run/eval_status.tsv"
            log "Warning: $caller evaluation failed; continuing"
        fi
    done < "$OUTDIR/run/call_status.tsv"
}

write_status_summary() {
    python3 - "$OUTDIR/run/call_status.tsv" "$OUTDIR/run/eval_status.tsv" "$OUTDIR/summary/caller_status.tsv" <<'PY'
import csv
import sys

call_path, eval_path, output_path = sys.argv[1:]
with open(call_path, encoding="utf-8") as handle:
    calls = {row["caller"]: row for row in csv.DictReader(handle, delimiter="\t")}
with open(eval_path, encoding="utf-8") as handle:
    evaluations = {row["caller"]: row for row in csv.DictReader(handle, delimiter="\t")}
with open(output_path, "w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
    writer.writerow(["caller", "calling", "evaluation", "reason"])
    for caller, call in calls.items():
        evaluation = evaluations.get(caller, {})
        reason = evaluation.get("reason") or call.get("reason") or ""
        writer.writerow([caller, call["calling"], evaluation.get("evaluation", "not_run"), reason])
PY
}

log "Benchmark inputs: BAM=$BAM, reference=$REF, truth=$TRUTH"
log "Configurations: $CALLERS_CSV; technology=$TECHNOLOGY; minimum support=$MIN_SUPPORT"
run_stage 1/3 preflight stage_preflight "$OUTDIR/logs/01_preflight.log" 2
run_stage 2/3 calling stage_calling "$OUTDIR/logs/02_calling.log" 1
run_stage 3/3 evaluation stage_evaluation "$OUTDIR/logs/03_evaluation.log" 1
write_status_summary

overall=0
awk -F '\t' 'NR > 1 && ($2 != "success" || $3 != "success") { exit 1 }' "$OUTDIR/summary/caller_status.tsv" || overall=1
if ((overall)); then
    log "Benchmark incomplete; see $OUTDIR/summary/caller_status.tsv"
    exit 1
fi

rm -rf -- "$TMP_DIR"
COMPLETED=1
log "Benchmark complete in $((SECONDS - START_TIME))s: $OUTDIR"
