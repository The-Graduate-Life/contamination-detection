# Shared helpers — sourced by numbered scripts. Run scripts from the repository root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source config/config.sh

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# require_tools tool1 tool2 ... — fail early if a dependency is missing
require_tools() {
    local t
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing tool '$t' (activate the 'contam' env)"; done
}

# Completion markers make steps restartable: skip a step whose marker exists.
done_marker() { echo "$LOG_DIR/.done/$1"; }
is_done()     { [[ -f "$(done_marker "$1")" ]]; }
mark_done()   { mkdir -p "$LOG_DIR/.done"; date -Is > "$(done_marker "$1")"; }

# fetch_organelles — A. hypogaea chloroplast and mitochondrion references (efetch), if absent
ORGANELLE_ACCS="NC_037358.1 MW448460.1"
fetch_organelles() {
    local acc f
    mkdir -p "$REF_DIR/organelles"
    for acc in $ORGANELLE_ACCS; do
        f="$REF_DIR/organelles/$acc.fasta"
        [[ -s $f ]] && continue
        log "fetching organelle reference $acc"
        efetch -db nuccore -id "$acc" -format fasta > "$f.tmp" 2>>"$LOG_DIR/organelle_efetch.log"
        grep -q '^>' "$f.tmp" || die "organelle fetch failed: $acc"
        mv "$f.tmp" "$f"
    done
}
