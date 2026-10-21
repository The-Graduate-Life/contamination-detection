#!/usr/bin/env bash
# Step 5 — Fetch the competitive validation panel listed in config/validation_panel.tsv.
#   nuccore      -> efetch FASTA
#   assembly     -> NCBI datasets genomic FASTA
#   assembly_rna -> NCBI datasets RefSeq transcript FASTA (host decoy)
#   local        -> organelle FASTA already in references/organelles
# Output: references/validation/panel.fasta and contig_map.tsv (contig -> group/label/role),
#         plus references/validation/manifest.tsv (accession, file, sequences, bp, md5, date).
# Usage: bash scripts/05_fetch_validation_refs.sh
source "$(dirname "$0")/common.sh"
require_tools efetch datasets unzip seqkit md5sum

sfx="${PANEL:+_$PANEL}"          # optional second panel: PANEL=name -> config/validation_panel_<name>.tsv
PANEL_TSV="config/validation_panel$sfx.tsv"
VDIR="$REF_DIR/validation$sfx"
[[ -s $PANEL_TSV ]] || die "missing $PANEL_TSV"
mkdir -p "$VDIR/src" "$LOG_DIR/05_refs"
is_done "validation_refs$sfx" && { log "validation panel already fetched"; exit 0; }

: > "$VDIR/contig_map.tsv.tmp"
printf 'group\taccession\tlabel\tfile\tn_seqs\tbp\tmd5\tretrieved\n' > "$VDIR/manifest.tsv.tmp"

grep -v '^#' "$PANEL_TSV" | while IFS=$'\t' read -r group acc type label role; do
    f="$VDIR/src/$label.fasta"
    if [[ ! -s $f ]]; then
        log "fetch $acc ($type) -> $label"
        case $type in
            nuccore)
                efetch -db nuccore -id "$acc" -format fasta > "$f.tmp" 2>>"$LOG_DIR/05_refs/efetch.log" ;;
            assembly|assembly_rna)
                inc=genome; [[ $type == assembly_rna ]] && inc=rna
                tmpd=$(mktemp -d "$VDIR/src/dl.XXXX")
                datasets download genome accession "$acc" --include "$inc" --filename "$tmpd/pkg.zip" \
                    >>"$LOG_DIR/05_refs/datasets.log" 2>&1
                unzip -q -o "$tmpd/pkg.zip" -d "$tmpd"
                find "$tmpd/ncbi_dataset/data" -name '*.fna' -exec cat {} + > "$f.tmp"
                rm -rf "$tmpd" ;;
            local)
                fetch_organelles
                cat "$REF_DIR/organelles/NC_037358.1.fasta" "$REF_DIR/organelles/MW448460.1.fasta" > "$f.tmp" ;;
            *) die "unknown type '$type' for $acc" ;;
        esac
        grep -q '^>' "$f.tmp" || die "$acc: download produced no FASTA (see logs/05_refs)"
        mv "$f.tmp" "$f"
    fi
    # contig -> panel metadata (first header token = contig name used by aligners)
    grep '^>' "$f" | sed 's/^>//; s/ .*//' | awk -v g="$group" -v a="$acc" -v l="$label" -v r="$role" \
        'BEGIN{OFS="\t"} {print $1, g, a, l, r}' >> "$VDIR/contig_map.tsv.tmp"
    read -r n bp < <(seqkit stats -T "$f" | awk 'NR==2{print $4, $5}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$group" "$acc" "$label" "$f" "$n" "$bp" \
        "$(md5sum "$f" | cut -d' ' -f1)" "$(date +%F)" >> "$VDIR/manifest.tsv.tmp"
done

# Contig names must be unique across the panel
dups=$(cut -f1 "$VDIR/contig_map.tsv.tmp" | sort | uniq -d | head)
[[ -z $dups ]] || die "duplicate contig names across panel: $dups"

{ printf 'contig\tgroup\taccession\tlabel\trole\n'; cat "$VDIR/contig_map.tsv.tmp"; } > "$VDIR/contig_map.tsv"
mv "$VDIR/manifest.tsv.tmp" "$VDIR/manifest.tsv"; rm -f "$VDIR/contig_map.tsv.tmp"
grep -v '^#' "$PANEL_TSV" | cut -f4 | while read -r l; do cat "$VDIR/src/$l.fasta"; done \
    | seqkit seq -w 0 > "$VDIR/panel.fasta"
seqkit stats -T "$VDIR/panel.fasta" > "$VDIR/panel.stats.tsv"
mark_done "validation_refs$sfx"
log "Step 5 complete: $(awk 'NR==2{print $4" sequences, "$5" bp"}' "$VDIR/panel.stats.tsv")"
