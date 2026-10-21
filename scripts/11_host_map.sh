#!/usr/bin/env bash
# Step 11 — Host-read partition (nuclear / organellar / ambiguous / unmapped) and non-host pool.
#   WGS (DNA)  : Bowtie2 end-to-end --sensitive vs host.fa
#   RNA-seq    : HISAT2 (spliced) vs host.fa
# Fragment classes (one per read pair; primary alignments):
#   nuclear_confident    >=1 mate MAPQ>=20 on a nuclear sequence
#   organellar_confident >=1 mate MAPQ>=20 on NC_037358.1 (cp) or MW448460.1 (mt), none on nuclear
#   ambiguous            mapped, but no mate with MAPQ>=20 (multi-mapping/repeats/NUPT-NUMT/divergence)
#   unmapped             neither mate aligned  -> the NON-HOST POOL (written to FASTQ)
# Low MAPQ or non-alignment is NOT proof of contamination (reference divergence, unassembled
# regions, conserved sequence); the non-host pool is a set of candidates for screening only.
# Usage: bash scripts/11_host_map.sh RUN dna|rna
source "$(dirname "$0")/common.sh"
require_tools samtools python3

run="${1:?RUN}"; kind="${2:?dna|rna}"
H="$REF_DIR/host"; O="$RES_DIR/02_host/genome/$run"; mkdir -p "$O" "$DATA_DIR/nonhost"
is_done host_bt2 && is_done host_ht2 || die "run step 10 first"
t1="$TRIM_DIR/${run}_1.trim.fastq.gz"; t2="$TRIM_DIR/${run}_2.trim.fastq.gz"
bam="$O/$run.host.bam"

if ! is_done "hostmap_$run"; then
    if [[ $kind == dna ]]; then
        require_tools bowtie2
        bowtie2 -p "$THREADS" --sensitive -x "$H/bt2_host" -1 "$t1" -2 "$t2" -X 800 \
            2> "$O/$run.aligner.log" \
          | samtools view -b -o "$bam.unsorted" -
    else
        require_tools hisat2
        hisat2 -p "$THREADS" -x "$H/ht2_host" -1 "$t1" -2 "$t2" \
            2> "$O/$run.aligner.log" \
          | samtools view -b -o "$bam.unsorted" -
    fi
    samtools sort -@ 4 -m 1G -o "$bam" "$bam.unsorted" && rm -f "$bam.unsorted"
    samtools index "$bam"
    mark_done "hostmap_$run"
fi

if ! is_done "hostpart_$run"; then
    total=$(awk -F'\t' -v r="$run" '$1==r{print $3}' "$RES_DIR/01_qc/retention.tsv")
    samtools flagstat -@ 4 "$bam" > "$O/$run.flagstat.txt"
    samtools idxstats "$bam" > "$O/$run.idxstats.tsv"
    # name-sorted stream of primary records -> per-fragment class
    samtools view -h -F 0x900 "$bam" | samtools sort -n -@ 4 -m 1G -O SAM - \
      | python3 "$ROOT/scripts/lib/host_partition.py" "$run" "$total" NC_037358.1,MW448460.1 \
        > "$O/$run.host_partition.tsv"
    # Non-host pool = pairs with BOTH mates unmapped (flags 0x4 and 0x8), primary records only
    samtools collate -u -O -@ 4 "$bam" "$O/collate" | samtools view -u -f 12 -F 0x900 - \
      | samtools fastq -@ 4 -1 "$DATA_DIR/nonhost/${run}_nonhost_1.fq.gz" -2 "$DATA_DIR/nonhost/${run}_nonhost_2.fq.gz" \
          -0 /dev/null -s /dev/null -n - 2> "$O/$run.nonhost_fastq.log"
    n_pool=$(( $(zcat "$DATA_DIR/nonhost/${run}_nonhost_1.fq.gz" | wc -l) / 4 ))
    printf '%s\tnonhost_pool_fastq_pairs\t%s\t%.4f\n' "$run" "$n_pool" "$(awk -v a=$n_pool -v b=$total 'BEGIN{print 100*a/b}')" \
        >> "$O/$run.host_partition.tsv"
    samtools coverage -q 20 "$bam" -r NC_037358.1 > "$O/$run.cp_cov.tsv"
    samtools coverage -q 20 "$bam" -r MW448460.1 > "$O/$run.mt_cov.tsv"
    mark_done "hostpart_$run"
fi
log "Step 11 complete for $run: $O/$run.host_partition.tsv"
