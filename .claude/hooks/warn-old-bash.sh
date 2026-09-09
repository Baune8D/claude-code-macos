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
# `bash --version` through PATH is the same lookup Claude Code makes for the override, so
# what this reports is what the Bash tool got. One short line to each audience —
# `additionalContext` for the agent, `systemMessage` for the developer — the way
# put-gnu-tools-on-path.sh does it: the agent gets the fact, the developer, who is the one
# who can fix PATH, gets the path and the fix. Silent when the bash is 5 or newer. Always
# exits 0.
#
# A PATH with no bash at all is not this hook's case: settings.json launches it as
# `bash <path>`, so that failure happens before it runs — and it does not happen on a Mac,
# which always has Apple's /bin/bash.

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

# First line only, without spawning `head`: several cases run this under a PATH that
# holds nothing but a bash. "GNU bash, version 5.3.15(1)-release ..." — the number
# after "version ".
version=$(bash --version 2>/dev/null)
version=${version%%$'\n'*}
version=${version#*version }
version=${version%% *}
major=${version%%.*}

case "$major" in
    ''|*[!0-9]*)
        hint "This session's Bash tool runs a bash whose version is unreadable, not 5." \
            "bash at $(command -v bash) reports no version. Fix: brew install bash"
        ;;
    *)
        if [[ "$major" -lt 5 ]]; then
            hint "This session's Bash tool runs bash $version, not 5." \
                "bash $major at $(command -v bash), need 5. Fix: brew install bash"
        fi
        ;;
esac

exit 0
