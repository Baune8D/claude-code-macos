#!/usr/bin/env bash

# Suite for warn-shell-not-bash.sh. Run it with the bash on PATH, the way settings.json
# starts the hook:
#
#     bash .claude/hooks/warn-shell-not-bash.test.sh
#
# The hook reads two variables and `uname`, so every case is a pair of variables and a fake
# `uname` that reports the platform under test. Nothing on the machine is read and nothing
# is written.

set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/warn-shell-not-bash.sh"
BASH_BIN="$(command -v bash)"
JQ_DIR="$(dirname "$(command -v jq)")"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fake_uname <sysname> — a directory whose `uname` reports that system, first on PATH, so
# the Mac-only cases and the Linux ones both run on whatever machine the suite is on.
fake_uname() {
    FAKE="$WORK/fake-$RANDOM$RANDOM"
    mkdir -p "$FAKE"
    printf '#!/bin/sh\necho "%s"\n' "$1" > "$FAKE/uname"
    chmod +x "$FAKE/uname"
}

# run_hook <CLAUDE_CODE_SHELL> <SHELL> [PATH] — either variable may be the literal `unset`,
# which leaves it out of the environment rather than setting it empty. `env -i` so nothing
# from the suite's own session reaches the hook.
#
# Leaving SHELL out does not reach the hook as an unset SHELL: bash assigns it the login
# shell from the passwd entry when it starts without one, and settings.json starts this
# hook with `bash`. An empty SHELL is what the unnameable case looks like in practice.
run_hook() {
    local vars=() out
    [[ "$1" != unset ]] && vars+=("CLAUDE_CODE_SHELL=$1")
    [[ "$2" != unset ]] && vars+=("SHELL=$2")
    out=$(env -i PATH="${3:-${FAKE:-}:$JQ_DIR:/usr/bin:/bin}" "${vars[@]}" \
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

# ok_with_hint <desc> <must name>... — exit 0, quiet stderr, one JSON line for both
# audiences, the way the other two suites check it.
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
    [[ "$ctx" != *'settings.json'* && "$ctx" != *'Fix:'* ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: the agent's line carries no instructions" "ctx: $ctx"
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

fake_uname Darwin

# The settings.json in this repository, and the environment measured on 2.1.278 with it.
run_hook bash bash
ok_and_silent 'CLAUDE_CODE_SHELL=bash'

# An absolute path is still bash. Which bash it is belongs to warn-old-bash.sh.
run_hook /opt/homebrew/bin/bash /bin/zsh
ok_and_silent 'an absolute Homebrew bash'

run_hook /bin/bash unset
ok_and_silent "Apple's bash by path"

# No block, but a login shell that is already bash: nothing to fix.
run_hook unset /opt/homebrew/bin/bash
ok_and_silent 'no override, login shell is bash'

# Off a Mac the login shell is bash already and the block is not worth a line.
fake_uname Linux
run_hook unset /bin/zsh
ok_and_silent 'zsh on Linux'
run_hook unset unset
ok_and_silent 'nothing set on Linux'

# --- hints ----------------------------------------------------------------------------

fake_uname Darwin

# The case the hook exists for: a plugin install with no env block, on a stock Mac.
run_hook unset /bin/zsh
ok_with_hint 'stock Mac, no override' 'zsh' 'not bash'
expect_dev 'stock Mac, no override' 'runs zsh' 'CLAUDE_CODE_SHELL' '"SHELL"' 'settings.json'

# An override to something that is not bash is reported by its name too.
run_hook /bin/zsh /bin/zsh
ok_with_hint 'override to zsh' 'zsh' 'not bash'
run_hook /usr/bin/fish /bin/zsh
ok_with_hint 'override to fish' 'fish' 'not bash'

# Neither value reaches the hook: the shell cannot be named, only that it is not bash.
run_hook '' ''
ok_with_hint 'no value for either' 'not bash'
expect_dev 'no value for either' 'unset' 'CLAUDE_CODE_SHELL' '"SHELL"'

# An empty override falls through to the login shell, the way the shell lookup does.
run_hook '' /bin/zsh
ok_with_hint 'empty override' 'zsh' 'not bash'

# Without jq the line still reaches the agent as plain text. macOS 26 ships a jq in
# /usr/bin, so a PATH of the fake uname alone is what takes it away; the hook needs
# nothing else.
fake_uname Darwin
run_hook unset /bin/zsh "$FAKE"
[[ "$STATUS" -eq 0 && -z "$STDERR" && "$STDOUT" == *'zsh'* && "$STDOUT" != '{'* ]] && verdict=yes || verdict=no
pass_if "$verdict" 'no jq: plain one-line hint' "stdout: $STDOUT stderr: $STDERR"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
