# Cavendish structural-variant benchmark

## setup
tools and dependancies are managed with [pixi](https://pixi.prefix.dev/latest/installation/), to install all the dependacies download pixi and run
```bash
pixi install
```
# Results

# Full workflow

### 1) simulate the triploid 🍌 genome

simulate the candidate set of SVs in the form of a VCF file
```bash
pixi run --locked inSVert simulate \
  data/input/config.yaml \
  data/input/cavendish_baxijiao_BXJ1.fa \
  --seed 42 \
  --output data/simulated/requested.vcf
```

insert the SVs into the reference, producing a synthetic genome
```bash
pixi run --locked inSVert insert \
  data/input/cavendish_baxijiao_BXJ1.fa \
  data/simulated/requested.vcf \
  --ploidy 3 \
  --truth-vcf data/simulated/truth.vcf \
  --output data/simulated/simulated.fa
```

This creates `data/simulated/truth.vcf` and
`data/simulated/simulated.fa`.

### 2) generate ONT reads from the genome

The combined FASTA contains three haplotypes, so `10x` over this file gives
approximately 30x aggregate coverage after mapping to the haploid reference.
PBSIM3 targets 87% mean read accuracy and a gamma length distribution with
15 kb mean and 13 kb standard deviation. Run the following from the project
root; the ONT model is included in the Pixi environment.

```bash
(
  set -euo pipefail
  pbsim_dir=$(mktemp -d data/simulated/pbsim3.XXXXXX)

  pixi run --locked pbsim \
    --strategy wgs \
    --method qshmm \
    --qshmm .pixi/envs/default/data/QSHMM-ONT.model \
    --genome data/simulated/simulated.fa \
    --depth 10 \
    --length-mean 15000 \
    --length-sd 13000 \
    --accuracy-mean 0.87 \
    --difference-ratio 39:24:36 \
    --seed 42 \
    --prefix "$pbsim_dir/sd" \
    2> "$pbsim_dir/pbsim.log"

  gzip -t "$pbsim_dir"/sd_*.fq.gz
  cat "$pbsim_dir"/sd_*.fq.gz \
    > data/simulated/simulated_reads.fastq.gz
  rm -r -- "$pbsim_dir"
)
```

### 3) map the simulated reads to the original reference

Since these are simulated ONT reads, map them with minimap2's `map-ont`
preset, coordinate-sort the alignments, and build the BAM index required by the
variant callers:

```bash
pixi run --locked bash -c '
  set -o pipefail
  minimap2 -a -x map-ont -t 10 \
    data/input/cavendish_baxijiao_BXJ1.fa \
    data/simulated/simulated_reads.fastq.gz \
    | samtools sort -@ 8 -m 2G \
        -o data/simulated/simulated.bam -
'

pixi run --locked samtools index -@ 8 \
  data/simulated/simulated.bam
```

### 4) call structural variants
with Sniffles, cuteSV, and dysgu

The simulated reads have 87% mean accuracy, so dysgu uses its noisy ONT
(`nanopore-r9`) preset, which estimates sequence divergence from the BAM.

```bash
mkdir -p data/variant_calls/cutesv_work data/variant_calls/dysgu_work

pixi run --locked sniffles \
  --input data/simulated/simulated.bam \
  --reference data/input/cavendish_baxijiao_BXJ1.fa \
  --threads 10 \
  --vcf data/variant_calls/sniffles.vcf

pixi run --locked cuteSV \
  data/simulated/simulated.bam \
  data/input/cavendish_baxijiao_BXJ1.fa \
  data/variant_calls/cutesv.vcf \
  data/variant_calls/cutesv_work \
  --threads 10 \
  --max_cluster_bias_INS 100 \
  --diff_ratio_merging_INS 0.3 \
  --max_cluster_bias_DEL 100 \
  --diff_ratio_merging_DEL 0.3 &&
  rm -r -- data/variant_calls/cutesv_work

pixi run --locked dysgu call \
  --mode nanopore-r9 \
  --diploid False \
  --procs 10 \
  --overwrite \
  --clean \
  --svs-out data/variant_calls/dysgu.vcf \
  data/input/cavendish_baxijiao_BXJ1.fa \
  data/variant_calls/dysgu_work \
  data/simulated/simulated.bam
```

For the next step we need to create coordinate-sorted, bgzip-compressed VCFs and their tabix indexes:

```bash
pixi run --locked bcftools sort -Oz -o data/variant_calls/sniffles.vcf.gz data/variant_calls/sniffles.vcf
pixi run --locked bcftools index --tbi data/variant_calls/sniffles.vcf.gz
pixi run --locked bcftools sort -Oz -o data/variant_calls/cutesv.vcf.gz data/variant_calls/cutesv.vcf
pixi run --locked bcftools index --tbi data/variant_calls/cutesv.vcf.gz
pixi run --locked bcftools sort -Oz -o data/variant_calls/dysgu.vcf.gz data/variant_calls/dysgu.vcf
pixi run --locked bcftools index --tbi data/variant_calls/dysgu.vcf.gz
```

### 5) Evaluation with truvari


```bash
pixi run --locked python scripts/evaluate_calls.py
```

This prepares sorted, indexed copies in `data/evaluation/`, retaining INS,
DEL, DUP, and INV. It evaluates each caller twice: `primary` requires matching
SVTYPEs; `dup-to-ins` additionally allows DUP and INS to match. Both use
PASS/unfiltered calls, a 50 bp minimum size, and one-to-one matching without
requiring genotype agreement. Sequence comparison is disabled because the
truth insertions are symbolic. BND/TRA counts and other exclusions are recorded
in `data/evaluation/manifest.json`, alongside input checksums and tool versions.

The script runs the following command for each caller, then repeats it with
`--dup-to-ins` and a separate output directory:

```bash
pixi run --locked truvari bench \
  --base data/evaluation/truth.vcf.gz \
  --comp data/evaluation/sniffles.vcf.gz \
  --output results/truvari/sniffles/primary \
  --pick single --passonly \
  --sizemin 50 --sizefilt 50 --sizemax -1 \
  --refdist 500 --pctsize 0.7 --pctseq 0 --pctovl 0 \
  --no-decompose
```

This block illustrates the command already executed by the script; do not run
it again against the same output directory. The script refuses to overwrite
existing evaluation inputs or results; archive them before a fresh run.

For each caller and analysis, retain `summary.json`, `params.json`, `log.txt`,
and the indexed `tp-base.vcf.gz`, `tp-comp.vcf.gz`, `fn.vcf.gz`, and `fp.vcf.gz`.
The script checks VCF counts against the summary and removes only the unused
`candidate.refine.bed` after validation. Overall counts, precision, recall, and F1 are collected in
`results/report/metrics.tsv`.


