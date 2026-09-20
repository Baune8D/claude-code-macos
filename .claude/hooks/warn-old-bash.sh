#!/usr/bin/env bash

# SessionStart: says so when the bash the Bash tool runs is older than 5.
#
# .claude/settings.json sets CLAUDE_CODE_SHELL to a bare `bash`, so the Bash tool runs
# whichever bash is first on PATH — Homebrew's on a Mac that has run `brew install bash`,
# the distribution's on Linux, and both are 5. A Mac where Homebrew is not ahead of /bin
# gets Apple's 3.2 instead, and nothing says
# so: the shell starts, and `mapfile`, `${x^^}` and associative arrays fail one at a time,
# halfway through whatever was being done.
#
# What it asks for a version is `CLAUDE_CODE_SHELL` itself, falling back to a bare `bash`,
# because that variable is the whole of Claude Code's choice: a bare name is resolved
# through PATH, the same lookup this makes, and an absolute path is not resolved at all.
# Asking PATH unconditionally would have a blind spot exactly where a developer is most
# likely to get it wrong — `"CLAUDE_CODE_SHELL": "/bin/bash"`, on the reasonable-sounding
# assumption that the setting wants a full path, pins the Bash tool to Apple's 3.2 while
# PATH's first bash is Homebrew's 5, and this hook would have reported the 5.
#
# The value is used as a command, not as a path: `/bin/bash` and a bare `bash` both run,
# and neither is inspected as a file first, so a shell that a `command -v` would miss is
# still asked. warn-shell-not-bash.sh is the hook that decides whether the value is bash at
# all; by the time this one speaks, the question is only which bash.
#
# One short line to each audience — `additionalContext` for the agent, `systemMessage` for
# the developer — the way put-gnu-tools-on-path.sh does it: the agent gets the fact, the
# developer, who is the one who can fix PATH, gets the path and the fix. Silent when the
# bash is 5 or newer. Always exits 0.
#
# A PATH with no bash at all is not this hook's case: settings.json launches it as
# `bash <path>`, so that failure happens before it runs — and it does not happen on a Mac,
# which always has Apple's /bin/bash. An override naming a shell that does not exist is a
# different matter, and reads here as a version that cannot be parsed.

set -u

# hint <for the agent> <for the developer> — one short line each, the shape
# put-gnu-tools-on-path.sh uses: the agent gets the fact, the developer gets a setup
# problem and the command that fixes it.
# Without jq only the agent's line goes out, as plain stdout, which is the audience stdout
# reaches.
hint() {
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg ctx "$1" --arg msg "$2" \
            '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}, systemMessage: $msg}'
    else
        printf '%s\n' "$1"
    fi
}

# The shell Claude Code was told to run, or the bare name it defaults to.
shell="${CLAUDE_CODE_SHELL:-bash}"

# Where that lands, for the developer's line. `command -v` answers for a bare name and an
# absolute path alike; when it answers nothing — an override naming a shell that is not
# there — the value itself is the most useful thing to print back.
where=$(command -v "$shell" 2>/dev/null)
where=${where:-$shell}

# First line only, without spawning `head`: several cases run this under a PATH that
# holds nothing but a bash. "GNU bash, version 5.3.15(1)-release ..." — the number
# after "version ".
version=$("$shell" --version 2>/dev/null)
version=${version%%$'\n'*}
version=${version#*version }
version=${version%% *}
major=${version%%.*}

case "$major" in
    ''|*[!0-9]*)
        hint "This session's Bash tool runs a bash whose version is unreadable, not 5." \
            "bash at $where reports no version. Fix: brew install bash"
        ;;
    *)
        if [[ "$major" -lt 5 ]]; then
            hint "This session's Bash tool runs bash $version, not 5." \
                "bash $major at $where, need 5. Fix: brew install bash"
        fi
        ;;
esac

exit 0
