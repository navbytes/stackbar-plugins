#!/bin/sh
# Checks out the Stackbar the plugins build against (store.json `stackbar` at
# Package.swift's stackbarRevision) into <dir>, using STACKBAR_REPO_TOKEN, and
# prints the STACKBAR_PATH line for $GITHUB_ENV. For an organization's copy
# whose Stackbar repository is private, so SwiftPM can't fetch it itself; the
# workflows run it only when that secret is set.
#
#   scripts/fetch-stackbar.sh <dir> [revision]
set -eu
DIR=$1
cd "$(dirname "$0")/.."
: "${STACKBAR_REPO_TOKEN:?STACKBAR_REPO_TOKEN is required}"
URL=$(python3 scripts/store_config.py get stackbar)
REVISION=${2:-$(sed -n 's/^let stackbarRevision = "\([0-9a-f]*\)".*/\1/p' Package.swift)}
[ -n "$REVISION" ] || { echo "fetch-stackbar: no stackbarRevision in Package.swift" >&2; exit 1; }
case "$URL" in
    https://github.com/*) AUTHED="https://x-access-token:${STACKBAR_REPO_TOKEN}@${URL#https://}" ;;
    *) echo "fetch-stackbar: $URL is not on github.com" >&2; exit 1 ;;
esac
rm -rf "$DIR"
git init -q "$DIR"
git -C "$DIR" fetch -q --depth 1 "$AUTHED" "$REVISION"
git -C "$DIR" checkout -q FETCH_HEAD
echo "STACKBAR_PATH=$(cd "$DIR" && pwd)"
