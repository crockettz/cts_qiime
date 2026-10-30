#!/bin/bash
# Build the CTS refdata archive: QIIME's pre-trained classifiers for scikit-learn 1.4.2
# (QIIME 2026.1) at the archive's top level, plus CLASSIFIERS.tsv with sources and checksums.
# Register the result with the CTS with unpack enabled.
#
# Usage: build_classifier_bundle.sh [<work dir>]   (default: current directory)
set -euo pipefail

BASE=https://data.qiime2.org/classifiers/sklearn-1.4.2
OUT=cts_qiime_classifiers_sklearn-1.4.2.tar.gz
# path under $BASE | database | weighting
CLASSIFIERS=(
    "silva/silva-138-99-nb-classifier.qza|SILVA 138 99% full-length (default)|uniform"
    "silva/silva-138-99-nb-diverse-weighted-classifier.qza|SILVA 138 99% full-length|diverse"
    "greengenes2/2024.09.backbone.full-length.nb.sklearn-1.4.2.qza|Greengenes2 2024.09 backbone full-length|uniform"
    "gtdb/gtdb_classifier_r220.qza|GTDB r220|uniform"
    "gtdb/gtdb_diverse_weighted_classifier_r220.qza|GTDB r220|diverse"
)

cd "${1:-.}"
printf 'file\tdatabase\tweighting\tsource_url\tsha256\n' > CLASSIFIERS.tsv
files=()
for entry in "${CLASSIFIERS[@]}"; do
    IFS='|' read -r path db weight <<< "$entry"
    f="$(basename "$path")"
    [[ -s "$f" ]] || curl -sSfL -o "$f" "$BASE/$path"
    sha="$(shasum -a 256 "$f" | cut -d' ' -f1)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$db" "$weight" "$BASE/$path" "$sha" >> CLASSIFIERS.tsv
    files+=("$f")
done

# Keep macOS metadata (._ files, xattrs) out of the archive. No links, all top level.
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -czf "$OUT" CLASSIFIERS.tsv "${files[@]}" \
    2>/dev/null || tar -czf "$OUT" CLASSIFIERS.tsv "${files[@]}"
tar -tzf "$OUT"
echo "wrote $OUT"
