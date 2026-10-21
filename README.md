# Contamination detection in peanut WGS and RNA-seq reads

A graduate Contamination Detection Practical. The goal is to find the non-target sequences in two *Arachis hypogaea* (peanut) read sets, and to tell genuine biological associates apart from technical contamination and artefacts. Each candidate is then validated and quantified.

| Accession | Library | Tissue / origin | Study |
|---|---|---|---|
| **SRR39022911** | WGS, Illumina NovaSeq 6000, 2×131/143 bp, 9,726,260 pairs (~1× genome) | leaf, Burkina Faso (CCH119) | PRJNA1475457, peanut mini-core GWAS |
| **SRR29854842** | RNA-seq, 2×150 bp, 21,801,972 pairs. The metadata says HiSeq 2500, but the read headers indicate a NovaSeq | root nodule, Fuzhou, China (IPN_3) | PRJNA1136701, intercropping study |

**Deliverables**
- `results/detection_table.tsv` and `.md`: the quantitative detection table. It is generated from the result files by `scripts/16_detection_table.py`, so no number is typed by hand.
- `docs/agent_transcript.md`: a chronological record of decisions, commands, errors and fixes.
- `docs/writeup.md`: a one-page write-up of the most interesting validated detection.
- `docs/METHODS.md` and `docs/INSTALL.md`: methods, parameters, denominators, installation and reproduction.

The significance categories (noise / trace / consequential / biological) and the likely-source decisions are **left to the student**. The table gives the evidence and the competing explanations.

## Results at a glance

Numbers below are copied from `results/detection_table.tsv`, which is generated from the result files. Fragments are read pairs.

| Run | Candidate | Supporting pairs | % of analysed | Rule-based detection confidence |
|---|---|---|---|---|
| SRR29854842 | *Fusarium oxysporum* species complex | 491,970 | 2.294 | high (8,391 genes expressed) |
| SRR29854842 | Bean common mosaic virus, peanut stripe strain | 148,658 | 0.693 | high (99.95% genome breadth; 10.2 kb contig) |
| SRR29854842 | Polerovirus related to CPPV2 (divergent) | 3,869 | 0.018 | high (5.85 kb contig, 92.4% nt id) |
| SRR29854842 | *Homo sapiens* | 10,410 confident | 0.049 | high |
| SRR29854842 | *Bradyrhizobium*, *C. acnes*, *Streptomyces* sp., *Talaromyces* sp., *E. coli*-like | see table | 0.007–0.18 | moderate |
| SRR29854842 | BCMV–host chimeric contigs | 0–4 junction reads | — | artifact |
| SRR39022911 | Bacteria-classified k-mer reads (STAT 2.6%) | 198,207 (Kraken2) | — | host-derived: 99.5% align to peanut |
| SRR39022911 | human, *Plasmodium*, *Klebsiella*, *E. coli*, *Sphingomonas*, *Enterococcus* | ≤ 25 near-identical each | ≤ 0.0003 (near-identical) | low / not supported |

The WGS leaf library is essentially free of credible non-host organisms, apart from trace signals. The RNA-seq nodule library carries two plant viruses, an actively transcribing *F. oxysporum*, symbiotic bradyrhizobia, and lower-level human, *Cutibacterium*, soil-actinobacterial and fungal signals.

Figures: `results/figures/fig1_host_partition.png`, `results/figures/fig2_virus_coverage.png`.

## Workflow

| Step | Script | Where it ran | What it does |
|---|---|---|---|
| 1 | `scripts/01_download_verify.sh` | local + ASC | ENA FASTQ download, MD5 check against ENA, read counts against SRA, R1/R2 ID sync, raw files made read-only |
| 2 | `scripts/02_qc_trim_subsample.sh` | local + ASC | FastQC/MultiQC, fastp (adapters, poly-G, Q15 window, min length 50, no dedup), 500k-pair seeded subsample (seed 11) |
| 3a | `scripts/03_sendsketch.sh` | local | BBTools SendSketch (nt, refseq) on the subsample |
| 4 | `scripts/04_organelle_map.sh` | local | Bowtie2 to the chloroplast (NC_037358.1) and mitochondrion (MW448460.1) |
| 5 | `scripts/05_fetch_validation_refs.sh` | local + ASC | competitive reference panels (`config/validation_panel*.tsv`) |
| 6 | `scripts/06_validate_candidates.sh` | ASC | Stage A: competitive Bowtie2 `--local` assignment with a host decoy. Stage B: coverage on the best reference |
| 7 | `scripts/07a_virus_dbs.sh`, `07_virus_assembly.sh` | ASC | MEGAHIT targeted assembly; BLASTn, DIAMOND (RefSeq viral r237) and Pfam RdRp HMMs; all-read remap |
| 8 | `scripts/08_polerovirus_orfs.sh` | local | per-protein amino-acid identity of the polerovirus contig against CPPV2 and relatives |
| 9 | `scripts/09_gene_level_support.sh` | local | distinct genes with reads (*Fusarium*, *Bradyrhizobium*) |
| 10–11 | `scripts/10_host_reference.sh`, `11_host_map.sh` | ASC | Tifrunner gnm2 (GCF_003086295.3) + mitochondrion; Bowtie2 (WGS) or HISAT2 (RNA); host partition and non-host pool |
| 12 | `scripts/12_kraken2.sh` | ASC | Kraken2 PlusPF-16 (20260626) + Bracken on the non-host pools |
| 13 | `PANEL=nonhost scripts/06_validate_candidates.sh RUN nonhost` | ASC | competitive validation of the non-host-pool candidates |
| 14 | `scripts/14_human.sh` | ASC | non-host pool mapped to GRCh38 |
| 15 | `scripts/15_kmer_bacteria_vs_host.sh` | ASC | read-level test of k-mer "Bacteria" assignments against host classes |
| 16 | `scripts/16_detection_table.py` | local | builds the detection table |

PBS job scripts for the Alabama Supercomputer (ASC) are in `pbs/`. Every script reads `config/config.sh` (threads, paths, seed). Scripts are restartable through completion markers in `logs/.done/`, and they stop on the first error.

## Repository layout

```
config/    run configuration, validation panels, detection-table candidate list
scripts/   numbered pipeline steps (+ lib/ helpers)
pbs/       ASC PBS job scripts (+ asc_env.sh)
metadata/  SRA runinfo, ENA filereport (MD5s), NCBI STAT JSON
results/   QC, screening, validation, virus and host-partition tables (small files only)
logs/      tool logs, environment version checks, ASC job records
docs/      transcript, methods, install, write-up, software versions
```

Large files are not committed: reads, references, indexes, databases, BAMs and the Conda environment are excluded (see `.gitignore`). The scripts re-create them from public accessions and check them by MD5.

## Reproducing

See `docs/INSTALL.md`. In short: `conda env create -f environment.yml`, then run the steps in order, using the PBS scripts for the memory-heavy ones.
