# Methods

Software versions are in `docs/software_versions.tsv`. Every command, with its logged output, is in `logs/`, and the chronology is in `docs/agent_transcript.md`.

## 1. Data acquisition and verification
FASTQ files were downloaded from the ENA mirror. The NCBI default download is SRA-Lite, which replaces the original quality scores, whereas ENA keeps the original binned NovaSeq qualities. Each file was checked in three ways:
- its MD5 against the ENA filereport (`metadata/ena_filereport.tsv`);
- its read count against SRA `spots` (`metadata/sra_runinfo.csv`);
- mate synchronisation, by comparing R1 and R2 read IDs line by line (0 mismatches).

Raw files were then set read-only. Both runs were downloaded and verified independently on the local machine and on ASC, with identical MD5s (`results/00_verify/`).

## 2. Quality control
- FastQC 0.12.1 and MultiQC 1.35 were run on raw and trimmed reads.
- fastp 1.4.0 was run with `--detect_adapter_for_pe --trim_poly_g --cut_right --cut_right_window_size 4 --cut_right_mean_quality 15 --length_required 50 --n_base_limit 5`.
- No deduplication was applied, because duplicates are expected in RNA-seq and coverage estimates should include them.
- Retention is reported in `results/01_qc/retention.tsv`. fastp output was identical between local and ASC (same pair counts; checked by a gate in the PBS scripts).
- For local tests, a 500,000-pair subsample was drawn with `seqtk sample -2 -s 11`.

## 3. Screening (hypothesis generation)
- **NCBI STAT** (SRA Taxonomy Analysis Tool, v2.1.0): per-run JSON from the SRA Trace API (`metadata/stat_*.json`).
- **BBTools SendSketch 40.05**: R1 of the subsample against the JGI `nt` and `refseq` sketch servers.
- **Kraken2 2.17.2 + Bracken 3.0.1**: PlusPF capped at 16 GB (build 20260626), run on the non-host pools. Bracken used 150-mer distributions at species and genus level, with a threshold of 10 reads. PlusPF contains no plant genomes, so host removal comes first.

These assignments are treated as hypotheses only.

## 4. Host-read assessment
- **Organelle-only mapping (step 4).** Bowtie2 2.5.5 end-to-end against NC_037358.1 and MW448460.1, giving an "organelle-like" fraction. Nuclear plastid and mitochondrial insertions (NUPTs/NUMTs) can also map here.
- **Whole-host mapping (steps 10–11).** The reference was the *A. hypogaea* Tifrunner gnm2 assembly (RefSeq GCF_003086295.3: 20 chromosomes, 422 unplaced scaffolds and the chloroplast) plus the mitochondrion MW448460.1, 2,558,162,147 bp in total. WGS reads were aligned with Bowtie2 `--sensitive -X 800`; RNA-seq reads with HISAT2 2.2.1, without splice-site annotation.
- **Classification.** Each read pair (primary alignments) was assigned to one class:

| Class | Definition |
|---|---|
| nuclear_confident | at least one mate with MAPQ ≥ 20 on a nuclear sequence |
| organellar_confident | at least one mate with MAPQ ≥ 20 on the chloroplast or mitochondrion, and none on nuclear |
| ambiguous | aligned, but no mate with MAPQ ≥ 20 |
| unmapped | neither mate aligned; this is the **non-host pool** |

Low MAPQ was never treated as contamination. Most organellar reads are ambiguous because near-identical plastid-like sequence exists elsewhere in the assembly, and the allotetraploid A/B subgenomes make many nuclear reads ambiguous too.

## 5. Competitive validation (steps 5–6, 13)
Each panel (`config/validation_panel*.tsv`) combines:
- candidate genomes;
- close competitors (other isolates, species or genera);
- for the full-read panel, a host decoy: *A. hypogaea* RefSeq transcripts and the organelles.

Validation then ran in two stages:
- **Stage A, competitive assignment.** Bowtie2 `--local -X 800` against the whole panel. Each pair is assigned to the reference of its higher-scoring mate's primary alignment. Reported per group and per reference:
  - fragments and MAPQ ≥ 20 fragments;
  - mean and median identity, where identity = (aligned columns − NM) / aligned columns;
  - the share of fragments aligned over ≥ 80% of the read.
- **Stage B, coverage.** The fragments of each group were realigned to that group's best-supported reference alone, and `samtools coverage` / `samtools depth -a` gave length-weighted mean depth and breadth at ≥ 1×, 5× and 10×.

Low MAPQ inside a group of near-identical isolates (BCMV) is expected. It doesn't weaken the group-level call, which depends on beating the decoy and the other genera.

## 6. Gene-level support (step 9)
For cellular organisms in RNA-seq, genome breadth is uninformative. Stage-A fragments were therefore split into a high-identity stratum (identity ≥ 0.98 and ≥ 80% aligned) and the rest. Each stratum was realigned to one annotated genome and counted per gene using the RefSeq GFF3 gene features, with the fraction falling on rRNA genes reported.

## 7. RNA-virus investigation (steps 7–8)
1. Fragments assigned to the potyvirus and polerovirus groups were assembled with MEGAHIT 1.2.9 (minimum contig 300 bp).
2. Contigs were compared with:
   - the panel's virus references, by BLASTn 2.17.0 (e ≤ 1e-10);
   - RefSeq viral proteins r237, by DIAMOND blastx `--sensitive`;
   - Pfam RdRp HMMs (HMMER 3.4), using `hmmsearch` on 6-frame translations.
3. **All** trimmed pairs were remapped to the contigs (Bowtie2 end-to-end) to measure support and coverage.
4. Chimeric contigs were identified by BLASTn of their non-viral parts against the host transcripts. Junction support was counted as end-to-end reads with ≤ 2 mismatches spanning ≥ 20 bp on each side, plus discordant virus/host read pairs.
5. Per-protein amino-acid identities of the polerovirus contig against CPPV2 and other poleroviruses came from tblastn of GenBank CDS translations.
6. CheckV and geNomad were not used (the student chose the minimal toolchain).

## 8. Human (step 14) and k-mer/host cross-check (step 15)
- **Human (step 14).** The non-host pools were aligned to GRCh38 (`GRCh38_full_as`, Bowtie2 `--sensitive`). "Human-confident" means MAPQ ≥ 20 and identity ≥ 0.98.
- **k-mer/host cross-check (step 15).** Kraken2 was run on all trimmed WGS pairs. Pairs assigned to Bacteria (exactly to the domain, and anywhere in the Bacteria clade) were cross-tabulated with their step-11 host class, as a read-level test of the STAT domain-level "Bacteria" signal.

## 9. Counting units and denominators
- The counting unit is a **fragment**: one read pair, counted once and never per mate.
- `pct_of_analyzed` = fragments / trimmed pairs (`retention.tsv`).
- `pct_of_nonhost` = fragments that lie in the non-host pool / non-host pool pairs (step 11).
- `pct_candidate_hits` (Stage A tables only) = fragments / all non-decoy panel assignments.

STAT counts are reads over the raw spots, Kraken2/Bracken counts are pairs within the non-host pool, and SendSketch reports ANI and WKID on a 500k-pair subsample, so these numbers are not directly comparable with each other.

## 10. Detection confidence rule (not significance)
| Level | Rule |
|---|---|
| high | at least 2 independent screens agree, ≥ 1,000 supporting fragments, and either viral breadth ≥ 90% at ≥ 10× or ≥ 100 distinct genes with ≥ 5 fragments |
| moderate | at least 2 screens agree and ≥ 100 fragments |
| low | otherwise |

Significance bins and likely sources are the student's decision.
