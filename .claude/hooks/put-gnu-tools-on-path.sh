#!/usr/bin/env bash

# SessionStart: puts Homebrew's GNU builds first on the PATH the Bash tool resolves, so
# `sed`, `date`, `stat`, `awk`, `tar` and the rest are GNU in an agent session on a Mac.
# `grep` and `find` are deliberately left as Claude Code ships them — see below.
#
# Homebrew ships each of those formulas with a `libexec/gnubin` directory holding the
# builds under their plain names — `sed`, not `gsed`. Those directories are what goes on
# PATH, one per installed formula, in the order listed. Nothing is copied or linked, so a
# `brew install` or `brew uninstall` takes effect at the next session with no step in
# between.
#
# It goes through CLAUDE_ENV_FILE rather than the profile because the profile cannot reach
# the Bash tool. Claude Code does not source it per command: at session start it captures
# a shell snapshot under ~/.claude/shell-snapshots/ and replays it for every Bash call,
# and the `export PATH` line in that snapshot is written from Claude Code's OWN process
# environment plus the plugin bin directories — the login shell it captures in is asked
# for its PATH only on Windows. So whatever the profile does, the session's PATH is the
# terminal's. Measured on 2.1.263: the capture shell had CLAUDECODE=1 and a profile guard
# fired in it, and the snapshot still came out without the directory it added. A
# SessionStart hook may append shell exports to the file CLAUDE_ENV_FILE names, and Claude
# Code sources that file after the snapshot, so a PATH prepend written here wins. Verified
# on `startup` and `resume`.
#
# `grep` and `find` are not changed by any of this, on purpose. Claude Code installs both
# as shell functions in the session snapshot, re-execing its own binary as ugrep and bfs,
# and a function beats a PATH lookup — so the bare names stay those two however the gnubin
# directories sit on PATH. An earlier version of this hook wrote `unset -f grep` and
# `unset -f find` to CLAUDE_ENV_FILE so the bare names became the GNU builds. That was
# taken out again after measuring: across two dozen common idioms the two engines never
# disagreed on syntax, and every difference was in ugrep's defaults (`--ignore-files
# --hidden -I`), which make a bare `grep -r` honour .gitignore and skip binaries — a
# better default than GNU's for an agent searching a repo. What the grep and findutils
# formulas still buy is that scripts, `command grep` and the wrapper's own fall-through
# for `-z` and `--null` all reach the GNU builds rather than the macOS ones.
#
# Only for the agent, deliberately: a developer's own terminal keeps the macOS tools, and
# nothing outside a Claude Code session changes.
#
# A directory is skipped only when it already sits ahead of /usr/bin on PATH — one that is
# merely present, behind the system tools, has lost the lookup and is prepended like one
# that is absent.
#
# Silent when it succeeds: SessionStart stdout is appended to the model's context, and a
# line saying the PATH was arranged costs context on every session and teaches nothing.
# Inert off a Mac — the images, where the plain names already resolve GNU. Always exits
# 0: a missing tool is not worth failing a session start over.
#
# It does speak on a Mac where it cannot deliver — a formula missing, no Homebrew, or a
# Claude Code that supplies no CLAUDE_ENV_FILE — once, because the agent would otherwise
# believe a CLAUDE.md's promise that its tools are GNU until `sed -i` or `date -d` fails
# halfway through something else. The agent's line names the commands that are the macOS
# builds and no more; the developer's line names the `brew install` to run. It reaches
# both audiences through the SessionStart JSON: `additionalContext` for the agent,
# `systemMessage` for the developer. A Mac with all seven formulas never sees it.

set -u

# The formulas whose gnubin goes on PATH, and the ones the hint asks to `brew install`.
formulas=(coreutils findutils gawk gnu-sed gnu-tar gnu-which grep)

# The commands an agent actually types from each formula, for the hint. Not exhaustive —
# coreutils alone is a hundred — just the ones an agent types most.
tools_of() {
    case "$1" in
        coreutils) printf 'date stat' ;;
        findutils) printf 'find xargs' ;;
        gawk) printf 'awk' ;;
        gnu-sed) printf 'sed' ;;
        gnu-tar) printf 'tar' ;;
        gnu-which) printf 'which' ;;
        # A bare `grep` is Claude Code's ugrep either way (see the header); what the hint
        # is about is the build that scripts and an explicit `command grep` get.
        grep) printf 'grep' ;;
        *) printf '%s' "$1" ;;
    esac
}

# name_tools <formula>... — sets TOOLS to "sed, awk and tar" for the commands those
# formulas provide, in list order, and TOOLS_N to how many, so a caller can pick is/are.
name_tools() {
    local formula list=() joined
    for formula in "$@"; do
        # shellcheck disable=SC2207  # tools_of prints fixed, space-separated command names
        list+=($(tools_of "$formula"))
    done
    TOOLS_N="${#list[@]}"
    if [[ "$TOOLS_N" -eq 1 ]]; then
        TOOLS="${list[0]}"
    else
        joined=$(printf '%s, ' "${list[@]:0:TOOLS_N-1}")
        TOOLS="${joined%, } and ${list[TOOLS_N-1]}"
    fi
}

# agent_line <formula>... — the fact, for the agent: "This session's sed is the macOS
# build, not GNU." for one command, "... sed, awk and tar are the macOS builds ..." for more.
agent_line() {
    name_tools "$@"
    if [[ "$TOOLS_N" -eq 1 ]]; then
        printf "This session's %s is the macOS build, not GNU." "$TOOLS"
    else
        printf "This session's %s are the macOS builds, not GNU." "$TOOLS"
    fi
}

# hint <for the agent> <for the developer> — one short line each. The agent gets the fact
# and nothing else: it has the portable forms in CLAUDE.md. The developer gets a setup
# problem and the command that fixes it, and nothing about which tool family is which —
# that distinction is the agent's concern, not theirs. Without jq only the agent's line
# goes out, as plain stdout, which is the audience stdout reaches.
hint() {
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg ctx "$1" --arg msg "$2" \
            '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}, systemMessage: $msg}'
    else
        printf '%s\n' "$1"
    fi
}

on_mac=no
[[ "$(uname -s 2>/dev/null)" == Darwin ]] && on_mac=yes

# Without CLAUDE_ENV_FILE — a Claude Code too old to supply it, or an event that does not
# carry one — there is nothing to write the PATH into, and on a Mac every tool stays the
# macOS build. Said once, so the agent does not go on assuming GNU tools.
if [[ -z "${CLAUDE_ENV_FILE:-}" ]]; then
    if [[ "$on_mac" == yes ]]; then
        hint "$(agent_line "${formulas[@]}")" \
            'Claude Code is too old for these hooks. Fix: claude update'
    fi
    exit 0
fi

# The environment's own answer first, which is what makes this work on an Intel Mac and
# under a non-standard prefix without asking anyone to configure it.
if [[ -n "${HOMEBREW_PREFIX:-}" ]]; then
    candidates=("$HOMEBREW_PREFIX")
else
    candidates=(/opt/homebrew /usr/local)
fi

prefix=''
for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate/opt" ]]; then
        prefix="$candidate"
        break
    fi
done

if [[ -z "$prefix" ]]; then
    # No Homebrew on a Mac means every one of the tools is the macOS build. Off a Mac
    # there is nothing to say.
    if [[ "$on_mac" == yes ]]; then
        hint "$(agent_line "${formulas[@]}")" \
            'Homebrew is missing. Fix: install it from https://brew.sh'
    fi
    exit 0
fi

# already_wins <dir> — true when <dir> sits ahead of /usr/bin and /bin on PATH, so its
# `sed` is the one a lookup finds already. Only that is a reason to skip: the terminal claude was
# launched from may have arranged it, or this is a nested session whose parent did. A
# directory that is on PATH but BEHIND /usr/bin has lost, and is prepended like one that
# is absent — the duplicate entry it leaves is harmless, the BSD sed it would leave is not.
already_wins() {
    local dir="$1" entry rest="${PATH:-}"
    while [[ -n "$rest" ]]; do
        entry="${rest%%:*}"
        [[ "$rest" == *:* ]] && rest="${rest#*:}" || rest=''
        [[ "$entry" == "$dir" ]] && return 0
        # Both are system-tools directories on a Mac: sed and grep live in /usr/bin, date,
        # ls and cp in /bin. Reaching either first means the GNU directory has lost.
        [[ "$entry" == /usr/bin || "$entry" == /bin ]] && return 1
    done
    return 1
}

prepend=''
missing=()
for formula in "${formulas[@]}"; do
    gnubin="$prefix/opt/$formula/libexec/gnubin"
    if [[ ! -d "$gnubin" ]]; then
        missing+=("$formula")
        continue
    fi
    already_wins "$gnubin" && continue
    prepend="${prepend:+$prepend:}$gnubin"
done

if [[ -n "$prepend" ]]; then
    printf "export PATH=\"%s:\${PATH}\"\n" "$prepend" >> "$CLAUDE_ENV_FILE"
fi

if [[ "$on_mac" == yes && "${#missing[@]}" -gt 0 ]]; then
    hint "$(agent_line "${missing[@]}")" "GNU tools missing. Fix: brew install ${missing[*]}"
fi

exit 0
