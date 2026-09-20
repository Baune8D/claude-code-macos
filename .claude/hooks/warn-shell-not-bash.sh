#!/usr/bin/env bash

# SessionStart: says so when the Bash tool is not running bash at all.
#
# The other two hooks assume the Bash tool is bash and ask which bash it is. This one asks
# the question underneath that, because the answer is not a hook's to arrange: the shell
# comes from `CLAUDE_CODE_SHELL` in the `env` block of a settings.json, read before the
# shell is chosen, and no hook can write it. A session without that block gets the login
# shell, which is zsh on every Mac since Catalina.
#
# It exists for the plugin. Installed as a plugin, this repository delivers the PATH half
# of the fix and cannot deliver the shell half — a plugin manifest has no `env` block, so
# `CLAUDE_CODE_SHELL` stays a line the developer adds to their own settings.json by hand.
# Without this hook that omission is silent: GNU tools arrive on PATH, the session is still
# zsh, and the first `mapfile` or `${x^^}` fails halfway through something else. Copied in
# as files instead, the settings.json alongside sets the variable and this hook never
# speaks.
#
# What it reads is the environment it is spawned into, not any settings file. Measured on
# 2.1.278: a SessionStart hook's own environment carried `CLAUDE_CODE_SHELL=bash` and
# `SHELL=bash` from the `env` block of the project's settings.json, so the hook sees the
# effective value however the block was merged across user, project and local scope.
#
# `SHELL` is the fallback because Claude Code falls back to the login shell, and a Mac
# whose login shell is already bash needs no block and no hint. Only the name is compared:
# `bash`, `/bin/bash` and `/opt/homebrew/bin/bash` are all bash, and which bash it is is
# warn-old-bash.sh's question.
#
# One short line to each audience through the SessionStart JSON, the shape the other two
# hooks use — `additionalContext` for the agent, `systemMessage` for the developer. Silent
# when the shell is bash. Inert off a Mac, where the login shell is bash already and a
# missing block costs nothing. Always exits 0.

set -u

# hint <for the agent> <for the developer> — one short line each. The agent gets the fact,
# because it is the one about to write `mapfile`; the developer gets the setting to add.
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

[[ "$(uname -s 2>/dev/null)" == Darwin ]] || exit 0

# The override first, the login shell behind it, which is the order Claude Code itself
# resolves them in.
shell="${CLAUDE_CODE_SHELL:-${SHELL:-}}"
name="${shell##*/}"

[[ "$name" == bash ]] && exit 0

# Both variables, not just the override: `SHELL` is what the model's environment summary
# reads, and a session with only `CLAUDE_CODE_SHELL` set runs bash while telling the model
# it is zsh — the inconsistency this repository exists to remove.
fix='Fix: add "CLAUDE_CODE_SHELL": "bash" and "SHELL": "bash" to the env block of ~/.claude/settings.json'

if [[ -z "$name" ]]; then
    hint "This session's Bash tool is not bash." \
        "The Bash tool shell is unset. $fix"
else
    hint "This session's Bash tool is $name, not bash." \
        "The Bash tool runs $name. $fix"
fi

exit 0
