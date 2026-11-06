#!/usr/bin/env bash
#
# Integration tests for apmw and apmw.cmd.
#
# Runs on Linux, macOS and Windows (Git Bash). On Windows both ./apmw (Git Bash) and
# apmw.cmd (cmd) are tested. The scripts from this checkout are served as fake apmw
# releases by a local web server; apm itself is downloaded from GitHub.
#
# Requirements: bash, curl, python3 (or python), network access to github.com.
# Usage: tests/test.sh

# eval with single quotes is intended: the checks expand when they run.
# shellcheck disable=SC2016
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/apmw-test.XXXXXX")
PASS=0
FAIL=0
SERVER_PID=

case $(uname -s) in
    MINGW* | MSYS* | CYGWIN*) IS_WINDOWS=1 ;;
    *) IS_WINDOWS= ;;
esac

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- helpers -----------------------------------------------------------------------

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
nok() {
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$1"
    printf '        exit code: %s, output:\n' "$RC"
    sed 's/^/        | /' "$WORK/out"
}
# check DESCRIPTION COMMAND... - pass if COMMAND succeeds
check() { _d=$1; shift; if "$@"; then ok "$_d"; else nok "$_d"; fi; }
out_has() { grep -q -- "$1" "$WORK/out"; }
out_lacks() { ! grep -q -- "$1" "$WORK/out"; }
rc_is() { [ "$RC" -eq "$1" ]; }
rc_not_zero() { [ "$RC" -ne 0 ]; }

# native_path PATH - path as the wrapper under test sees it (Windows form on Windows)
native_path() { if [ -n "$IS_WINDOWS" ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# apmw ARGS... - run the wrapper flavor under test in $PROJ; sets RC, output in $WORK/out
apmw() {
    if [ "$FLAVOR" = cmd ]; then
        (cd "$PROJ" && MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c apmw.cmd "$@") > "$WORK/out" 2>&1
    else
        (cd "$PROJ" && ./apmw "$@") > "$WORK/out" 2>&1
    fi
    RC=$?
}

# replace_in FILE PREFIX NEW_LINE - replace lines starting with PREFIX
replace_in() {
    awk -v p="$2" -v r="$3" 'index($0, p) == 1 { $0 = r } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# make_release VERSION - stamp the scripts from this checkout as a fake apmw release
make_release() {
    _dir=$WORK/releases/download/$1
    mkdir -p "$_dir"
    cp "$ROOT/apmw" "$ROOT/apmw.cmd" "$_dir/"
    sh "$ROOT/scripts/stamp-version.sh" "$1" "$_dir" || exit 1
    (cd "$_dir" && for f in apmw apmw.cmd; do
        printf '%s  %s\n' "$(sha256 "$f")" "$f"
    done > apmw.sha256)
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
    else shasum -a 256 "$1" | awk '{ print $1 }'; fi
}

new_project() { PROJ=$WORK/project-$FLAVOR-$1; mkdir -p "$PROJ"; }

# --- setup -----------------------------------------------------------------------------

PYTHON=$(command -v python3 || command -v python) || { echo "python is required" >&2; exit 1; }
PORT=$((20000 + RANDOM % 20000))
make_release v9.9.9
make_release v9.9.10
make_release v9.9.11
printf '%s  apmw\n%s  apmw.cmd\n' 0000000000000000000000000000000000000000000000000000000000000000 \
    0000000000000000000000000000000000000000000000000000000000000000 > "$WORK/releases/download/v9.9.11/apmw.sha256"

(cd "$WORK/releases" && exec "$PYTHON" -m http.server "$PORT" --bind 127.0.0.1) > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
    curl -fs "http://127.0.0.1:$PORT/download/v9.9.9/apmw.sha256" >/dev/null 2>&1 && break
    sleep 0.2
done

export APMW_WRAPPER_RELEASES_URL=http://127.0.0.1:$PORT
export APMW_HOME
APMW_HOME=$(native_path "$WORK/home")
OFFLINE_URL=http://127.0.0.1:1

FLAVORS="sh"
[ -n "$IS_WINDOWS" ] && FLAVORS="sh cmd"

printf 'platform: %s %s, flavors: %s\n' "$(uname -s)" "$(uname -m)" "$FLAVORS"

# --- tests -------------------------------------------------------------------------------

for FLAVOR in $FLAVORS; do
    if [ "$FLAVOR" = cmd ]; then SCRIPT=apmw.cmd; COMPANION=apmw; else SCRIPT=apmw; COMPANION=apmw.cmd; fi
    printf '\n== %s (%s)\n' "$SCRIPT" "$FLAVOR"

    new_project main
    cp "$WORK/releases/download/v9.9.9/$SCRIPT" "$PROJ/"
    chmod +x "$PROJ/$SCRIPT" # like the README's "chmod +x apmw" after downloading
    PROPS=$PROJ/apm/wrapper/apmw.properties

    apmw --version
    check "first run pins latest apm and runs it" eval 'rc_is 0 && out_has "Agent Package Manager"'
    check "first run adds $COMPANION" test -f "$PROJ/$COMPANION"
    check "first run writes apmVersion" grep -q '^apmVersion=v' "$PROPS"
    check "first run writes 5 checksums" test "$(grep -c '^apmSha256\.' "$PROPS")" -eq 5
    check "first run writes wrapperVersion" grep -q '^wrapperVersion=v9.9.9$' "$PROPS"
    APM_VERSION=$(sed -n 's/^apmVersion=//p' "$PROPS")

    apmw --version
    check "second run uses the cache" eval 'rc_is 0 && out_lacks "downloading"'

    apmw --apmw-version
    check "--apmw-version shows script version" eval 'rc_is 0 && out_has "this script: v9.9.9"'

    apmw nosuchcommand
    check "apm exit code is passed through" rc_is 2

    apmw config get "a b"
    check "arguments with spaces reach apm as one" out_has "'a b'"

    apmw self-update
    check "apm self-update is blocked" eval 'rc_not_zero && out_has "managed by apmw"'

    APMW_APM_RELEASES_URL=$OFFLINE_URL apmw --version
    check "offline with cached apm works" eval 'rc_is 0 && out_has "Agent Package Manager"'

    APMW_HOME=$(native_path "$WORK/home-empty-$FLAVOR") APMW_APM_RELEASES_URL=$OFFLINE_URL apmw --version
    check "offline without cached apm fails" eval 'rc_not_zero && out_has "not in the cache"'

    apmw --apmw-upgrade-apm "$APM_VERSION"
    check "--apmw-upgrade-apm with the pinned version" eval 'rc_is 0 && out_has "already pinned"'

    apmw --apmw-unknown
    check "unknown wrapper option fails" rc_not_zero

    # A wrong checksum must stop the install and leave nothing behind.
    cp "$PROPS" "$WORK/props.bak"
    for p in linux-x86_64 linux-arm64 darwin-x86_64 darwin-arm64 windows-x86_64; do
        replace_in "$PROPS" "apmSha256.$p=" "apmSha256.$p=$(printf '0%.0s' $(seq 1 64))"
    done
    BAD_HOME=$WORK/home-bad-$FLAVOR
    APMW_HOME=$(native_path "$BAD_HOME") apmw --version
    check "wrong checksum is rejected" eval 'rc_not_zero && out_has "checksum mismatch"'
    check "wrong checksum leaves no files in the cache" test -z "$(ls -A "$BAD_HOME/dists/$APM_VERSION" 2>/dev/null)"
    cp "$WORK/props.bak" "$PROPS"

    # Upgrading replaces the running script (the tricky part for cmd).
    apmw --apmw-upgrade 9.9.10
    check "--apmw-upgrade succeeds" eval 'rc_is 0 && out_has "updated apmw to v9.9.10"'
    check "--apmw-upgrade updates wrapperVersion" grep -q '^wrapperVersion=v9.9.10$' "$PROPS"
    apmw --apmw-version
    check "upgraded script runs" eval 'rc_is 0 && out_has "this script: v9.9.10"'
    if [ "$FLAVOR" = sh ]; then
        check "upgraded apmw stays executable" test -x "$PROJ/apmw"
    fi

    cp "$PROJ/apmw" "$WORK/apmw.before"
    apmw --apmw-upgrade 9.9.11
    check "tampered release is rejected" eval 'rc_not_zero && out_has "checksum mismatch"'
    check "tampered release leaves the scripts alone" cmp -s "$PROJ/apmw" "$WORK/apmw.before"

    # A deleted companion is not added back after the first run.
    new_project nocompanion
    cp "$WORK/releases/download/v9.9.9/$SCRIPT" "$PROJ/"
    chmod +x "$PROJ/$SCRIPT"
    mkdir -p "$PROJ/apm/wrapper"
    cp "$PROPS" "$PROJ/apm/wrapper/"
    apmw --version
    check "existing project: companion is not re-added" eval 'rc_is 0 && test ! -f "$PROJ/$COMPANION"'
done

if [ -n "$IS_WINDOWS" ]; then
    printf '\n== Windows\n'
    FLAVOR=cmd
    new_project shared
    cp "$WORK/releases/download/v9.9.9/apmw.cmd" "$PROJ/"
    mkdir -p "$PROJ/apm/wrapper"
    cp "$WORK/project-sh-main/apm/wrapper/apmw.properties" "$PROJ/apm/wrapper/"
    apmw --version
    check "apmw.cmd uses the cache that ./apmw filled" eval 'rc_is 0 && out_lacks "downloading"'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
