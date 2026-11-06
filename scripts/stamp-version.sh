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

# replace FILE PREFIX OLD NEW - replace the first line starting with PREFIX OLD
# (portable: no "sed -i", which differs between GNU and BSD/macOS)
replace() {
    awk -v p="$2$3" -v r="$2$4" '!done && index($0, p) == 1 { $0 = r substr($0, length(p) + 1); done = 1 } { print }' \
        "$1" > "$1.tmp" && cat "$1.tmp" > "$1" && rm -f "$1.tmp" # cat keeps the file mode
}

replace "$dir/apmw" 'APMW_VERSION=' dev "$tag"
# apmw.cmd keeps its CRLF line endings: only the start of the line is replaced.
replace "$dir/apmw.cmd" "\$ApmwVersion = '" "dev'" "$tag'"

grep -q "^APMW_VERSION=$tag\$" "$dir/apmw" || { echo "stamping apmw failed" >&2; exit 1; }
grep -q "^.ApmwVersion = '$tag'" "$dir/apmw.cmd" || { echo "stamping apmw.cmd failed" >&2; exit 1; }
