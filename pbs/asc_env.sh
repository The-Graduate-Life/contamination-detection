# Sourced by every PBS job on ASC. Puts the project's prefix environment first on PATH without
# loading the shared anaconda module (which adds MPI/CUDA libraries to LD_LIBRARY_PATH).
# Project root on ASC (scratch only, per user instruction):
export PROJ="${PROJ:-/scratch/aubfxp001/contamination_detection}"
export CONDA_PREFIX="$PROJ/conda/envs/contam"
export PATH="$CONDA_PREFIX/bin:$PATH"
export JAVA_HOME="$CONDA_PREFIX/lib/jvm"
# Match tool threads to the PBS allocation
export THREADS="${NCPUS:-${THREADS:-8}}"
cd "$PROJ"
echo "[$(date '+%F %T')] host=$(hostname) job=${PBS_JOBID:-none} threads=$THREADS prefix=$CONDA_PREFIX"
