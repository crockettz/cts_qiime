#!/bin/bash
# 454 single-end 16S amplicon pipeline for the CTS:
#   import → cutadapt primer trim → DADA2 denoise-pyro → SILVA classify → export
#
# Usage (args come from the CTS job, e.g. {"type": "input_files",
# "input_files_format": "space_separated_list"}):
#   entrypoint.sh pipeline <fastq.gz> [<fastq.gz> ...]
#
# All samples must go through one container (num_containers: 1): DADA2 learns its error
# model from the whole run. The sample ID is the file name minus .fastq.gz / .fq.gz; for
# paired runs (_1/_2) only the _1 read is used.
#
# Settings (environment variables, all optional):
#   OUT_DIR            output directory                    (default /out)
#   REFDATA_DIR        CTS refdata mount point             (default /reference_data)
#   CLASSIFIER         classifier .qza                     (default $REFDATA_DIR/silva-138-99-nb-classifier.qza)
#   SKIP_TAXONOMY      "true" to stop after denoising      (default false)
#   FWD_PRIMER         5' primer                           (default 926F AAACTYAAAKGAATTGRCGG)
#   REV_PRIMER_RC      reverse complement of the 3' primer (default 1392R → GYACACACCGCCCGT)
#   DISCARD_UNTRIMMED  "true" to drop reads with no primer (default false; SRA reads often
#                      already have primers removed)
#   TRIM_LEFT          bases to trim from the 5' end       (default 0)
#   TRUNC_LEN          truncate reads to this length; shorter reads are dropped (default 400)
#   MAX_EE             DADA2 max expected errors           (default 2.0)
#   THREADS            threads for DADA2 and classifier    (default: all CPUs)
set -euo pipefail

OUT_DIR="${OUT_DIR:-/out}"
REFDATA_DIR="${REFDATA_DIR:-/reference_data}"
CLASSIFIER="${CLASSIFIER:-$REFDATA_DIR/silva-138-99-nb-classifier.qza}"
SKIP_TAXONOMY="${SKIP_TAXONOMY:-false}"
FWD_PRIMER="${FWD_PRIMER:-AAACTYAAAKGAATTGRCGG}"
REV_PRIMER_RC="${REV_PRIMER_RC:-GYACACACCGCCCGT}"
DISCARD_UNTRIMMED="${DISCARD_UNTRIMMED:-false}"
TRIM_LEFT="${TRIM_LEFT:-0}"
TRUNC_LEN="${TRUNC_LEN:-400}"
MAX_EE="${MAX_EE:-2.0}"
THREADS="${THREADS:-$(nproc)}"

log() { echo "[pipeline $(date -u +%H:%M:%S)] $*" >&2; }

if [[ $# -eq 0 ]]; then
    echo "usage: pipeline <fastq.gz> [<fastq.gz> ...]" >&2
    exit 2
fi
if [[ "$SKIP_TAXONOMY" != "true" && ! -f "$CLASSIFIER" ]]; then
    echo "classifier not found: $CLASSIFIER (set CLASSIFIER, or SKIP_TAXONOMY=true)" >&2
    exit 2
fi

WORK="$TMPDIR/qiime_work"
QZA="$OUT_DIR/qiime"
EXPORT="$OUT_DIR/export"
mkdir -p "$WORK" "$QZA" "$EXPORT"

# --- Manifest ------------------------------------------------------------------------
MANIFEST="$WORK/manifest.tsv"
printf 'sample-id\tabsolute-filepath\n' > "$MANIFEST"
declare -A seen
for f in "$@"; do
    name="$(basename "$f")"
    name="${name%.gz}"; name="${name%.fastq}"; name="${name%.fq}"
    if [[ "$name" == *_2 ]]; then
        log "skipping reverse read $f (single-end pipeline)"
        continue
    fi
    sample="${name%_1}"
    if [[ -n "${seen[$sample]:-}" ]]; then
        echo "duplicate sample ID '$sample' from $f and ${seen[$sample]}" >&2
        exit 2
    fi
    seen[$sample]="$f"
    printf '%s\t%s\n' "$sample" "$(readlink -f "$f")" >> "$MANIFEST"
done
cp "$MANIFEST" "$OUT_DIR/manifest.tsv"
log "${#seen[@]} samples"

# --- Import + primer trim ------------------------------------------------------------
log "importing"
qiime tools import \
    --type 'SampleData[SequencesWithQuality]' \
    --input-format SingleEndFastqManifestPhred33V2 \
    --input-path "$MANIFEST" \
    --output-path "$QZA/demux.qza"

log "trimming primers"
discard_flag="--p-no-discard-untrimmed"
[[ "$DISCARD_UNTRIMMED" == "true" ]] && discard_flag="--p-discard-untrimmed"
qiime cutadapt trim-single \
    --i-demultiplexed-sequences "$QZA/demux.qza" \
    --p-front "$FWD_PRIMER" \
    --p-adapter "$REV_PRIMER_RC" \
    --p-cores "$THREADS" \
    "$discard_flag" \
    --o-trimmed-sequences "$QZA/trimmed.qza"

# --- Denoise -------------------------------------------------------------------------
log "denoising (dada2 denoise-pyro, trunc_len=$TRUNC_LEN)"
qiime dada2 denoise-pyro \
    --i-demultiplexed-seqs "$QZA/trimmed.qza" \
    --p-trim-left "$TRIM_LEFT" \
    --p-trunc-len "$TRUNC_LEN" \
    --p-max-ee "$MAX_EE" \
    --p-n-threads "$THREADS" \
    --o-table "$QZA/table.qza" \
    --o-representative-sequences "$QZA/rep-seqs.qza" \
    --o-denoising-stats "$QZA/denoising-stats.qza"

# --- Taxonomy ------------------------------------------------------------------------
if [[ "$SKIP_TAXONOMY" != "true" ]]; then
    log "classifying with $(basename "$CLASSIFIER")"
    qiime feature-classifier classify-sklearn \
        --i-classifier "$CLASSIFIER" \
        --i-reads "$QZA/rep-seqs.qza" \
        --p-n-jobs "$THREADS" \
        --o-classification "$QZA/taxonomy.qza"
fi

# --- Export plain files --------------------------------------------------------------
log "exporting"
qiime tools export --input-path "$QZA/table.qza" --output-path "$WORK/table"
biom convert -i "$WORK/table/feature-table.biom" -o "$EXPORT/feature-table.tsv" --to-tsv
cp "$WORK/table/feature-table.biom" "$EXPORT/"
qiime tools export --input-path "$QZA/rep-seqs.qza" --output-path "$WORK/rep-seqs"
cp "$WORK/rep-seqs/dna-sequences.fasta" "$EXPORT/"
qiime tools export --input-path "$QZA/denoising-stats.qza" --output-path "$WORK/stats"
cp "$WORK/stats/stats.tsv" "$EXPORT/denoising-stats.tsv"
if [[ "$SKIP_TAXONOMY" != "true" ]]; then
    qiime tools export --input-path "$QZA/taxonomy.qza" --output-path "$WORK/taxonomy"
    cp "$WORK/taxonomy/taxonomy.tsv" "$EXPORT/"
fi

log "done → $OUT_DIR"
