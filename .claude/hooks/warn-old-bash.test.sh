#!/usr/bin/env bash

# Suite for warn-old-bash.sh. Run it with the bash on PATH, which is what settings.json
# hands the hook:
#
#     bash .claude/hooks/warn-old-bash.test.sh
#
# The hook asks `bash --version` through PATH, so every case puts a fake `bash` first on
# PATH that prints the version line under test. The hook itself is started with the real
# bash, resolved once before PATH is rearranged.

set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/warn-old-bash.sh"
BASH_BIN="$(command -v bash)"
JQ_DIR="$(dirname "$(command -v jq)")"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fake_bash <version line> — a directory whose `bash` prints that line for --version.
fake_bash() {
    FAKE="$WORK/fake-$RANDOM$RANDOM"
    mkdir -p "$FAKE"
    printf '#!/bin/sh\necho "%s"\n' "$1" > "$FAKE/bash"
    chmod +x "$FAKE/bash"
}

# other_bash <version line> — a bash somewhere else entirely, under its own name, for the
# cases where CLAUDE_CODE_SHELL names a shell by absolute path and PATH holds a different
# one. Sets OTHER to that path.
other_bash() {
    local dir="$WORK/other-$RANDOM$RANDOM"
    mkdir -p "$dir"
    printf '#!/bin/sh\necho "%s"\n' "$1" > "$dir/bash"
    chmod +x "$dir/bash"
    OTHER="$dir/bash"
}

# run_hook [PATH=...] [CLAUDE_CODE_SHELL=...] — runs the hook under a PATH that starts with
# the fake bash. The second argument, when given, is the override Claude Code was told to
# run; without it the variable is absent, which is the bare-name default.
run_hook() {
    local out vars=()
    [[ -n "${2:-}" ]] && vars+=("CLAUDE_CODE_SHELL=$2")
    out=$(env -i PATH="${1:-$FAKE:$JQ_DIR:/usr/bin:/bin}" "${vars[@]}" \
        "$BASH_BIN" "$HOOK" 2>"$WORK/stderr" </dev/null)
    STATUS=$?
    STDOUT="$out"
    STDERR=$(cat "$WORK/stderr")
}

pass_if() {
    local verdict="$1" desc="$2" detail="${3:-}"
    if [[ "$verdict" == yes ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n' "$desc"
        [[ -n "$detail" ]] && printf '      %s\n' "$detail"
    fi
}

ok_and_silent() {
    [[ "$STATUS" -eq 0 && -z "$STDOUT" && -z "$STDERR" ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$1: exits 0 and says nothing" "status $STATUS stdout: $STDOUT stderr: $STDERR"
}

# ok_with_hint <desc> <must name>... — exit 0, quiet stderr, one JSON line for both audiences.
ok_with_hint() {
    local desc="$1" ctx msg name
    shift
    [[ "$STATUS" -eq 0 && -z "$STDERR" ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: exits 0 with a quiet stderr" "status $STATUS stderr: $STDERR"
    ctx=$(printf '%s' "$STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
    msg=$(printf '%s' "$STDOUT" | jq -r '.systemMessage // ""' 2>/dev/null)
    [[ -n "$ctx" && -n "$msg" && "$ctx" != "$msg" ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: a different line for each audience" "stdout: $STDOUT"
    [[ "$ctx" != *$'\n'* && "${#ctx}" -le 160 && "$msg" != *$'\n'* && "${#msg}" -le 200 ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: both lines are one line and short" "agent ${#ctx}: $ctx / dev ${#msg}: $msg"
    [[ "$ctx" != *"brew install"* && "$ctx" != *"$FAKE"* ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: the agent's line carries no path and no instructions" "ctx: $ctx"
    for name in "$@"; do
        [[ "$ctx" == *"$name"* ]] && verdict=yes || verdict=no
        pass_if "$verdict" "$desc: agent line names $name" "ctx: $ctx"
    done
}

# expect_dev <description> <substring>... — the developer's line says each of these.
expect_dev() {
    local desc="$1" msg name
    shift
    msg=$(printf '%s' "$STDOUT" | jq -r '.systemMessage // ""' 2>/dev/null)
    for name in "$@"; do
        [[ "$msg" == *"$name"* ]] && verdict=yes || verdict=no
        pass_if "$verdict" "$desc: developer line says $name" "msg: $msg"
    done
}

# --- silent ---------------------------------------------------------------------------

fake_bash 'GNU bash, version 5.3.15(1)-release (aarch64-apple-darwin25.4.0)'; run_hook
ok_and_silent 'bash 5.3'

fake_bash 'GNU bash, version 5.0.17(1)-release (x86_64-pc-linux-gnu)'; run_hook
ok_and_silent 'bash 5.0'

fake_bash 'GNU bash, version 6.0.0(1)-release (x86_64-pc-linux-gnu)'; run_hook
ok_and_silent 'a future bash 6'

# The real bash on this machine, first on PATH. Silent when it is 5 or newer, a hint when it
# is older — the expectation comes from that bash's own version, not from the one the suite
# happens to run under, which need not be the same binary.
# shellcheck disable=SC2016  # the child bash expands $BASH_VERSION, not this one
real_version=$("$BASH_BIN" -c 'printf %s "$BASH_VERSION"')
run_hook "$JQ_DIR:$(dirname "$BASH_BIN"):/usr/bin:/bin"
if [[ "${real_version%%.*}" -ge 5 ]]; then
    ok_and_silent 'the real bash on PATH'
else
    ok_with_hint 'the real bash on PATH' 'not 5' "$real_version"
fi

# --- hints ----------------------------------------------------------------------------

# Apple's bash: the case the hook exists for. Names the version, where it came from, and
# what to do.
fake_bash 'GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)'; run_hook
ok_with_hint 'Apple bash 3.2' 'not 5' '3.2.57'
expect_dev 'Apple bash 3.2' "$FAKE/bash" 'need 5' 'brew install bash'

fake_bash 'GNU bash, version 4.4.23(1)-release (x86_64-pc-linux-gnu)'; run_hook
ok_with_hint 'bash 4.4' 'not 5' '4.4.23'
expect_dev 'bash 4.4' 'bash 4 at' 'brew install bash'

# A bash whose --version says nothing parseable is reported rather than assumed fine.
fake_bash 'something that is not a version line'; run_hook
ok_with_hint 'unparseable --version' 'unreadable' 'not 5'
expect_dev 'unparseable --version' 'reports no version' 'brew install bash'

# --- CLAUDE_CODE_SHELL names the shell ------------------------------------------------

# The case this hook was blind to: the override is an absolute path to Apple's bash, while
# PATH's first bash is Homebrew's 5. Asking PATH would report the 5 and say nothing; the
# Bash tool runs the 3.2.
fake_bash 'GNU bash, version 5.3.15(1)-release (aarch64-apple-darwin25)'
other_bash 'GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)'
run_hook '' "$OTHER"
ok_with_hint 'override to an old bash by path' 'not 5' '3.2.57'
expect_dev 'override to an old bash by path' "$OTHER" 'need 5'

# And the other way: a modern bash named by path is fine however old PATH's bash is.
fake_bash 'GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)'
other_bash 'GNU bash, version 5.3.15(1)-release (aarch64-apple-darwin25)'
run_hook '' "$OTHER"
ok_and_silent 'override to a modern bash by path'

# A bare name is resolved through PATH, which is the lookup Claude Code makes for it and
# the one this hook made before the variable was read at all.
fake_bash 'GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)'
run_hook '' bash
ok_with_hint 'bare-name override' 'not 5' '3.2.57'
expect_dev 'bare-name override' "$FAKE/bash" 'need 5'

# An override naming a shell that is not there reports no version rather than passing for
# a 5, and the developer's line names the value, which is the thing to correct.
fake_bash 'GNU bash, version 5.3.15(1)-release (aarch64-apple-darwin25)'
run_hook '' /nonexistent/bash
ok_with_hint 'override to a missing shell' 'unreadable' 'not 5'
expect_dev 'override to a missing shell' '/nonexistent/bash' 'reports no version'

# Without jq the line still reaches the agent as plain text. The hook needs nothing but
# the bash it is asking about, so PATH is the fake alone.
fake_bash 'GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)'; run_hook "$FAKE"
[[ "$STATUS" -eq 0 && -z "$STDERR" && "$STDOUT" == *'3.2.57'* && "$STDOUT" != '{'* ]] && verdict=yes || verdict=no
pass_if "$verdict" 'no jq: plain one-line hint' "stdout: $STDOUT stderr: $STDERR"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
