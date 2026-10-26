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
# Settings are environment variables (CTS job "params.environment"), all optional.
#
# Any QIIME parameter of the three steps can be set as <STEP>_<PARAM>, where STEP is
#   CUTADAPT  (qiime cutadapt trim-single)
#   DADA2     (qiime dada2 denoise-pyro)
#   CLASSIFY  (qiime feature-classifier classify-sklearn)
# and PARAM is the --p-<param> name in upper case with "-" → "_". For example
#   DADA2_POOLING_METHOD=pseudo      → --p-pooling-method pseudo
#   CLASSIFY_CONFIDENCE=0.8          → --p-confidence 0.8
#   DADA2_ALLOW_ONE_OFF=true         → --p-allow-one-off      (false → --p-no-allow-one-off)
#   CUTADAPT_FRONT=SEQ1,SEQ2         → --p-front SEQ1 SEQ2    (commas separate values)
# Parameters you don't set aren't passed, so QIIME's own defaults apply (see
# `qiime <step> --help`). QIIME rejects misspelled names.
#
# Values the pipeline sets because QIIME has no default for them:
#   CUTADAPT_FRONT     5' primer                  (default 926F AAACTYAAAKGAATTGRCGG)
#   CUTADAPT_ADAPTER   3' primer, reverse compl.  (default 1392R → GYACACACCGCCCGT)
#   DADA2_TRUNC_LEN    truncation length; shorter reads are dropped; 0 = none (default 400)
# Shorthands kept from earlier versions: FWD_PRIMER, REV_PRIMER_RC, TRUNC_LEN, TRIM_LEFT,
# MAX_EE, DISCARD_UNTRIMMED (= CUTADAPT_FRONT, CUTADAPT_ADAPTER, DADA2_TRUNC_LEN,
# DADA2_TRIM_LEFT, DADA2_MAX_EE, CUTADAPT_DISCARD_UNTRIMMED).
#
# Pipeline settings:
#   THREADS            cutadapt cores, DADA2 threads, classifier jobs (default: all CPUs;
#                      a <STEP>_CORES/_N_THREADS/_N_JOBS setting overrides it per step)
#   SKIP_TAXONOMY      "true" to stop after denoising      (default false)
#   CLASSIFIER         classifier .qza                     (default $REFDATA_DIR/silva-138-99-nb-classifier.qza)
#   OUT_DIR            output directory                    (default /out)
#   REFDATA_DIR        CTS refdata mount point             (default /reference_data)
set -euo pipefail

OUT_DIR="${OUT_DIR:-/out}"
REFDATA_DIR="${REFDATA_DIR:-/reference_data}"
CLASSIFIER="${CLASSIFIER:-$REFDATA_DIR/silva-138-99-nb-classifier.qza}"
SKIP_TAXONOMY="${SKIP_TAXONOMY:-false}"
THREADS="${THREADS:-$(nproc)}"

# Shorthands and the defaults QIIME doesn't provide. Exported so qiime_opts sees them.
export CUTADAPT_FRONT="${CUTADAPT_FRONT:-${FWD_PRIMER:-AAACTYAAAKGAATTGRCGG}}"
export CUTADAPT_ADAPTER="${CUTADAPT_ADAPTER:-${REV_PRIMER_RC:-GYACACACCGCCCGT}}"
export DADA2_TRUNC_LEN="${DADA2_TRUNC_LEN:-${TRUNC_LEN:-400}}"
[[ -n "${TRIM_LEFT:-}" ]] && export DADA2_TRIM_LEFT="${DADA2_TRIM_LEFT:-$TRIM_LEFT}"
[[ -n "${MAX_EE:-}" ]] && export DADA2_MAX_EE="${DADA2_MAX_EE:-$MAX_EE}"
[[ -n "${DISCARD_UNTRIMMED:-}" ]] &&
    export CUTADAPT_DISCARD_UNTRIMMED="${CUTADAPT_DISCARD_UNTRIMMED:-$DISCARD_UNTRIMMED}"

log() { echo "[pipeline $(date -u +%H:%M:%S)] $*" >&2; }

# Build the QIIME options for one step from the <PREFIX>_* environment variables into the
# array `opts`. The step's thread parameter gets $THREADS unless the step sets its own
# (QIIME rejects an option given twice).
qiime_opts() {
    local prefix=$1 thread_param=$2 var name val
    local -a vals
    opts=()
    local thread_var="${prefix}_${thread_param^^}"
    thread_var="${thread_var//-/_}"
    [[ -z "${!thread_var:-}" ]] && opts+=("--p-$thread_param" "$THREADS")
    for var in $(compgen -e | grep "^${prefix}_" | sort); do
        name="${var#"${prefix}_"}"
        name="${name,,}"
        name="${name//_/-}"
        val="${!var}"
        case "$val" in
            true) opts+=("--p-$name") ;;
            false) opts+=("--p-no-$name") ;;
            *) IFS=, read -ra vals <<< "$val"; opts+=("--p-$name" "${vals[@]}") ;;
        esac
    done
    log "$prefix options: ${opts[*]:-(QIIME defaults)}"
}

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
qiime_opts CUTADAPT cores
qiime cutadapt trim-single \
    --i-demultiplexed-sequences "$QZA/demux.qza" \
    "${opts[@]}" \
    --o-trimmed-sequences "$QZA/trimmed.qza"

# --- Denoise -------------------------------------------------------------------------
log "denoising (dada2 denoise-pyro)"
qiime_opts DADA2 n-threads
qiime dada2 denoise-pyro \
    --i-demultiplexed-seqs "$QZA/trimmed.qza" \
    "${opts[@]}" \
    --o-table "$QZA/table.qza" \
    --o-representative-sequences "$QZA/rep-seqs.qza" \
    --o-denoising-stats "$QZA/denoising-stats.qza" \
    --o-base-transition-stats "$QZA/base-transition-stats.qza"

# --- Taxonomy ------------------------------------------------------------------------
if [[ "$SKIP_TAXONOMY" != "true" ]]; then
    log "classifying with $(basename "$CLASSIFIER")"
    qiime_opts CLASSIFY n-jobs
    qiime feature-classifier classify-sklearn \
        --i-classifier "$CLASSIFIER" \
        --i-reads "$QZA/rep-seqs.qza" \
        "${opts[@]}" \
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
