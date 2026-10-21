# Installation and reproduction

## Environment

All tools come from conda-forge and bioconda, in one environment. Exact resolved versions are in `docs/software_versions.tsv`, and the full pinned list is in `environment.yml`.

```bash
# local (WSL/Ubuntu)
mamba env create -f environment.yml          # creates env "contam"
conda activate contam

# ASC (scratch-only prefix env; the shared anaconda module is NOT loaded, because it adds MPI/CUDA libs)
P=/scratch/$USER/contamination_detection
cat > $P/conda/condarc <<EOF
channels: [conda-forge, bioconda]
channel_priority: strict
pkgs_dirs: [$P/conda/pkgs]
envs_dirs: [$P/conda/envs]
EOF
CONDARC=$P/conda/condarc CONDA_PKGS_DIRS=$P/conda/pkgs \
  /apps/x86-64/apps/anaconda_3-2025.06/bin/conda env create -y -p $P/conda/envs/contam -f environment.yml
```

Mamba 2.0.3 on ASC needs `MAMBA_ROOT_PREFIX`, so `conda` (libmamba solver) was used there instead. To check the installation, print each tool's version with the commands in `logs/env/contam_versions.txt`; the ASC versions were identical to the local ones.

## Running

Run from the repository root. Thread count, seed and paths are set in `config/config.sh`, and any of them can be overridden with an environment variable (for example `THREADS=16`).

```bash
bash scripts/01_download_verify.sh                 # both runs
bash scripts/02_qc_trim_subsample.sh
bash scripts/03_sendsketch.sh
bash scripts/04_organelle_map.sh
bash scripts/05_fetch_validation_refs.sh
bash scripts/06_validate_candidates.sh SRR29854842 sub     # 500k-pair test
bash scripts/07a_virus_dbs.sh
# memory/CPU-heavy steps: qsub the scripts in pbs/ (ASC), or run the scripts directly on a large machine
qsub pbs/06_validate_rna.pbs; qsub pbs/07_virus_rna.pbs
qsub pbs/cd_host_ref.pbs; qsub pbs/cd_host_wgs.pbs; qsub pbs/cd_host_rna.pbs
bash scripts/12_kraken2.sh download; qsub pbs/cd_k2_wgs.pbs; qsub pbs/cd_k2_rna.pbs
PANEL=nonhost bash scripts/05_fetch_validation_refs.sh; bash scripts/14_human.sh download
qsub pbs/cd_val2a.pbs; qsub pbs/cd_val2b.pbs
bash scripts/08_polerovirus_orfs.sh SRR29854842 SRR29854842_k141_5
bash scripts/09_gene_level_support.sh SRR29854842 fusarium Fol_4287 GCF_000149955.1 0.98
bash scripts/09_gene_level_support.sh SRR29854842 bradyrhizobium Bgx_CCBAU53363 GCF_004114915.1 0.98
python3 scripts/16_detection_table.py
```

## Resources observed

| Job | Wall time | Peak memory |
|---|---|---|
| Local, 6 threads, 4.8 GB RAM: 500k-pair panel test | 9.3 min (Stage A) | < 4 GB |
| ASC `06_validate_rna`, 16 cpu: 21.4M pairs vs 645 Mb panel | 68 min | 6.4 GB |
| ASC `cd_host_ref`: Bowtie2 + HISAT2 indexes, 2.56 Gb | 40 min | 5.6 GB |
| ASC `cd_host_rna` / `cd_host_wgs` | 15 / 16 min | 4.7 / 4.8 GB |
| ASC Kraken2 PlusPF-16 on the non-host pools | < 1 min | 16 GB |

## Databases (version-pinned)

- Kraken2 PlusPF-16: `k2_pluspf_16_GB_20260626` (Langmead lab index collection)
- NCBI RefSeq viral proteins, release 237 (DIAMOND 2.2.8); Pfam RdRp HMMs PF00680, PF02123, PF00978, PF00998, PF05919, PF00946 (InterPro API, 2026-10-20)
- GRCh38_full_as Bowtie2 index (Langmead lab)
- The reference panels and their MD5s are listed in `references/*/manifest.tsv` (generated) and `config/validation_panel*.tsv`.
