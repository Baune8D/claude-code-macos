#!/usr/bin/env bash

# Suite for put-gnu-tools-on-path.sh. Run it with the bash on PATH, which is what
# settings.json hands the hook:
#
#     bash .claude/hooks/put-gnu-tools-on-path.test.sh
#
# Every case points the hook at a throwaway Homebrew prefix under mktemp through
# HOMEBREW_PREFIX, so the suite never reads the formulas on the machine it runs on, nor
# writes to a real CLAUDE_ENV_FILE. A fake `uname` first on PATH decides whether the hook
# believes it is on a Mac, so both branches run on any machine.
#
# The silent cases matter as much as the ones that write. This hook fires at the top of
# every session, in every checkout on every machine, and a stray line in the env
# file — in a pod with no Homebrew, in a terminal that already had the tools — is sourced
# by every Bash call for the rest of that session. And the hint it emits when a formula
# is missing lands in the model's context, so it has to appear only on a Mac, only when
# something is missing, and name the right thing.

set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/put-gnu-tools-on-path.sh"
# The bash on PATH, resolved once: cases rearrange PATH to hold only a fake uname, a jq or
# nothing, and the hook is written for 5, so it must not fall to /bin/bash there.
BASH_BIN="$(command -v bash)"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Two bin dirs the cases put first on PATH: one whose `uname` answers Darwin, one Linux.
mkdir -p "$WORK/mac" "$WORK/linux"
printf '#!/bin/sh\necho Darwin\n' > "$WORK/mac/uname"
printf '#!/bin/sh\necho Linux\n' > "$WORK/linux/uname"
chmod +x "$WORK/mac/uname" "$WORK/linux/uname"
# Where the suite's own jq is, for the JSON cases; the no-jq case leaves it off PATH.
JQ_DIR="$(dirname "$(command -v jq)")"

# Fresh prefix and env file per case, so no case sees another's formulas or write.
fresh() {
    PREFIX="$WORK/brew-$RANDOM$RANDOM"
    mkdir -p "$PREFIX/opt"
    ENV_FILE="$WORK/env-$RANDOM$RANDOM.sh"
    : > "$ENV_FILE"
}

# installed <formula>... — gives each formula a gnubin directory under the case's prefix.
installed() {
    local formula
    for formula in "$@"; do
        mkdir -p "$PREFIX/opt/$formula/libexec/gnubin"
    done
}

gnubin() {
    printf '%s/opt/%s/libexec/gnubin' "$PREFIX" "$1"
}

# run_hook [VAR=value ...] — runs the hook against the case's prefix, on a Mac, with a
# plain PATH unless a case overrides it and CLAUDE_ENV_FILE set unless a case unsets it.
# Captures stdout, stderr and the exit status.
run_hook() {
    local out
    out=$(env -i PATH="$WORK/mac:$JQ_DIR:/usr/bin:/bin" HOMEBREW_PREFIX="$PREFIX" CLAUDE_ENV_FILE="$ENV_FILE" "$@" \
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

# Every case: exit 0, nothing on stdout, nothing on stderr.
quiet_and_ok() {
    local desc="$1"
    [[ "$STATUS" -eq 0 ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: exits 0" "status $STATUS"
    [[ -z "$STDOUT" ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: silent on stdout" "stdout: $STDOUT"
    [[ -z "$STDERR" ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: silent on stderr" "stderr: $STDERR"
}

# ok_with_hint <description> <must name>... — exit 0, nothing on stderr, and on stdout the
# SessionStart JSON with one line for the agent in additionalContext, naming every
# argument, and one line for the developer in systemMessage. The two differ on purpose:
# the agent gets the fact, the developer gets what to do.
ok_with_hint() {
    local desc="$1" ctx msg name
    shift
    [[ "$STATUS" -eq 0 ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: exits 0" "status $STATUS"
    [[ -z "$STDERR" ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: silent on stderr" "stderr: $STDERR"
    ctx=$(printf '%s' "$STDOUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
    msg=$(printf '%s' "$STDOUT" | jq -r '.systemMessage // ""' 2>/dev/null)
    [[ -n "$ctx" && -n "$msg" && "$ctx" != "$msg" && "$(printf '%s' "$STDOUT" | jq -r '.hookSpecificOutput.hookEventName')" == SessionStart ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: a different line for each audience, as SessionStart JSON" "stdout: $STDOUT"
    [[ "$ctx" != *$'\n'* && "${#ctx}" -le 160 && "$msg" != *$'\n'* && "${#msg}" -le 200 ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: both lines are one line and short" "agent ${#ctx}: $ctx / dev ${#msg}: $msg"
    [[ "$ctx" != *"brew install"* ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: the agent's line carries no install instructions" "ctx: $ctx"
    for name in "$@"; do
        [[ "$ctx" == *"$name"* ]] && verdict=yes || verdict=no
        pass_if "$verdict" "$desc: agent line names $name" "ctx: $ctx"
    done
}

# expect_dev <description> <substring> — the developer's line says this.
expect_dev() {
    local msg
    msg=$(printf '%s' "$STDOUT" | jq -r '.systemMessage // ""' 2>/dev/null)
    [[ "$msg" == *"$2"* ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$1: developer line says $2" "msg: $msg"
}

# expect_written <description> <expected prepend> — the PATH line, and only one of them.
# The hook writes nothing else: an earlier version also dropped the grep and find shell
# functions, and a line reappearing here is that coming back.
expect_written() {
    local desc="$1" expected="$2" body
    body=$(cat "$ENV_FILE")
    [[ "$body" == *"export PATH=\"$expected:\${PATH}\""* ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc" "got: $body"
    [[ "$(printf '%s\n' "$body" | command grep -c 'export PATH=')" -eq 1 ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: exactly one PATH line" "got: $body"
    [[ "$body" != *unset* && "$(printf '%s\n' "$body" | command grep -c .)" -eq 1 ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc: and nothing else" "got: $body"
}

expect_nothing_written() {
    local desc="$1"
    [[ ! -s "$ENV_FILE" ]] && verdict=yes || verdict=no
    pass_if "$verdict" "$desc" "file: $(cat "$ENV_FILE")"
}

# --- writes -------------------------------------------------------------------------

# All seven, in the order the hook lists them — not the order the file system enumerates
# in — so which formula wins a name both provide is decided by the list.
fresh; installed grep gnu-which gnu-tar gnu-sed gawk findutils coreutils; run_hook
quiet_and_ok 'all formulas installed'
expect_written 'all formulas installed: one prepend, in list order' \
    "$(gnubin coreutils):$(gnubin findutils):$(gnubin gawk):$(gnubin gnu-sed):$(gnubin gnu-tar):$(gnubin gnu-which):$(gnubin grep)"

# The line is sourced by a shell, so it has to be one a shell accepts, and it has to put
# the tools FIRST — a later entry would lose to /usr/bin/sed.
resolved=$(env -i PATH="/usr/bin:/bin" bash --norc --noprofile -c "source '$ENV_FILE'; printf '%s' \"\$PATH\"")
[[ "$resolved" == "$(gnubin coreutils):"*":$(gnubin grep):/usr/bin:/bin" ]] && verdict=yes || verdict=no
pass_if "$verdict" 'all formulas installed: the written line, sourced, puts the tools first' "PATH became: $resolved"

# A Mac with some of them: only what is there, order kept — and one line saying which
# commands stayed macOS, naming the formulas to install, not the ones that are there.
fresh; installed coreutils gnu-sed; run_hook
ok_with_hint 'two formulas installed' "This session's find, xargs, awk, tar, which and grep are the macOS builds, not GNU."
expect_dev 'two formulas installed' 'brew install findutils gawk gnu-tar gnu-which grep'
expect_written 'two formulas installed: only those two' "$(gnubin coreutils):$(gnubin gnu-sed)"
ctx=$(printf '%s' "$STDOUT" | jq -r '.hookSpecificOutput.additionalContext')
[[ "$ctx" != *coreutils* && "$ctx" != *"gnu-sed"* && "$ctx" != *" sed"* ]] && verdict=yes || verdict=no
pass_if "$verdict" 'two formulas installed: hint does not name what is installed' "ctx: $ctx"

# One formula missing: singular grammar, and nothing about the six that are there.
fresh; installed coreutils findutils gnu-sed gnu-tar gnu-which grep; run_hook
ok_with_hint 'one formula missing' "This session's awk is the macOS build, not GNU."
expect_dev 'one formula missing' 'GNU tools missing. Fix: brew install gawk'

# The same, without jq on PATH: the agent's line still reaches it as plain stdout.
fresh; installed coreutils gnu-sed
out=$(env -i PATH="$WORK/mac:/bin" HOMEBREW_PREFIX="$PREFIX" CLAUDE_ENV_FILE="$ENV_FILE" "$BASH_BIN" "$HOOK" 2>"$WORK/stderr" </dev/null)
STATUS=$?; STDOUT="$out"; STDERR=$(cat "$WORK/stderr")
[[ "$STATUS" -eq 0 && -z "$STDERR" && "$STDOUT" == "This session's find, xargs, awk, tar, which and grep are the macOS builds, not GNU." ]] && verdict=yes || verdict=no
pass_if "$verdict" 'two formulas installed, no jq: plain one-line hint' "stdout: $STDOUT / stderr: $STDERR"
expect_written 'two formulas installed, no jq: still writes' "$(gnubin coreutils):$(gnubin gnu-sed)"

# Homebrew has gnubin directories the list does not name — inetutils shadows ping,
# hostname and telnet, libtool its own two — and they must stay off PATH.
fresh; installed coreutils inetutils libtool gsed; run_hook
expect_written 'unlisted gnubin directories are left alone' "$(gnubin coreutils)"

# A formula that is installed but has no gnubin (a future formula, a broken link) is
# nothing to put on PATH.
fresh; installed coreutils; mkdir -p "$PREFIX/opt/gnu-sed/bin"; run_hook
expect_written 'a formula without a gnubin directory is skipped' "$(gnubin coreutils)"

# A file that already has content is appended to, never truncated: other SessionStart
# hooks write to the same file.
fresh; installed coreutils; printf 'export OTHER=1\n' > "$ENV_FILE"; run_hook
[[ "$(head -n 1 "$ENV_FILE")" == 'export OTHER=1' && "$(wc -l < "$ENV_FILE")" -eq 2 ]] && verdict=yes || verdict=no
pass_if "$verdict" 'appends after what other hooks wrote' "file: $(tr '\n' '|' < "$ENV_FILE")"

# Already on PATH in part — the terminal had some, or a nested session's parent arranged
# them. Only what is missing is written, so nothing is repeated.
fresh; installed coreutils findutils gawk gnu-sed gnu-tar gnu-which grep; run_hook PATH="$(gnubin gnu-sed):$WORK/mac:$JQ_DIR:/usr/bin:/bin"
quiet_and_ok 'some tools already on PATH'
expect_written 'some tools already on PATH: writes only the missing ones' \
    "$(gnubin coreutils):$(gnubin findutils):$(gnubin gawk):$(gnubin gnu-tar):$(gnubin gnu-which):$(gnubin grep)"

# --- silent -------------------------------------------------------------------------

# No Homebrew at the configured prefix. Off a Mac that is the images, and there is nothing
# to say. HOMEBREW_PREFIX set means "only there" — the hook must not fall back to
# /opt/homebrew, where this machine's real formulas are.
fresh; rmdir "$PREFIX/opt"; run_hook PATH="$WORK/linux:$JQ_DIR:/usr/bin:/bin"
quiet_and_ok 'no Homebrew prefix, not a Mac'
expect_nothing_written 'no Homebrew prefix, not a Mac: writes nothing'

fresh; run_hook PATH="$WORK/linux:$JQ_DIR:/usr/bin:/bin" HOMEBREW_PREFIX="$WORK/does-not-exist"
quiet_and_ok 'HOMEBREW_PREFIX pointing nowhere, not a Mac'
expect_nothing_written 'HOMEBREW_PREFIX pointing nowhere: writes nothing, no fallback'

# On a Mac, no Homebrew is the un-onboarded developer: every tool is the macOS build, and
# the hint says so and names all seven formulas.
fresh; rmdir "$PREFIX/opt"; run_hook
ok_with_hint 'no Homebrew prefix on a Mac' 'date, stat, find, xargs, awk, sed, tar, which and grep'
expect_dev 'no Homebrew prefix on a Mac' 'Homebrew is missing. Fix: install it from https://brew.sh'
expect_nothing_written 'no Homebrew prefix on a Mac: writes nothing'

# Homebrew without any of the formulas — a fresh Mac before `brew install`.
fresh; installed inetutils; run_hook
ok_with_hint 'Homebrew without the GNU formulas' 'date, stat, find, xargs, awk, sed, tar, which and grep'
expect_dev 'Homebrew without the GNU formulas' 'brew install coreutils findutils gawk gnu-sed gnu-tar gnu-which grep'
expect_nothing_written 'Homebrew without the GNU formulas: writes nothing'

# Off a Mac, a missing formula is not worth a line: the plain names already resolve GNU
# there, whatever Linuxbrew has or has not got.
fresh; installed coreutils; run_hook PATH="$WORK/linux:$JQ_DIR:/usr/bin:/bin"
quiet_and_ok 'missing formulas, not a Mac'
expect_written 'missing formulas, not a Mac: still writes what is there' "$(gnubin coreutils)"

# All already on PATH — nothing to add, so not even an empty prepend.
fresh; installed coreutils findutils gawk gnu-sed gnu-tar gnu-which grep
all_on_path="$(gnubin coreutils):$(gnubin findutils):$(gnubin gawk):$(gnubin gnu-sed):$(gnubin gnu-tar):$(gnubin gnu-which):$(gnubin grep)"
run_hook PATH="$all_on_path:$WORK/mac:$JQ_DIR:/usr/bin:/bin"
quiet_and_ok 'all tools already on PATH'
expect_nothing_written 'all tools already on PATH: writes nothing'

# On PATH but BEHIND /usr/bin is not "already on PATH": that sed has lost the lookup, and
# the hook has to prepend it as if it were absent.
fresh; installed coreutils gnu-sed; run_hook PATH="$WORK/mac:$JQ_DIR:/usr/bin:$(gnubin gnu-sed):/bin"
expect_written 'a gnubin behind /usr/bin on PATH is prepended anyway' "$(gnubin coreutils):$(gnubin gnu-sed)"

# /bin is a system-tools directory on a Mac as much as /usr/bin — date, ls and cp live
# there — so a gnubin behind /bin has lost too.
fresh; installed gnu-sed; run_hook PATH="/bin:$(gnubin gnu-sed):$WORK/mac:$JQ_DIR:/usr/bin"
expect_written 'a gnubin behind /bin on PATH is prepended anyway' "$(gnubin gnu-sed)"

# Ahead of /usr/bin is the case that counts as present — and so is a PATH with no /usr/bin
# at all, since there is then no macOS sed for the entry to lose to.
fresh; installed coreutils gnu-sed; run_hook PATH="$(gnubin gnu-sed):$WORK/mac:$JQ_DIR:/usr/bin:/bin"
expect_written 'a gnubin ahead of /usr/bin is not repeated' "$(gnubin coreutils)"
fresh; installed gnu-sed; run_hook PATH="$WORK/mac:$JQ_DIR:$(gnubin gnu-sed):/bin"
expect_nothing_written 'a gnubin on a PATH without /usr/bin already wins, so nothing is written'

# A directory whose name merely starts with a gnubin path is not that gnubin.
fresh; installed coreutils; run_hook PATH="$(gnubin coreutils)-old:$WORK/mac:$JQ_DIR:/usr/bin:/bin"
expect_written 'a look-alike PATH entry does not count as present' "$(gnubin coreutils)"

# No CLAUDE_ENV_FILE: an older Claude Code, or a hook event that does not carry one.
# Nothing to write to — and on a Mac that means every tool is the macOS build, which is
# said once so that "absent that line, the tools are GNU" holds. Off a Mac, silence.
fresh; installed coreutils
out=$(env -i PATH="$WORK/mac:$JQ_DIR:/usr/bin:/bin" HOMEBREW_PREFIX="$PREFIX" "$BASH_BIN" "$HOOK" 2>"$WORK/stderr" </dev/null)
STATUS=$?; STDOUT="$out"; STDERR=$(cat "$WORK/stderr")
ok_with_hint 'CLAUDE_ENV_FILE unset on a Mac' 'date, stat, find, xargs, awk, sed, tar, which and grep'
expect_dev 'CLAUDE_ENV_FILE unset on a Mac' 'too old for these hooks. Fix: claude update'
expect_nothing_written 'CLAUDE_ENV_FILE unset on a Mac: touches no file'

fresh; installed coreutils; run_hook CLAUDE_ENV_FILE=
ok_with_hint 'CLAUDE_ENV_FILE empty on a Mac' 'macOS builds'
expect_dev 'CLAUDE_ENV_FILE empty on a Mac' 'Fix: claude update'
expect_nothing_written 'CLAUDE_ENV_FILE empty on a Mac: writes nothing'

fresh; installed coreutils
out=$(env -i PATH="$WORK/linux:$JQ_DIR:/usr/bin:/bin" HOMEBREW_PREFIX="$PREFIX" "$BASH_BIN" "$HOOK" 2>"$WORK/stderr" </dev/null)
STATUS=$?; STDOUT="$out"; STDERR=$(cat "$WORK/stderr")
quiet_and_ok 'CLAUDE_ENV_FILE unset, not a Mac'
expect_nothing_written 'CLAUDE_ENV_FILE unset, not a Mac: touches no file'

# --- hook contract ------------------------------------------------------------------

# SessionStart hands the hook a JSON payload on stdin. It is not read, and it must not
# matter what it says.
fresh; installed coreutils
out=$(printf '{"hook_event_name":"SessionStart","source":"resume"}' \
    | env -i PATH="$WORK/mac:$JQ_DIR:/usr/bin:/bin" HOMEBREW_PREFIX="$PREFIX" CLAUDE_ENV_FILE="$ENV_FILE" "$BASH_BIN" "$HOOK" 2>"$WORK/stderr")
STATUS=$?; STDOUT="$out"; STDERR=$(cat "$WORK/stderr")
ok_with_hint 'with a SessionStart payload on stdin' 'find, xargs, awk, sed, tar, which and grep'
expect_dev 'with a SessionStart payload on stdin' 'brew install findutils gawk gnu-sed gnu-tar gnu-which grep'
expect_written 'with a SessionStart payload on stdin: still writes' "$(gnubin coreutils)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
