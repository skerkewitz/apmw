#!/bin/sh
# Writes the release tag into apmw and apmw.cmd (replacing the "dev" placeholder),
# so a released script knows which apmw release it belongs to.
# Usage: scripts/stamp-version.sh v1.2.3 [DIR]
set -eu
tag=$1
dir=${2:-.}
case $tag in
    v[0-9]*) ;;
    *) echo "invalid tag: $tag" >&2; exit 1 ;;
esac
sed -i "s/^APMW_VERSION=dev\$/APMW_VERSION=$tag/" "$dir/apmw"
# apmw.cmd has CRLF line endings, so no end-of-line anchor here.
sed -i "s/^\\\$ApmwVersion = 'dev'/\\\$ApmwVersion = '$tag'/" "$dir/apmw.cmd"
grep -q "^APMW_VERSION=$tag\$" "$dir/apmw" || { echo "stamping apmw failed" >&2; exit 1; }
grep -q "^\\\$ApmwVersion = '$tag'" "$dir/apmw.cmd" || { echo "stamping apmw.cmd failed" >&2; exit 1; }
