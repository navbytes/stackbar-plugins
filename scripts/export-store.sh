#!/bin/sh
# Puts the published store in one folder, ready to upload to a host of your
# own: the gh-pages branch (signed index, bundles, renders, helpers.json) and,
# when store.json's helpersURL is a relative path such as helpers-bin, the
# prebuilt helper binaries from this repository's helpers-* releases at
# <helpersURL>/<release>/<asset>, where helpers.json points.
#
# For an organization's private copy, whose GitHub Pages and release assets
# the app can't download (stackbar's docs/self-hosting.md). Needs git, gh
# and GH_TOKEN with contents read on this repository.
#
#   scripts/export-store.sh <out dir>
set -eu
OUT=$1
cd "$(dirname "$0")/.."
REPO=${GITHUB_REPOSITORY:-navbytes/stackbar-plugins}
HELPERS_URL=$(python3 scripts/store_config.py get helpersURL)
HELPERS_URL=${HELPERS_URL%/}

rm -rf "$OUT"
mkdir -p "$OUT"
git fetch -q --depth 1 origin gh-pages
git archive FETCH_HEAD | tar -x -C "$OUT"
echo "store: $(find "$OUT" -type f | wc -l | tr -d ' ') files from gh-pages"

case "$HELPERS_URL" in
    "") echo "helpers: served from this repository's releases (helpersURL is null)"; exit 0 ;;
    *://*) echo "helpers: served from $HELPERS_URL; not exported"; exit 0 ;;
esac
[ -f "$OUT/helpers.json" ] || { echo "helpers: no helpers.json yet"; exit 0; }

python3 - "$OUT/helpers.json" "$HELPERS_URL" <<'PY' > "$OUT/.helpers-wanted"
import json, sys
helpers, base = json.load(open(sys.argv[1]))["helpers"], sys.argv[2] + "/"
for record in helpers:
    url = record.get("url", "")
    if url.startswith(base) and url.count("/") == base.count("/") + 1:
        print(url[len(base):])
PY
count=0
while IFS=/ read -r release asset; do
    [ -n "$release" ] && [ -n "$asset" ] || continue
    mkdir -p "$OUT/$HELPERS_URL/$release"
    gh release download "$release" -R "$REPO" -p "$asset" -D "$OUT/$HELPERS_URL/$release" --clobber
    count=$((count + 1))
done < "$OUT/.helpers-wanted"
rm -f "$OUT/.helpers-wanted"
echo "helpers: $count binaries under $HELPERS_URL/"
