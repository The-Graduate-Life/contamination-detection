#!/usr/bin/env bash
# Step 7a — Small virus databases for contig annotation (minimal virus toolchain).
#   * NCBI RefSeq viral proteins (viral.*.protein.faa.gz, current release) -> DIAMOND database
#   * Pfam RdRp profile HMMs from InterPro -> HMMER database
# Versions (RefSeq release number, download date, MD5) are written to databases/virus/VERSIONS.tsv.
# Usage: bash scripts/07a_virus_dbs.sh
source "$(dirname "$0")/common.sh"
require_tools wget diamond hmmpress md5sum

D="$DB_DIR/virus"; mkdir -p "$D/pfam" "$LOG_DIR/07_virus"
is_done virus_dbs && { log "virus databases present"; exit 0; }

RS=https://ftp.ncbi.nlm.nih.gov/refseq/release
release=$(curl -s "$RS/RELEASE_NUMBER")
files=$(curl -s "$RS/viral/" | grep -oE 'viral\.[0-9]+\.protein\.faa\.gz' | sort -u)
[[ -n $files ]] || die "could not list RefSeq viral protein files"
printf 'database\tsource\tversion\tdate\tmd5\n' > "$D/VERSIONS.tsv"
for f in $files; do
    wget -q -c -O "$D/$f" "$RS/viral/$f" || die "download failed: $f"
    printf 'refseq_viral_protein\t%s\trelease_%s\t%s\t%s\n' "$RS/viral/$f" "$release" "$(date +%F)" \
        "$(md5sum "$D/$f" | cut -d' ' -f1)" >> "$D/VERSIONS.tsv"
done
log "DIAMOND makedb (RefSeq viral release $release)"
cat "$D"/viral.*.protein.faa.gz | diamond makedb --db "$D/refseq_viral" --threads "$THREADS" \
    > "$LOG_DIR/07_virus/diamond_makedb.log" 2>&1

# RNA-dependent RNA polymerase families relevant to plant/fungal RNA viruses
#   PF00680 RdRP_1 (picorna-like; potyvirus NIb)   PF02123 RdRP_4 (luteo/polero/tombus-like)
#   PF00978 RdRP_2 (alpha-like)                    PF00998 RdRP_3 (tombus/flavi-like)
#   PF05919 Mitovir_RNA_pol (mitoviruses)          PF00946 Mononeg_RNA_pol
for pf in PF00680 PF02123 PF00978 PF00998 PF05919 PF00946; do
    curl -s -f "https://www.ebi.ac.uk/interpro/api/entry/pfam/$pf?annotation=hmm" | gunzip -c > "$D/pfam/$pf.hmm" \
        || die "HMM download failed: $pf"
    printf 'pfam_hmm\tInterPro API %s\t%s\t%s\t%s\n' "$pf" "$(grep -m1 '^NAME' "$D/pfam/$pf.hmm" | awk '{print $2}')" \
        "$(date +%F)" "$(md5sum "$D/pfam/$pf.hmm" | cut -d' ' -f1)" >> "$D/VERSIONS.tsv"
done
cat "$D"/pfam/PF*.hmm > "$D/pfam/rdrp.hmm"
hmmpress -f "$D/pfam/rdrp.hmm" > "$LOG_DIR/07_virus/hmmpress.log"
mark_done virus_dbs
log "Step 7a complete: $D/VERSIONS.tsv"
