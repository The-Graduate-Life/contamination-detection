# Agent transcript — Contamination Detection Practical

Chronological record of planning, decisions, commands and outcomes. Raw command output lives in `logs/`.
Datasets: **SRR39022911** (WGS) and **SRR29854842** (RNA-seq), *Arachis hypogaea*.

## 2026-10-20 — Session 1

### 1. Environment audit (read-only)
- Local: WSL2 Ubuntu 24.04.1, i7-1165G7 (4 cores / 8 threads), **4.8 GiB RAM** (`.wslconfig memory=5GB`, Windows host 7.7 GB), 8 GB swap, 924 GB free disk.
- Conda: Miniforge, conda 26.3.2 + mamba; only `base` env. No bioinformatics tools on PATH (only pigz, java 21, git, bcftools 1.19, python 3.12 without pandas).
- No reusable Kraken2/geNomad/CheckV databases or peanut gnm2 reference found. Old Snakemake envs on `/mnt/c` judged not reusable (other project, slow mount).

### 2. Dataset verification (NCBI runinfo, BioSample, BioProject, ENA filereport, NCBI STAT)
| | SRR39022911 | SRR29854842 |
|---|---|---|
| Library | WGS / RANDOM / GENOMIC / PAIRED | RNA-Seq / cDNA / TRANSCRIPTOMIC / PAIRED |
| Tissue, origin | leaf, Burkina Faso (CCH119) | root nodule, Fuzhou, China (IPN_3) |
| BioProject | PRJNA1475457 (peanut mini-core GWAS) | PRJNA1136701 (intercropping; roots/nodules/seeds) |
| Platform (metadata) | NovaSeq 6000 | HiSeq 2500 — **read headers `A02036:…:H2FJ5DSX7` indicate NovaSeq; discrepancy recorded** |
| Spots / bases | 9,726,260 / 2,664,995,240 (~1.0x of 2.56 Gb genome) | 21,801,972 / 6,474,020,056 |

- NCBI default download is SRA-Lite (simplified qualities); ENA FASTQ.gz retain original binned qualities and provide MD5s.
- STAT (v2.1.0) JSON saved to `metadata/stat_<run>.json` (endpoint required `cluster_name=public`). Key hypotheses, not detections:
  - WGS: 255,756 reads (2.63%) resolved only to domain *Bacteria* (hypothesis: organellar rRNA); *Klebsiella pneumoniae* 1,051; *Stenotrophomonas* 619; *Aeromonas caviae* 392.
  - RNA: *Fusarium* 435,254 (2.00%); *Potyvirus phaseovulgaris* (BCMV) 121,753 (0.56%); Polerovirus CPPV2 2,164; *Bradyrhizobium* 4,671; *Homo sapiens* 3,905; *Capra hircus* 1,057.

### 3. Decisions
- Plan presented with approval checkpoints. User initially chose all-HPC (ASC), then Easley; SSH to `easley.auburn.edu` timed out (likely VPN required).
- **User decision:** build the environment locally and run the local part first; HPC later.
- **User authorization:** agent may create the `contam` env with the exact proposed specification (overrides the default "user installs" rule for this env only).

### 4. Environment build
Command (log: `logs/env/contam_create.log`):
```bash
mamba create -n contam -y -c conda-forge -c bioconda --strict-channel-priority \
  python=3.11 "sra-tools>=3.1" entrez-direct ncbi-datasets-cli \
  fastqc=0.12.1 "multiqc>=1.25" "fastp>=0.24" "seqkit>=2.8" seqtk \
  "samtools>=1.21" "bowtie2>=2.5.4" hisat2=2.2.1 "minimap2>=2.28" mosdepth \
  "kraken2>=2.1.3" "bracken>=2.9" krakentools "bbmap>=39" \
  megahit=1.2.9 "spades>=4.0" "diamond>=2.1.9" "hmmer>=3.4" "blast>=2.16" \
  pigz pandas matplotlib
```
- Result: exit 0 (2026-10-20 20:36). Versions verified (`logs/env/contam_versions.txt`; manifest `docs/software_versions.tsv`): sra-tools 3.4.1, FastQC 0.12.1, MultiQC 1.35, fastp 1.4.0, seqkit 2.14.0, seqtk 1.5, samtools 1.24, Bowtie2 2.5.5, HISAT2 2.2.1, minimap2 2.31, mosdepth 0.3.14, Kraken2 2.17.2, Bracken 3.0.1, BBTools 40.05, MEGAHIT 1.2.9, SPAdes 4.3.0, DIAMOND 2.2.8, HMMER 3.4, BLAST+ 2.17.0, datasets 18.39.0, EDirect 26.0, Python 3.11.17.
- Note: Bowtie2 prints `Failed to launch x86-64-v3 version, staying with default` — the conda build lacks the optimised binary; the generic binary is used (affects speed only).
- Exported `environment.yml` (`--no-builds`) and an explicit lock file `logs/env/contam_explicit_lock.txt`.
- fastp 1.4.0 option names used in step 2 checked against `fastp --help` (all present).
- Optional `contam-virus` env (geNomad/CheckV) **not** built — deferred until the virus step.

### 5. Phase 1 — download and verification (local; authorised by "let's do the local part first")
Script: `scripts/01_download_verify.sh` (ENA HTTPS, MD5 vs ENA, counts vs SRA spots, R1/R2 ID sync, raw files set read-only).
- Download initially launched as one sequential job (~1 MB/s); a second per-run job for SRR29854842 was started to parallelise. Because the first job would later also have fetched SRR29854842 (risk of two `wget -c` writers on one file), it was stopped (`TaskStop`) during the WGS R1 transfer and relaunched as `01_download_verify.sh SRR39022911`; `wget -c` resumed the partial file. Integrity confirmed by MD5 below.
- **SRR39022911 verified (21:07):** MD5 R1 `f1eac8bf…` and R2 `0c8ed4a4…` match ENA; R1 = R2 = 9,726,260 reads = SRA spots; 0 read-ID mismatches between mates. Raw files set read-only.
- Known cosmetic issue: `seqkit stats` progress bar floods the log; to be silenced after the running job completes (editing a script while bash executes it is unsafe).

### 6. Phase 2 — QC / trimming (SRR39022911 started 21:07 while SRR29854842 downloads)
Script: `scripts/02_qc_trim_subsample.sh` — fastp `--detect_adapter_for_pe --trim_poly_g --cut_right --cut_right_window_size 4 --cut_right_mean_quality 15 --length_required 50 --n_base_limit 5` (no deduplication); seqtk `sample -2 -s 11` 500,000 pairs from trimmed reads.
- **Error (21:19):** FastQC failed on trimmed reads: `java.util.zip.ZipException: Not in GZIP format`. Cause: fastp selects gzip output from the file extension; temporary outputs were named `*.trim.fastq.gz.tmp`, so fastp wrote plain FASTQ that was then renamed to `.gz`. `set -euo pipefail` stopped the script (exit 1) before subsampling.
- **Resolution:** the fastp output content was valid (inspected first records), so it was compressed in place with `pigz -p 6` and checked with `pigz -t` (OK) instead of re-running fastp. Script fixed: temp names now end in `.tmp.fastq.gz`, and `pigz -t` validates outputs before marking the step done. Step resumed from the trimmed-read FastQC via completion markers.
- **SRR29854842 verified (21:33):** MD5 R1 `a5303be1…` and R2 `ac5f87a8…` match ENA; R1 = R2 = 21,801,972 reads = SRA spots; 0 read-ID mismatches. Raw files set read-only. Checksums: `results/00_verify/checksums.md5`; counts: `results/00_verify/read_counts.tsv`.
- Script 01: `seqkit stats --quiet` added to suppress progress-bar log flooding.
- SRR29854842 step 2 started 21:34 (uses the fixed fastp temp naming), concurrently with the SRR39022911 resume.
- **SRR39022911 step 2 complete (21:36).** `results/01_qc/retention.tsv`: 9,726,260 → 8,497,015 pairs (87.36%); bases 83.95%; Q30 0.8645 → 0.9020. fastp filter reasons (reads): too_short 2,281,960; low_quality 168,514; adapter_dimer 7,268; too_many_N 748. R1 length 131, R2 143 (asymmetric run). Auto-detected R2 adapter `GATCGTCGGACTGTAGAACTCTGAACGTGTAGA` (reverse complement of the Illumina small-RNA 5′ adapter, unusual for a WGS library — recorded, not interpreted). Most loss = reads shortened below 50 bp (short inserts / adapter read-through); flagged as a limitation (short fragments are excluded from screening).
- Subsample: 500,000 pairs, seed 11 (`results/01_qc/SRR39022911.subsample_stats.tsv`).

### 7. Step 3a — SendSketch (SRR39022911, R1 of subsample)
Script `scripts/03_sendsketch.sh`; servers nt and refseq (BBTools 40.05, 2026-10-20 21:37). Note `printdepth` columns are not emitted in `format=3`.
- Top hits: *Arachis hypogaea* (refseq ANI 99.65%, WKID 90.6%), other *Arachis* spp.; many ~100–170 kb *Arachis*/legume references = chloroplast genomes (organellar signal, as expected for leaf DNA).
- Non-plant hits (lineage via NCBI Taxonomy efetch): *Enterococcus faecalis* (refseq; ANI 80.6%, KID 0.233%, WKID 0.260%) and *Eimeria acervulina* (refseq; ANI 73.5%, KID 0.026%). Both have low ANI → shared k-mers, not a close genome match; treated as weak hypotheses. *E. faecalis* is noted alongside STAT's 1,608 reads assigned only to order Lactobacillales.
- **SRR29854842 step 2 complete (22:07).** 21,801,972 → 21,444,624 pairs (98.36%); bases 97.97%; Q30 0.9569 → 0.9648. Filter reasons (reads): too_short 685,228; low_quality 21,544; adapter_dimer 5,074; too_many_N 2,850. No adapter auto-detected (PE overlap trimming; 13,690 reads adapter-trimmed). fastp duplication estimate 41.6% — expected for RNA-seq (highly expressed transcripts); no deduplication applied. Subsample 500,000 pairs, seed 11.
- MultiQC (both runs): `results/01_qc/multiqc_report.html`; retention: `results/01_qc/retention.tsv`.

### 8. Step 3a — SendSketch (SRR29854842, R1 of subsample, 22:14)
- Top hits *Arachis duranensis* (nt ANI 97.7%) and *A. hypogaea* (nt ANI 99.0%, WKID 75.0%).
- Non-plant hits (lineage via NCBI Taxonomy):
  - ***Fusarium oxysporum* species complex**: *F. oxysporum* NRRL 32931 (nt ANI 87.9%, KID 1.58%, WKID 2.94%), *F. odoratissimum* (ANI 87.8%), *F. oxysporum* f. sp. *lycopersici* 4287 (refseq ANI 88.0%); weaker hits to other *Fusarium* spp. (ANI 78–85%). ANI ~88% to every reference → the organism may not be any sequenced strain; sketch ANI from transcript k-mers is also biased (hypothesis).
  - ***Peanut stripe virus*** (nt; ANI 95.0%, KID 0.052%, **WKID 24.3%**) — independent support for STAT's *Potyvirus phaseovulgaris* (BCMV) signal.
  - Weak (ANI < 82%): *Talaromyces* spp., *Cutibacterium acnes*, *Enterococcus faecalis*, *Bradyrhizobium guangxiense/guangzhouense*, *Streptomyces*, *Arthrobacter*, *Staphylococcus epidermidis*, uncultured *Mycobacterium* (nt ANI 88.3%, WKID 3.2%, KID 0.029%).
- Checkpoint reached: local Phases 1–3a complete for both runs.

## 2026-10-20 — Checkpoint 1 decision
User approved: (1) organelle mapping, (2) competitive validation of the strongest RNA-seq candidates (potyvirus, *Fusarium*, *Bradyrhizobium*), (3) targeted virus assembly; **minimal virus tools** only (no geNomad/CheckV for now).

### 9. Step 4 — organelle mapping
Script `scripts/04_organelle_map.sh`: Bowtie2 end-to-end (default sensitivity, `-X 800`, `--no-unal`) against NC_037358.1 + MW448460.1; fragment-level counts (one record per pair, primary alignments), MAPQ≥20 subsets, `samtools coverage -q 20 -Q 20`. Denominator = trimmed pairs (`retention.tsv`).
- Launch error: the first `nohup … > logs/04_organelle/run.log` failed because the log directory did not exist yet (the script creates it, but the shell redirect is evaluated first). Directory created and job relaunched (22:20). The same mistake recurred for step 5 and was fixed the same way.
- **SRR39022911 organelle result (22:24):** 887,167 / 8,497,015 trimmed pairs (10.44%) organelle-like; 830,999 proper pairs; 513,855 (6.05%) MAPQ≥20. Chloroplast 749,004 (8.81%; MAPQ≥20 410,978), mitochondrion 138,163 (1.63%; MAPQ≥20 102,877). Coverage (MAPQ≥20, baseQ≥20): chloroplast mean depth 660x, breadth 76.8%; mitochondrion 43.8x, breadth 97.2%. Low chloroplast MAPQ≥20 breadth is expected: the two inverted-repeat copies are identical (MAPQ 0). Organelle depth (~660x cp, ~44x mt) vs ~0.9x nuclear shows a large organellar DNA share in leaf tissue.
- Interpretation status: the organelle-like fraction (10.4%) is large enough to contain STAT's 255,756 domain-only "Bacteria" reads (2.63% of raw reads), so the organellar hypothesis is **consistent but not yet tested read-by-read** (STAT gives no per-read assignments). Planned direct test: classify organelle-mapped reads with Kraken2 (HPC phase) or BLAST a sample.

### 10. Step 5 — validation panel (`config/validation_panel.tsv`, `scripts/05_fetch_validation_refs.sh`)
30 entries: 10 potyvirus (5 BCMV/peanut stripe candidates incl. two isolates from *A. hypogaea* leaves; competitors PeMoV, BCMNV, SMV, CABMV, BYMV), 5 polerovirus (CPPV2 candidate; GRAV, PBMYV, BrYV-from-peanut, ArMoV competitors), 6 *Fusarium* genomes (3 *F. oxysporum* species complex candidates; *F. verticillioides*, *F. vanettenii*, *F. graminearum* competitors), 7 *Bradyrhizobium* complete genomes (peanut symbionts *B. arachidis*, *B. guangxiense*, *B. guangzhouense*, *B. zhanjiangense*, *B. yuanmingense*; *B. elkanii*, *B. diazoefficiens* competitors), host decoy = *A. hypogaea* RefSeq transcripts (GCF_003086295.3) + organelles. Manifest with MD5s: `references/validation/manifest.tsv`.
- **SRR29854842 organelle result (22:31):** 60,530 / 21,444,624 trimmed pairs (0.28%) organelle-like; MAPQ≥20 32,483 (0.15%). Chloroplast 24,408 (only 1,436 MAPQ≥20 — most fall in the duplicated inverted repeat, which carries the rRNA operons), mitochondrion 36,122 (31,047 MAPQ≥20). Coverage (MAPQ≥20): cp 2.5x / 43.4% breadth, mt 15.1x / 45.2%. Low organellar share is consistent with non-photosynthetic nodule tissue and likely poly(A) enrichment (library selection is recorded only as "cDNA" — unverified).
- Panel fetched (22:26): 174,035 sequences, 644,790,175 bp (296 Mb is host-transcript decoy). Bowtie2 index build started (`scripts/06_validate_candidates.sh SRR29854842 sub` = build + 500k-pair timing test).

### 11. Step 7a — virus databases (`scripts/07a_virus_dbs.sh`)
NCBI RefSeq viral proteins (release 237, `viral.1.protein.faa.gz`, 107 MB) → DIAMOND db; Pfam RdRp HMMs via InterPro API (PF00680, PF02123, PF00978, PF00998, PF05919, PF00946) → `hmmpress`. Versions/MD5s in `databases/virus/VERSIONS.tsv`.
- Step 7a complete (22:38): DIAMOND db 722,738 RefSeq viral proteins (175,001,826 letters, release 237); 6 Pfam RdRp HMMs pressed.

## User instruction: "continue, run the full mapping after the subsample test"
- Chained job: waits for the 500k-pair test (`06_validate_candidates.sh SRR29854842 sub`); starts the full-depth run only if the test's Stage B completion marker exists.
- **User change:** full-depth validation mapping moves to the Alabama Supercomputer (ASC) after the local subsample test. The chained local full run was cancelled (`TaskStop`) before it started; the subsample test continues locally.

### 12. Step 6 — local 500k-pair subsample test (SRR29854842, seed 11)
- Panel index build finished 22:55 (~25 min, 6 threads). Stage A 22:55→23:04 (9.3 min for 500k pairs) ⇒ ~6.7 h projected locally for 21.4M pairs — justifies moving the full run to ASC.
- Stage A Bowtie2 `--local`: 95.63% overall alignment rate (most to host decoy).
- Fragment assignment (`results/04_validation/SRR29854842.sub/*.group_summary.tsv`; denominators: 500,000 subsampled trimmed pairs; candidate-hit pool 15,814):
  | group | fragments | % pairs | MAPQ≥20 | mean identity | aligned≥80% | best label |
  |---|---|---|---|---|---|---|
  | host_decoy | 464,176 | 92.84 | 66,033 | 0.9983 | 98.9% | Ahyp RefSeq transcripts |
  | fusarium | 11,459 | 2.29 | 457 | 0.9909 | 94.1% | Fol_4287 (then Fod_NRRL54006, Fox_NRRL32931) |
  | potyvirus | 3,402 | 0.68 | 0 | 0.9978 | 99.9% | BCMV_P02_peanut (then BCMV_Jeonju-1_peanut) |
  | bradyrhizobium | 861 | 0.17 | 23 | 0.9240 | 71.7% | Bgz_CCBAU51670 (labels spread evenly) |
  | polerovirus | 92 | 0.018 | 63 | 0.9410 | 100% | CPPV2_RefSeq |
- Observations (not conclusions): MAPQ≈0 within potyvirus/*Fusarium* reflects near-identical isolates/species-complex members competing; *Bradyrhizobium* hits are divergent (≈92% identity) and often partial → conserved-gene cross-mapping not excluded; polerovirus reads align full-length at ≈94% identity to CPPV2.

### 13. ASC setup (account aubfxp001, asax.asc.edu; scratch only per user)
- Access via user-opened SSH ControlMaster socket. Read-only audit saved to `logs/asc_audit_2026-10-20.txt`: Rocky Linux 9.6; PBS (`qsub`; ASC `run_script` is an interactive wrapper around qsub); queues incl. `medium` (≤16 cpus, 16 GB, 150 h), `large` (≤128 cpus, 120 GB); scratch `/scratch/aubfxp001` (panfs); internet available on login node; Anaconda modules (conda 25.7, mamba 2.0.3), no user `.condarc`.
- Pre-existing items in `/scratch/aubfxp001` (`contam_stageB/`, `db/`, `asc_bundle.tar.gz`, `week7/`) were **not** read, reused or modified; all work is in `/scratch/aubfxp001/contamination_detection`.
- Project `condarc` (conda-forge, bioconda, strict; pkgs/envs in scratch). Code-only rsync of repo (no data).
- Env build: `mamba env create -p …/conda/envs/contam -f environment.yml` failed (`mamba binary not found. Please set MAMBA_ROOT_PREFIX`); switched to the module's `conda env create` (libmamba solver) without loading the module (avoids its MPI/CUDA `LD_LIBRARY_PATH` additions). Solve succeeded; install in progress (log `logs/env/contam_create_asc.log` on ASC).
- PBS scripts written in `pbs/` (`asc_env.sh`, `02_qc_rna.pbs`, `06_validate_rna.pbs`, `07_virus_rna.pbs`); standard `qsub` with the same options run_script uses (`-j oe -r n`), `medium` queue. Not submitted — awaiting user approval.
- Subsample Stage B finished 23:09 (`results/04_validation/SRR29854842.sub/SRR29854842.sub.coverage.tsv`), realigning each group's Stage A fragments to its best label:
  | group | reference | length | breadth ≥1x | mean depth | ≥5x | ≥10x | fragments | mean identity |
  |---|---|---|---|---|---|---|---|---|
  | potyvirus | BCMV_P02_peanut (OR734859.1) | 10,041 | 88.3% | 99.5 | 47.4% | 25.1% | 3,398 | 0.9950 |
  | polerovirus | CPPV2_RefSeq (NC_034247.1) | 5,945 | 92.2% | 4.4 | 48.5% | 2.1% | 91 | 0.9317 |
  | fusarium | Fol_4287 (GCF_000149955.1) | 61.4 Mb | 2.2% | 0.05 | 0.18% | 0.05% | 10,819 | 0.9863 |
  | bradyrhizobium | Bgz_CCBAU51670 | 8.1 Mb | 0.18% | 0.02 | 0.05% | 0.05% | 693 | 0.9199 |
- Potyvirus depth profile (500-bp bins): ~1–6x over positions 1–7,500, rising to 60x (8.5–9 kb), 414x (9–9.5 kb) and 1,436x (9.5–10 kb). Strong 3′ bias, consistent with oligo-dT/poly(A)-based library preparation acting on a polyadenylated potyvirus genome (library protocol not documented in metadata). 1,028 of 6,780 primary records are soft-clipped (local mode).
- Low *Fusarium* breadth is expected for RNA-seq (only expressed genes are sampled); breadth is therefore not an informative criterion for the fungus in this dataset, whereas the number of distinct genes hit would be (to compute at full depth).

## User approval: "Yes, run downloads and submit jobs"
- 23:12 ASC login node: raw-read download for SRR29854842 started with system `wget -c` (no env needed) into `$PROJ/data/raw`; `01_download_verify.sh` will verify MD5/counts/pairing once the env is ready. (A misplaced `&` backgrounded the whole `cd && mkdir && nohup` chain, so the follow-up `ls` ran from `$HOME`; the download itself started correctly — confirmed.)
- `pbs/06_validate_rna.pbs`: added reproducibility gate — aborts unless ASC trimmed pairs = 21,444,624 (local value).
- ASC env build finished 23:22 (exit 0; ~20 min). Versions verified via `pbs/asc_env.sh` — identical to local for all tools (`logs/env/contam_versions_asc.txt`); binaries resolve to the scratch prefix.
- 23:24 ASC login node: `05_fetch_validation_refs.sh` then `07a_virus_dbs.sh` started (THREADS=4, network-bound); raw download R1 complete-size reached, R2 in progress.
- ASC login-node results (23:46): raw R1/R2 downloads exit 0; `07a_virus_dbs.sh` exit 0; **`05_fetch_validation_refs.sh` exit 1** — `cat: references/organelles/NC_037358.1.fasta: No such file or directory`. Cause: the organelle FASTAs had been fetched locally by an ad-hoc `efetch` command (§9) that was never scripted, and `references/` is not synced. **Fix:** added `fetch_organelles()` to `scripts/common.sh` (efetch NC_037358.1, MW448460.1 when absent) and called it from steps 04 and 05, closing the reproducibility gap. Step 05 re-run (cached downloads reused) followed by `01_download_verify.sh SRR29854842`.
- Transient `curl: (56) OpenSSL SSL_read … unexpected eof` messages from EDirect on both machines; EDirect retried and the records were retrieved (FASTA validity is checked by the script).
- 23:48 ASC verification: step 05 exit 0 (174,035 seqs, 644,790,175 bp — same as local); **all 30 panel files and `panel.fasta` MD5-identical to local** (`ee29e3901bbe845a02a09b60ceb4a0ee`). Step 01: SRR29854842 MD5 OK (both mates), 21,801,972 pairs = SRA spots, 0 ID mismatches.

### 14. ASC job submission (user-approved) — 2026-10-20 23:49
`qsub` chain in `/scratch/aubfxp001/contamination_detection` (queue `medium`; record `logs/asc_jobs.txt`):
- `105462.asax-pbs1` cd_qc_rna (8 cpu, 8 GB, 4 h) — fastp/QC/subsample
- `105463.asax-pbs1` cd_val_rna (16 cpu, 16 GB, 24 h; `afterok:105462`) — panel index + full Stage A/B, gated on trimmed pairs = 21,444,624
- `105464.asax-pbs1` cd_virus_rna (16 cpu, 16 GB, 12 h; `afterok:105463`) — MEGAHIT, BLASTn/DIAMOND/hmmsearch, full remap
- Chain result (00:09): **105462 QC exit 0**; reproducibility gate passed — ASC fastp gave **21,444,624 trimmed pairs, identical to local**. **105463 exit 127**: `/usr/bin/time: No such file or directory` (GNU time not installed on ASC nodes; not covered by the env version check). **105464 ran anyway and exit 1** (`run step 6 (full) first`): every PBS script ended with `echo "exit $?"`, so the job's own exit status was 0 and PBS released the `afterok` dependant.
- **Fixes:** PBS scripts now `exit $rc` with the real status; step-6 job uses the bash `time` builtin (peak memory from `qstat -xf resources_used.mem`). No analysis outputs were affected (validation never started).
- Resubmitted 00:10: `105466.asax-pbs1` cd_val_rna, `105467.asax-pbs1` cd_virus_rna (`afterok:105466`).
- **105466 cd_val_rna exit 0** (00:29→01:37; wall 68 min, CPU 13.4 h, peak mem 6.45 GB, asax008). **105467 cd_virus_rna exit 0** (5 min, 0.7 GB). Results rsynced back (tables/logs only; BAM/FASTQ/indexes stay on ASC) to `results/04_validation/SRR29854842/`, `results/05_virus/SRR29854842/`, `logs/asc/`.

### 15. Full-depth validation results — SRR29854842 (denominator: 21,444,624 trimmed pairs; candidate-hit pool 682,406 fragments)
Stage A (Bowtie2 --local, 95.63% overall alignment):
| group | fragments | % trimmed | MAPQ≥20 | mean id | aligned≥80% | best label |
|---|---|---|---|---|---|---|
| host_decoy | 19,904,228 | 92.817 | 2,821,624 | 0.9983 | 98.9% | Ahyp RefSeq rna |
| fusarium | 491,970 | 2.294 | 20,139 | 0.9909 | 94.1% | Fol_4287 (191,627) > Fod_NRRL54006 (157,059) > Fox_NRRL32931 (115,993); Fve/Fva/Fgr 6.6–12.6k |
| potyvirus | 148,658 | 0.693 | 9 | 0.9978 | 99.8% | BCMV_P02_peanut 86,297; Jeonju-1_peanut 34,098; PSt_Laixi 18,393; PSV_U05771 9,857; non-BCMV competitors ≤8 |
| bradyrhizobium | 37,909 | 0.177 | 1,011 | 0.9244 | 73.3% | Bgz 8,226 (median id 0.92); **Bgx_CCBAU53363 4,153 with median id 0.9933, 83.9% full-length** |
| polerovirus | 3,869 | 0.018 | 2,762 | 0.9408 | 98.2% | CPPV2 3,801; PBMYV 68 |
Stage B (realignment to best label):
| reference | breadth ≥1x | mean depth | ≥5x | ≥10x | fragments | mean id |
|---|---|---|---|---|---|---|
| BCMV_P02_peanut OR734859.1 (10,041) | 99.95% | 4,337 | 99.93% | 99.84% | 148,365 | 0.9951 |
| CPPV2 NC_034247.1 (5,945) | 95.81% | 180.2 | 95.73% | 95.73% | 3,744 | 0.9307 |
| Fol_4287 (61.4 Mb) | 13.75% | 2.10 | 6.27% | 3.60% | 465,375 | 0.9863 |
| Bgz_CCBAU51670 (8.1 Mb) | 2.12% | 0.93 | 0.40% | 0.11% | 30,541 | 0.9207 |
Observation: *Bradyrhizobium* group is heterogeneous — most hits ≈91–92% identity (conserved-gene cross-mapping candidates), but the *B. guangxiense* subset is ≈99.3% identity; Stage B used Bgz (most fragments), which is not the best representative. Needs an identity-stratified re-analysis.

### 16. Targeted virus assembly — SRR29854842 (MEGAHIT 1.2.9 on Stage A potyvirus+polerovirus fragments)
6 contigs (18,884 bp; N50 10,216).
- **k141_4 (10,216 nt)**: BLASTn 99.29% id to BCMV OR734859.1 (*A. hypogaea* isolate) over 9,985 nt (98% qcov); DIAMOND 88.3% aa id to BCMV RefSeq polyprotein NP_570723.1 (bean isolate); RdRP_1 (PF00680) domain E=6e-83 (HMM 11–449/450). Remap of all trimmed pairs: 154,038 fragments (129,004 MAPQ≥20), 99.93% breadth, mean 4,324x.
- **k141_5 (5,851 nt)**: BLASTn **92.36% nt id** to CPPV2 NC_034247.1 over 5,718 nt (97% qcov); DIAMOND 89.9% aa id to CPPV2 read-through protein YP_009352255.1; RdRP_4 (PF02123) E=4.3e-91 (HMM 3–462/465). Remap: 4,254 fragments (4,233 MAPQ≥20), 100% breadth, mean 211x. Divergence is near commonly used *Polerovirus* species-demarcation thresholds (ICTV: >10% aa difference in any gene product) — per-ORF aa comparison needed before any statement; not interpreted here.
- **k141_0–k141_3 (561–846 nt): virus–host chimeras.** Each has a BCMV 3′-region segment (genome positions ~9,100–9,960; BLASTn 98.6–99.5%) joined to host sequence (BLASTn vs *A. hypogaea* RefSeq rna, local db): k141_0 and k141_1 → 18S rRNA (XR_003816679.1), k141_2 → 28S rRNA (XR_003816680.1), k141_3 → *Lea5* mRNA (XM_025755471.2). Their large remap counts (35k–212k fragments; up to 77,000x) are host rRNA reads and **must not be counted as virus support**. Origin hypotheses: library chimeras vs assembler joins across chimeric reads — testable by counting read pairs with one mate on BCMV and the other on host rRNA in the Stage A BAM (on ASC).

## 2026-10-21 — Follow-ups (user: "continue with the next steps")
- 04:13 ASC ControlMaster socket had expired (opened ~22:57). An ssh call without `BatchMode=yes` fell back to interactive password auth and failed (`Too many authentication failures`; no credentials were sent). **Correction:** all ASC commands now use `-o BatchMode=yes` after an `-O check`. User asked to reopen the socket; A2–A4 run locally meanwhile.

### 17. A2 — polerovirus per-protein comparison (`scripts/08_polerovirus_orfs.sh SRR29854842 SRR29854842_k141_5`)
tblastn of annotated reference proteins (GenBank `fasta_cds_aa`) vs contig k141_5. Output `results/05_virus/SRR29854842/polerovirus_orfs/per_protein_identity.tsv`.
- vs **CPPV2 NC_034247.1**: P0 83.5% aa (261 aa, 100% of protein), P1 89.9% (100%), P1-P2 fusion 96.3% (P2/RdRp part; frameshift region aligned separately), P3a 93.5%, coat protein 98.5%, movement protein 91.5%, read-through protein 92.7%.
- Next closest: Soybean chlorotic leafroll virus NC_117245.1 (P1-P2 85.8%, P0 46.1%), Phasey bean mild yellows virus NC_028793.2 (RdRp 85.2%, P0 45.6%); GRAV, ArMoV, CpCSV, PeVYV, CABYV ≤ 65% on P1-P2.
- Evidence statement only: aa differences vs the single complete CPPV2 genome exceed 10% for P0 (16.5%) and P1 (10.1%). Commonly cited polerovirus species criterion = >10% aa difference in any gene product (current ICTV wording not re-checked here). Caveats: one complete CPPV2 reference; tblastn local alignments, not curated ORFs. Species-level conclusion left to the user.

### 18. A1 — chimera test (ASC, Stage A BAM and contig remap BAM; `logs/asc/a1_chimera_test.txt`)
- Mates of the 297,350 primary BCMV-mapped records: BCMV 294,902 (99.18%); other host transcripts 2,129 (0.72%); **18S/28S rRNA 25 (0.008%)**, 23 of them at BCMV 9–10 kb; mate unmapped 162; *Fusarium* 125; *Bradyrhizobium* 7.
- End-to-end reads (≤2 mismatches) spanning ≥20 bp either side of each chimeric-contig junction: k141_0 = 2, k141_1 = 4, k141_2 = 1, k141_3 = 0, versus 1–36,479 reads overlapping the junction position from one side.
- Evidence summary: the virus–host contigs are supported by only a handful of junction reads/pairs located in the most abundant viral region (3′ end) and the most abundant host RNAs (rRNA) — the pattern expected when rare chimeric molecules are joined by the assembler. Source attribution (library chimera vs alternatives) left to the user.

### 19. A3 — *Bradyrhizobium* gene-level support (`scripts/09_gene_level_support.sh SRR29854842 bradyrhizobium Bgx_CCBAU53363 GCF_004114915.1 0.98`)
- Stage A *Bradyrhizobium* fragments split: 8,230 with identity ≥0.98 and ≥80% aligned ("high"), 29,679 others.
- High stratum realigned to *B. guangxiense* CCBAU 53363: 8,195 fragments; 338 of 7,842 annotated genes hit (47 with ≥5 fragments); **86.65% of fragments on rRNA genes**, 2.01% intergenic. Non-rRNA genes include transporters, cold-shock protein, LptD, ribosomal protein L10, and **nitrogen-fixation genes *nifE* (3), *nifB* (3), *nifA* (2), *nifN* (2)** plus hydrogenase chaperone HybE (4).

### 20. Phase B — host genome & non-host screening (ASC)
New scripts: `10_host_reference.sh` (GCF_003086295.3 incl. chloroplast NC_037358.1 + mitochondrion MW448460.1; Bowtie2 + HISAT2 indexes, HISAT2 without splice annotation by default), `11_host_map.sh` (Bowtie2 `--sensitive` for WGS, HISAT2 for RNA; fragment classes nuclear_confident / organellar_confident / ambiguous / unmapped via `lib/host_partition.py`; **non-host pool = pairs with both mates unmapped**, extracted from the BAM), `12_kraken2.sh` (Kraken2 PlusPF-16 `k2_pluspf_16_GB_20260626` + Bracken at nearest read length). Partition logic tested on the local WGS organelle BAM (887,167 fragments, = step 4 count). Initial draft used `--un-conc` (includes pairs with one mate aligned) and an invalid HISAT2 flag — both replaced before use.
PBS jobs generated in `pbs/` (cd_qc_wgs with reproducibility gate 8,497,015 pairs; cd_host_ref; cd_host_wgs; cd_host_rna; cd_k2_wgs; cd_k2_rna on `large` queue 32 GB).
- 04:19 login node: WGS raw download+verify and Kraken2 DB download started. Submitted `105474.asax-pbs1` cd_host_ref; `cd_host_rna` chained afterok:105474.
- A3/A4 jobs completed 04:34 (both exit 0; the background task reported failure only because of an invalid `tail -4` on multiple files in my wrapper command).
- *Bradyrhizobium* low stratum (identity <0.98 or <80% aligned): 26,757 fragments realigned to *B. guangxiense*, 337 genes hit (58 ≥5), **96.20% rRNA** — consistent with conserved-rRNA cross-mapping from other bacteria and/or the same bradyrhizobia at lower alignment quality.

### 21. A4 — *Fusarium* gene-level support (`scripts/09_gene_level_support.sh SRR29854842 fusarium Fol_4287 GCF_000149955.1 0.98`)
- High stratum (identity ≥0.98, ≥80% aligned): 414,234 fragments realigned to *F. oxysporum* f. sp. *lycopersici* 4287; **8,391 of 21,353 annotated genes hit (5,833 with ≥5 fragments)**; 7.28% rRNA, 6.07% intergenic.
- Low stratum: 56,300 fragments; 3,501 genes (1,310 ≥5); 5.42% rRNA.
- Evidence: transcripts from ~39% of annotated genes of a *F. oxysporum* species-complex genome — broad transcriptional activity, not a conserved-locus artefact.
- 04:37 ASC: SRR39022911 verified (MD5 both mates, 9,726,260 pairs = SRA, 0 ID mismatches). Kraken2 DB `k2_pluspf_16_GB_20260626` downloaded/extracted (hash.k2d 16,000,000,032 B; Bracken kmer_distrib 50–300 bp).
- 04:39 watcher submitted: `105476` cd_qc_wgs; `105477` cd_host_wgs (afterok 105476 + 105474); `105478` cd_k2_rna (afterok 105475); `105479` cd_k2_wgs (afterok 105477). Record: `logs/asc_jobs.txt`.

### 22. Repository (part C)
- `git init` (branch main) in `~/contamination_detection`; name = directory name (user did not specify; noted as changeable). No commits made — awaiting user instruction.
- `.gitignore` excludes reads, references/indexes/databases, BAM/SAM, conda env, restart markers, MEGAHIT intermediates, per-fragment tables and fragment name lists, credentials. Trackable content: 257 files, 15 MB.
- Phase B jobs (all exit 0; finished 05:57): 105474 host indexes 40 min / 5.6 GB; 105476 WGS QC — **reproducibility gate passed (8,497,015 pairs = local)**; 105475 RNA host map 15 min / 4.7 GB; 105477 WGS host map 16 min / 4.8 GB; 105478/105479 Kraken2 39 s / 11 s (16.3 / 15.8 GB). Host reference: 444 sequences, 2,558,162,147 bp.

### 23. Host partition (denominator = trimmed pairs; `results/02_host/genome/<run>/<run>.host_partition.tsv`)
| class | SRR39022911 (WGS, Bowtie2; 97.81% aln) | SRR29854842 (RNA, HISAT2; 94.49% aln) |
|---|---|---|
| nuclear_confident (≥1 mate MAPQ≥20 nuclear) | 5,039,673 (59.31%) | 16,574,742 (77.29%) |
| organellar_confident | 1,922 (0.023%) | 932 (0.004%) |
| ambiguous (mapped, no mate MAPQ≥20) | 3,400,622 (40.02%) | 3,859,999 (18.00%) |
| unmapped = **non-host pool** | **54,798 (0.645%)** | **1,008,951 (4.705%)** |
- Organellar reads are almost all "ambiguous", not lost: WGS chloroplast primary records 440,410, of which 437,318 MAPQ 1–19 and 427,354 carry an `XS` secondary score → near-identical plastid-like sequence elsewhere in the assembly (NUPTs or plastid-derived scaffolds). Host-derived but compartment unresolved; consistent with the 10.4% organelle-like fraction from the organelle-only mapping. Ambiguous ≠ contamination; such reads are excluded from the non-host pool.

### 24. Kraken2 PlusPF-16 (20260626) + Bracken on non-host pools (`results/03_screen/kraken2/`)
- WGS pool 54,798 pairs: 6.39% classified (Eukaryota 2,196 incl. Metazoa 1,529; Bacteria 960). Bracken species: *Homo sapiens* 1,712; *Plasmodium coatneyi* 591; *Larkinella roseola* 286; *Pseudoalteromonas undina* 97; *Cutibacterium acnes* 37; *Sphingomonas melonis* 33; *Xanthomonas albilineans* 23. STAT's *Klebsiella*/*Stenotrophomonas*/*Aeromonas* absent from the pool.
- RNA pool 1,008,951 pairs: 68.50% classified (Fungi 478,269; Bacteria 101,510; Metazoa 15,500). Bracken species: *F. oxysporum* 437,003; *Potyvirus phaseoli* 37,148 / *P. phaseovulgaris* 32,579 / *P. wisteriae* 19,230 (k-mer split among related potyviruses; competitive mapping showed BCMV-specific reads); *Homo sapiens* 16,775; *F. verticillioides* 9,812; *Cutibacterium acnes* 9,633; *Talaromyces marneffei* 8,768; *Salmonella enterica* 3,747; *Bacillus thuringiensis* 3,719; *Streptomyces* spp.; *Bradyrhizobium arachidis* 3,436 / *B. guangxiense* 2,925; Polerovirus CPPV2 2,557.
- All are hypotheses; new candidates (human, *C. acnes*, *Salmonella*, *B. thuringiensis*, *Talaromyces*, *Larkinella*, *Pseudoalteromonas*, *Plasmodium*) require validation.

### 25. Second-round validation setup (non-host candidates)
- Steps 05/06 parameterised: `PANEL=<name>` selects `config/validation_panel_<name>.tsv` / `references/validation_<name>`; step 06 mode `nonhost` maps the step-11 non-host pool (pct_trimmed keeps the all-trimmed-pairs denominator).
- `config/validation_panel_nonhost.tsv` (24 refs): *Cutibacterium* (acnes + granulosum), Enterobacterales (*Salmonella* LT2, *Klebsiella* HS11286, *E. coli* Sakai), *Bacillus* (thuringiensis, cereus, subtilis), *Talaromyces* (marneffei, amestolkiae, pinophilus) with validated *F. oxysporum* as competitor, *Larkinella roseola*, *Pseudoalteromonas undina*, *Sphingomonas melonis*, Xanthomonadales (*X. albilineans*, *S. maltophilia*), *Aeromonas caviae*, *Enterococcus faecalis*, *Plasmodium* (coatneyi + knowlesi), *Streptomyces griseorubiginosus*, *B. guangxiense* competitor, phiX174 control. Accessions resolved with NCBI datasets (reference or complete genomes).
- `scripts/14_human.sh`: non-host pool vs GRCh38_full_as (prebuilt Bowtie2 index); "human-confident" = MAPQ≥20 and identity ≥0.98; chrM share.
- `scripts/15_kmer_bacteria_vs_host.sh`: Kraken2 on all WGS trimmed pairs; Bacteria-assigned fragments (domain-only and whole clade) cross-tabulated with step-11 host classes — read-level test of the STAT domain-level "Bacteria" hypothesis. Report parser unit-tested (641 taxa under Bacteria in the WGS non-host report).
- `pbs/cd_val2.pbs` (large queue, 16 cpu, 32 GB, 8 h). Login node: non-host panel fetch + GRCh38 index download started; job auto-submitted only if both downloads exit 0.
- 06:03 login-node downloads OK: non-host panel 532 sequences / 295,994,041 bp; GRCh38_full_as Bowtie2 index (6 files). 06:05 `105495` cd_val2 submitted (large queue) but stayed queued; at user's progress check (06:10) it was deleted before starting (`qdel`) and split so only the Kraken2 part needs the large queue: `105496` cd_val2a (medium: non-host panel + human, both runs), `105497` cd_val2b (large: WGS k-mer test).

### 26. RNA candidates within the non-host pool (`results/04_validation/SRR29854842/SRR29854842.groups_in_nonhost_pool.tsv`)
Stage A fragments whose read name is in the step-11 non-host pool (1,008,951 pairs): *Fusarium* 487,257 / 491,970 (99.04%; = 48.29% of pool), potyvirus 147,638 / 148,658 (99.31%; 14.63% of pool), *Bradyrhizobium* 37,854 / 37,909 (99.85%; 3.75%; high-identity subset 8,192), polerovirus 3,866 / 3,869 (99.92%; 0.38%).
- **Rule deviation (self-reported):** this computation wrote a temporary name list to `/tmp` on the ASC login node instead of the user's scratch directory (user instruction: scratch only). The file was deleted at the end of the same command. All later temporary files on ASC go under `/scratch/aubfxp001/contamination_detection/tmp/`.

### 27. Deliverable drafting while cd_val2a/b run
- `config/detection_candidates.tsv` + `scripts/16_detection_table.py`: detection table generated from result files only (STAT JSON, SendSketch TSV, Bracken TSV, Stage A/B tables, gene summaries, virus contig tables, chimera log). Explicit denominators; transparent detection-confidence rule; significance bin / likely source left as "(student decision)". Two generator fixes after first run: (i) STAT/Kraken lookups switched to genus-level names for genus-level groups (*Fusarium* STAT 129,900 species-sum → 435,254 genus clade); (ii) `reference` now always names the Stage-B genome the coverage was measured on (*Bradyrhizobium* coverage is vs *B. guangzhouense*; gene support vs *B. guangxiense* is labelled as such).
- `README.md`, `docs/INSTALL.md`, `docs/METHODS.md` drafted.
- Figures (`scripts/17_figures.py`, dataviz method; categorical slots 1–4 validated with `validate_palette.js --mode light`: all hard checks pass, aqua/yellow contrast WARN → direct labels + tables): `results/figures/fig1_host_partition.png`, `fig2_virus_coverage.png` (per-base depth from `samtools depth -a` on the all-read remap BAM). Rendered and inspected; one overflowing in-bar label removed (threshold 6%).
- **cd_val2a (105496) exit 1 / cd_val2b (105497) exit 141.** Non-host panel finished for both runs. Human summaries and the k-mer cross-tab failed: a `samtools view | python3 - args <<'EOF'` construct gives python the heredoc (script text) as stdin, so the piped alignments were never read and samtools received SIGPIPE (141) under `pipefail`. Alignments/Kraken2 outputs were complete (markers set). **Fix:** inline code moved to `scripts/lib/human_summary.py` and `scripts/lib/host_class_of_ids.py`; checked that no other script pipes into a heredoc python. Summary-only re-run submitted: 105500.asax-pbs1 (cd_val2c, medium).

### 28. Non-host panel results (PANEL=nonhost; `results/04_validation/<run>.nonhost_nonhost/`; strata in `results/04_validation/nonhost_identity_strata.txt`)
Denominators: pct_trimmed = fragments / trimmed pairs; non-host pool = 54,798 (WGS) / 1,008,951 (RNA) pairs. "Near-identical" = identity ≥0.99 and ≥80% of read aligned.
- **SRR39022911 (WGS)**: *Plasmodium* 14,728 fragments (0.173% of trimmed; 26.9% of pool) but mean identity 0.868, near-identical **9** (P. knowlesi) / 0 (P. coatneyi) → unsupported; low-identity local alignments (AT-rich/low-complexity candidates). Enterobacterales 57 (best *E. coli* Sakai 48; near-identical 18). *Sphingomonas melonis* 22 (near-identical 14). *Cutibacterium* 17; *Larkinella* 55 (0% aligned ≥80%; near-identical 0); *Talaromyces* 280 (near-identical 2); *Pseudoalteromonas* 5; *Enterococcus* 5; *Aeromonas* 1; *Xanthomonadales* 7. STAT's *Klebsiella* (1,051), *Stenotrophomonas* (619), *Aeromonas* (392) are not supported in the non-host pool.
- **SRR29854842 (RNA)**: *F. oxysporum* competitor 460,927 (near-identical 318,531); *Talaromyces* 38,205 (best *T. pinophilus* 31,919; near-identical 6,143; mean id 0.961 → species unresolved); *Streptomyces* 29,994 (near-identical 9,804; mean 0.957); *Cutibacterium* 17,014 (*C. acnes* 10,390 with **7,598 near-identical**; *C. granulosum* 6,624 with 252); *Bradyrhizobium* competitor 13,768 (near-identical 7,247); *Sphingomonas* 6,555 (near-identical 567); Enterobacterales 3,349 (*E. coli* 1,579 / 805 near-identical; *K. pneumoniae* 1,004 / 155; *S. enterica* 766 / 115 → Kraken2 "Salmonella" better explained by *E. coli*-like reads); *Bacillus* 3,159 (near-identical ≤121 per species; *B. thuringiensis* 5); *Plasmodium* 6,477 (near-identical 0); *Enterococcus*, *Aeromonas*, *Xanthomonadales*, *Pseudoalteromonas*, *Larkinella* mostly <0.93 identity (generic conserved-gene hits).
- **cd_val2c (105500) exit 0** (summary re-run after the stdin fix).

### 29. Human validation (step 14; non-host pool vs GRCh38_full_as)
| run | aligned pairs | MAPQ≥20 | human-confident (MAPQ≥20, id≥0.98) | % trimmed | % non-host pool | on chrM | distinct nuclear seqs |
|---|---|---|---|---|---|---|---|
| SRR39022911 | 65 | 8 | **6** | 0.00007 | 0.011 | 0 | 4 |
| SRR29854842 | 19,183 | 10,821 | **10,410** | 0.0485 | 1.032 | 317 | 30 |
Kraken2/Bracken "Homo sapiens": 1,712 (WGS) and 16,775 (RNA) pairs → largely unsupported in WGS; supported in RNA.

### 30. k-mer "Bacteria" vs host class (step 15; Kraken2 PlusPF-16 on all 8,497,015 WGS trimmed pairs)
- Bacteria clade: 198,207 pairs → ambiguous-nuclear 164,315 (82.90%), ambiguous with organelle primary 24,405 (12.31%), nuclear-confident 8,514 (4.30%), organellar-confident 13, **unmapped 960 (0.48%)**.
- Domain-only (taxid 2; STAT-like case): 61,820 pairs → 99.88% host-mapped (ambiguous-nuclear 94.99%, organelle-primary 3.74%, nuclear-confident 1.12%), unmapped 76.
- Evidence: domain-level bacterial k-mer assignments in this WGS run overwhelmingly come from reads that align to the peanut assembly, mostly to multi-copy nuclear regions (not only organelles). Caveat: Kraken2 (no plant genomes) is used as a per-read stand-in for STAT, which provides no per-read output.

### 31. Detection table, write-up, manifests
- `scripts/16_detection_table.py` rewritten to cover all sources (main, nonhost, human, kmer, chimera). Added `near_identical_fragments` (cellular: identity ≥0.98 & ≥80% aligned from Stage-A fragment tables; viruses: MAPQ≥20 remap fragments on the assembled contig; human: MAPQ≥20 & id≥0.98) and `independent_screens_agreeing`; confidence rule now keyed to near-identical support (adds "not supported" for <10). 18 candidates (11 RNA-seq, 7 WGS). Config label corrected for the k-mer row (STAT 267,551 Bacteria clade / 255,756 domain-only).
- Rule-based confidence (not significance): high — BCMV, polerovirus, *F. oxysporum* SC, human (RNA); moderate — *Bradyrhizobium*, *C. acnes*, *Streptomyces* sp., *Talaromyces* sp., *E. coli*-like (RNA); low — *Plasmodium*, *E. coli*-like, *Sphingomonas* (WGS); not supported — *Plasmodium* (RNA), human, *Klebsiella*, *Enterococcus* (WGS); artifact — BCMV–host chimeric contigs; host-derived — WGS Bacteria k-mer reads.
- Reference/database manifests copied to `docs/reference_manifests/` (references/ and databases/ are git-ignored).
