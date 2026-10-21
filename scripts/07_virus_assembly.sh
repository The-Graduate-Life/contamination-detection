#!/usr/bin/env bash
# Step 7 — Targeted RNA-virus assembly and annotation (minimal toolchain).
#   1. Reads assigned to virus groups in step 6 Stage A (potyvirus, polerovirus) -> MEGAHIT
#   2. Contig annotation: BLASTn vs panel virus references (identity/coverage to each isolate),
#      DIAMOND blastx vs RefSeq viral proteins, hmmsearch of 6-frame translations vs Pfam RdRp HMMs
#   3. Confirmation: ALL trimmed pairs remapped to the contigs (Bowtie2 end-to-end), so support is
#      not limited to panel-recruited reads; samtools coverage for depth/breadth.
# Limitation: targeted assembly only recovers viruses similar enough to the panel to be recruited;
#   untargeted assembly of host-depleted reads is deferred to the HPC phase.
# Usage: bash scripts/07_virus_assembly.sh RUN
source "$(dirname "$0")/common.sh"
require_tools megahit blastn makeblastdb diamond hmmsearch seqkit bowtie2 bowtie2-build samtools

run="${1:?usage: 07_virus_assembly.sh RUN}"
V="$RES_DIR/05_virus/$run"; S6="$RES_DIR/04_validation/$run/stageB"
VDB="$DB_DIR/virus"
mkdir -p "$V" "$LOG_DIR/07_virus"
is_done "validateB_$run" || die "$run: run step 6 (full) first"
is_done virus_dbs || die "run step 7a first"

# 1. assembly input: virus-group fragments from Stage A (pairs + orphan mates)
if ! is_done "virus_asm_$run"; then
    groups=$(ls -d "$S6"/*virus 2>/dev/null | xargs -n1 basename | paste -sd' ')
    [[ -n $groups ]] || die "$run: no virus groups with assigned fragments in $S6"
    log "$run: MEGAHIT on fragments from: $groups"
    cat "$S6"/*virus/r1.fq.gz > "$V/asm_r1.fq.gz"; cat "$S6"/*virus/r2.fq.gz > "$V/asm_r2.fq.gz"
    rm -rf "$V/megahit"
    megahit -1 "$V/asm_r1.fq.gz" -2 "$V/asm_r2.fq.gz" -o "$V/megahit" -t "$THREADS" \
        --min-contig-len 300 -m 0.5 > "$LOG_DIR/07_virus/$run.megahit.log" 2>&1
    seqkit seq -m 300 "$V/megahit/final.contigs.fa" | sed 's/^>\(k[0-9]*_[0-9]*\).*/>'"$run"'_\1/' > "$V/contigs.fa"
    seqkit stats -a -T "$V/contigs.fa" > "$V/contigs.stats.tsv"
    seqkit fx2tab -n -l "$V/contigs.fa" > "$V/contig_lengths.tsv"
    mark_done "virus_asm_$run"
fi

# 2a. BLASTn vs panel virus references
if ! is_done "virus_blastn_$run"; then
    awk -F'\t' '$2 ~ /virus$/{print $1}' "$REF_DIR/validation/contig_map.tsv" > "$V/panel_virus_ids.txt"
    samtools faidx "$REF_DIR/validation/panel.fasta" -r "$V/panel_virus_ids.txt" > "$V/panel_viruses.fasta"
    makeblastdb -in "$V/panel_viruses.fasta" -dbtype nucl -out "$V/panel_viruses" > /dev/null
    blastn -query "$V/contigs.fa" -db "$V/panel_viruses" -evalue 1e-10 -max_target_seqs 20 -num_threads "$THREADS" \
        -outfmt "6 qseqid sseqid pident length qlen slen qstart qend sstart send evalue bitscore qcovs" \
        > "$V/blastn_panel.tsv"
    mark_done "virus_blastn_$run"
fi

# 2b. DIAMOND blastx vs RefSeq viral proteins
if ! is_done "virus_diamond_$run"; then
    diamond blastx -q "$V/contigs.fa" -d "$VDB/refseq_viral" --sensitive -e 1e-5 -k 5 -p "$THREADS" \
        -f 6 qseqid sseqid pident length qlen slen qstart qend sstart send evalue bitscore stitle \
        -o "$V/diamond_refseq_viral.tsv" 2> "$LOG_DIR/07_virus/$run.diamond.log"
    mark_done "virus_diamond_$run"
fi

# 2c. RdRp domains: hmmsearch on 6-frame translations (stops -> X)
if ! is_done "virus_hmm_$run"; then
    seqkit translate -f 6 -F --clean "$V/contigs.fa" 2>/dev/null > "$V/contigs.6frame.faa"
    hmmsearch --cpu "$THREADS" -E 1e-5 --domtblout "$V/rdrp_hmmsearch.domtbl" \
        "$VDB/pfam/rdrp.hmm" "$V/contigs.6frame.faa" > "$LOG_DIR/07_virus/$run.hmmsearch.out"
    mark_done "virus_hmm_$run"
fi

# 3. Remap ALL trimmed pairs to the contigs
if ! is_done "virus_remap_$run"; then
    bowtie2-build -q "$V/contigs.fa" "$V/contigs_idx"
    bowtie2 -p "$THREADS" -x "$V/contigs_idx" -1 "$TRIM_DIR/${run}_1.trim.fastq.gz" -2 "$TRIM_DIR/${run}_2.trim.fastq.gz" \
        -X 800 --no-unal 2> "$V/remap.bowtie2.log" | samtools sort -@ 2 -o "$V/remap.bam" -
    samtools index "$V/remap.bam"
    samtools coverage "$V/remap.bam" > "$V/remap_coverage.tsv"
    samtools coverage -q 20 "$V/remap.bam" > "$V/remap_coverage_q20.tsv"
    # fragments per contig (R1, or R2 when R1 unmapped; primary only), all and MAPQ>=20
    for q in 0 20; do
        { samtools view -F 0x904 -f 0x40 -q $q "$V/remap.bam"; samtools view -F 0x904 -f 0x88 -q $q "$V/remap.bam"; } \
            | cut -f3 | sort | uniq -c | awk -v q=$q 'BEGIN{OFS="\t"}{print $2, q, $1}'
    done > "$V/remap_fragments_per_contig.tsv"
    mark_done "virus_remap_$run"
fi
log "Step 7 complete for $run: $V"
