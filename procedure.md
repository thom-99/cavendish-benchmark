# Benchmarking long-read structural-variant callers

This walkthrough describes how to simulate a synthetic triploid Cavendish data
set with moderate-poor read quality and benchmark Sniffles2, cuteSV, and dysgu against the resulting truth set.


## workflow

1. simulate a set of SVs with inSVert simulate starting from a config.yaml (config.yaml --> VCF)
2. insert the variants into a triploid reference, with inSVert insert (VCF --> fasta)
3. simulate poor quality ONT reads with Badread (fasta --> fastq.gz)
4. map them back to the original haploid reference with minimap2 (fastq.gz --> bam)
5. variant call with [Sniffles, cuteSV, dysgu --diploid False]
6. evaluate against the truth VCF using truvari
7. final report

## project organization

data/ 
    input/
        config.yaml, Cavendish reference genome, index, provenance
        subset_cavendish/ --> reduced reference, index, config
        pilot/ --> pilot reference, index, config
    simulated/ --> truth.vcf simulated.fa simulated_reads.fastq simulated.bam
    variant_calls/ --> sniffles.vcf cutesv.vcf dysgu.vcf 

results/
    truvari/
        sniffles/ --> summary, truth-vcf, ...
        cutesv/
        dysgu/
    report/ --> report.[md/html], figures 

scripts/ --> all the scripts to achieve the work
    /plots --> scripts to plot visually the results 



## execution

we will configure each step with a unique script, in parallel we will build the readme with the commands used to run the scripts at each step. 
the readme has to be clean and minimal, it should read without giving the user unnecessary information. 


## notes

- truvari produces many output files, which in my opinion are quite confusing for the project organization, let's just keep the summary file and the VCFs

- TRAs events cannot be detected by Sniffles, so it is not fair to evaluate on them. They also require different truvari settings I believe. 

- for this workflow, simplicity and cleanliness are to be prioritized

- a previous version of this was performed with the files scripts/simulated_bam.sh and scripts/benchmark_callers.sh but those were aggregating a buch of steps together and were not tailored to poor read quality, so you can have a quick look at it if it helps but do not rely on it as truth to which base this project from. I'll remove them once we have finished with the work. 

- when building scrips, make sure to include comments. Do not overdo it, but make sure to add comments when tools are called with specific pararms and include comments for less intuitive code sections