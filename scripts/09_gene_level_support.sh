#!/usr/bin/env bash
# Step 9 — Gene-level support for a cellular candidate in RNA-seq.
# Genome breadth is uninformative for transcriptomes (only expressed genes are sampled), so we ask:
# how many distinct annotated genes carry candidate-assigned fragments, and are they spread across
# functional categories or concentrated in conserved loci (rRNA) that invite cross-mapping?
#   1. fragments assigned to GROUP in step 6 Stage A, stratified by identity (>= MIN_ID and < MIN_ID)
#   2. reads extracted from the trimmed FASTQ, realigned (Bowtie2 --local) to one reference genome
#   3. per-gene fragment counts from the RefSeq GFF3 (gene features; product from child CDS/RNA)
# Usage: bash scripts/09_gene_level_support.sh RUN GROUP LABEL ASSEMBLY_ACC [MIN_ID=0.98]
source "$(dirname "$0")/common.sh"
require_tools seqkit bowtie2 bowtie2-build samtools datasets unzip python3

run="${1:?RUN}"; group="${2:?GROUP}"; label="${3:?LABEL}"; acc="${4:?ASSEMBLY_ACC}"; min_id="${5:-0.98}"
V="$RES_DIR/04_validation/$run"; D="$V/genes/$label"; R="$REF_DIR/validation/annot/$label"
mkdir -p "$D" "$R"
frag="$V/$run.fragments.tsv.gz"; [[ -s $frag ]] || die "missing $frag (run step 6)"

# 1. fragment lists by identity stratum (Stage A primary alignment)
zcat "$frag" | awk -F'\t' -v g="$group" -v m="$min_id" -v d="$D" \
    'NR>1 && $3==g { if ($5>=m && $6>=0.8) print $1 > d"/names_high.txt"; else print $1 > d"/names_low.txt" }'
touch "$D/names_high.txt" "$D/names_low.txt"
log "$run/$group: $(wc -l < "$D/names_high.txt") fragments identity>=$min_id & aligned>=80%, $(wc -l < "$D/names_low.txt") others"

# 2. reference genome + GFF3
if [[ ! -s $R/genome.fna || ! -s $R/genes.gff3 ]]; then
    tmp=$(mktemp -d "$R/dl.XXXX")
    datasets download genome accession "$acc" --include genome,gff3 --filename "$tmp/p.zip" > "$LOG_DIR/05_refs/datasets_$label.log" 2>&1
    unzip -q -o "$tmp/p.zip" -d "$tmp"
    find "$tmp/ncbi_dataset/data" -name '*.fna' -exec cat {} + > "$R/genome.fna"
    find "$tmp/ncbi_dataset/data" -name '*.gff' -exec cat {} + > "$R/genes.gff3"
    rm -rf "$tmp"
    [[ -s $R/genes.gff3 ]] || die "$acc: no GFF3 annotation available"
fi
[[ -s $R/idx.1.bt2 || -s $R/idx.1.bt2l ]] || bowtie2-build -q --threads "$THREADS" "$R/genome.fna" "$R/idx"

for stratum in high low; do
    n=$(wc -l < "$D/names_$stratum.txt"); [[ $n -gt 0 ]] || continue
    if [[ ! -s $D/$stratum.bam ]]; then
        for r in 1 2; do
            seqkit grep -j 4 -f "$D/names_$stratum.txt" "$TRIM_DIR/${run}_${r}.trim.fastq.gz" -o "$D/${stratum}_$r.fq.gz"
        done
        bowtie2 -p "$THREADS" --local -x "$R/idx" -1 "$D/${stratum}_1.fq.gz" -2 "$D/${stratum}_2.fq.gz" -X 800 --no-unal \
            2> "$D/$stratum.bowtie2.log" | samtools sort -@ 2 -o "$D/$stratum.bam" -
        samtools index "$D/$stratum.bam"
    fi
    # 3. per-gene counts (one count per fragment: R1, or R2 if R1 unmapped; primary; MAPQ>=0)
    { samtools view -F 0x904 -f 0x40 "$D/$stratum.bam"; samtools view -F 0x904 -f 0x88 "$D/$stratum.bam"; } \
      | python3 "$ROOT/scripts/lib/count_genes.py" "$R/genes.gff3" "$D/${stratum}_gene_counts.tsv" "$D/${stratum}_gene_summary.tsv" \
        "$run" "$group" "$label" "$stratum" "$min_id"
done
cat "$D"/*_gene_summary.tsv 2>/dev/null | awk 'NR==1 || !/^run\t/' > "$D/gene_summary.tsv"
log "Step 9 complete: $D/gene_summary.tsv"
