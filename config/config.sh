# Project configuration — sourced by every script in scripts/.
# Paths are relative to the repository root; override any value via environment variables.

# Datasets (do not substitute without approval)
WGS_RUN="${WGS_RUN:-SRR39022911}"
RNA_RUN="${RNA_RUN:-SRR29854842}"
RUNS="${RUNS:-$WGS_RUN $RNA_RUN}"

# Resources (local WSL defaults: 8 threads, ~5 GB RAM)
THREADS="${THREADS:-6}"
MEM_GB="${MEM_GB:-4}"

# Directories
DATA_DIR="${DATA_DIR:-data}"
RAW_DIR="${RAW_DIR:-$DATA_DIR/raw}"
TRIM_DIR="${TRIM_DIR:-$DATA_DIR/trimmed}"
SUB_DIR="${SUB_DIR:-$DATA_DIR/subsample}"
REF_DIR="${REF_DIR:-references}"
DB_DIR="${DB_DIR:-databases}"
RES_DIR="${RES_DIR:-results}"
LOG_DIR="${LOG_DIR:-logs}"
META_DIR="${META_DIR:-metadata}"

# Subsampling for local tests
SUB_PAIRS="${SUB_PAIRS:-500000}"
SEED="${SEED:-11}"

# fastp (conservative)
FASTP_QUAL="${FASTP_QUAL:-15}"       # sliding-window mean quality (cut_right)
FASTP_MINLEN="${FASTP_MINLEN:-50}"   # discard reads shorter than this after trimming
