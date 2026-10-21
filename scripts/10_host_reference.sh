#!/usr/bin/env bash
# Step 10 — Host reference: A. hypogaea Tifrunner gnm2 (RefSeq GCF_003086295.3; 20 chromosomes,
# 422 unplaced scaffolds, chloroplast NC_037358.1) + mitochondrion MW448460.1 (not in the assembly).
# Builds a Bowtie2 index (DNA, WGS) and a HISAT2 index with splice sites/exons from the RefSeq GFF
# (RNA-seq). Memory: hisat2-build with --ss/--exon on 2.56 Gb needs far more RAM than without;
# set HISAT2_SPLICE=0 to build without annotation (~8 GB).
# Usage: bash scripts/10_host_reference.sh   (run on HPC: medium/large queue)
source "$(dirname "$0")/common.sh"
require_tools datasets unzip bowtie2-build hisat2-build samtools seqkit

H="$REF_DIR/host"; mkdir -p "$H" "$LOG_DIR/10_host"
HISAT2_SPLICE="${HISAT2_SPLICE:-0}"

if ! is_done host_fasta; then
    fetch_organelles
    tmp=$(mktemp -d "$H/dl.XXXX")
    datasets download genome accession GCF_003086295.3 --include genome,gff3 --filename "$tmp/p.zip" \
        > "$LOG_DIR/10_host/datasets.log" 2>&1
    unzip -q -o "$tmp/p.zip" -d "$tmp"
    find "$tmp/ncbi_dataset/data" -name '*.fna' -exec cat {} + > "$H/assembly.fna"
    find "$tmp/ncbi_dataset/data" -name '*.gff' -exec cat {} + > "$H/assembly.gff3"
    rm -rf "$tmp"
    grep -q '^>NC_037358.1' "$H/assembly.fna" || die "expected chloroplast NC_037358.1 in assembly"
    cat "$H/assembly.fna" "$REF_DIR/organelles/MW448460.1.fasta" | seqkit seq -w 0 > "$H/host.fa"
    rm -f "$H/assembly.fna"
    samtools faidx "$H/host.fa"
    seqkit stats -T "$H/host.fa" > "$H/host.stats.tsv"
    printf 'component\taccession\nnuclear+chloroplast\tGCF_003086295.3\nmitochondrion\tMW448460.1\n' > "$H/host_components.tsv"
    md5sum "$H/host.fa" > "$H/host.fa.md5"
    mark_done host_fasta
fi

if ! is_done host_bt2; then
    log "bowtie2-build host ($(awk 'NR==2{print $5}' "$H/host.stats.tsv") bp)"
    bowtie2-build --threads "$THREADS" "$H/host.fa" "$H/bt2_host" > "$LOG_DIR/10_host/bowtie2-build.log" 2>&1
    mark_done host_bt2
fi

if ! is_done host_ht2; then
    extra=()
    if [[ $HISAT2_SPLICE == 1 ]]; then
        require_tools gffread
        gffread "$H/assembly.gff3" -T -o "$H/assembly.gtf"
        hisat2_extract_splice_sites.py "$H/assembly.gtf" > "$H/splice_sites.txt"
        hisat2_extract_exons.py "$H/assembly.gtf" > "$H/exons.txt"
        extra=(--ss "$H/splice_sites.txt" --exon "$H/exons.txt")
    fi
    log "hisat2-build host (splice annotation: $HISAT2_SPLICE)"
    hisat2-build -p "$THREADS" "${extra[@]}" "$H/host.fa" "$H/ht2_host" > "$LOG_DIR/10_host/hisat2-build.log" 2>&1
    mark_done host_ht2
fi
log "Step 10 complete: $H"
