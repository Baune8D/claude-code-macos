# claude-code-macos

Makes Claude Code's Bash tool behave like Linux on a Mac: bash 5 instead of zsh, and GNU
`sed`, `date`, `stat`, `awk`, `tar`, `which`, `xargs` and friends instead of the BSD
builds.

Two files do it, both under `.claude/`:

- `settings.json` — an `env` block that switches the Bash tool to bash, and three
  `SessionStart` hooks.
- `hooks/put-gnu-tools-on-path.sh` — puts Homebrew's GNU builds first on the PATH the
  Bash tool resolves. `hooks/warn-shell-not-bash.sh` says so if the Bash tool is not
  running bash at all, and `hooks/warn-old-bash.sh` says so if the bash that won is
  still Apple's 3.2.

Install it as a plugin, or copy the files in. [Both are below](#install).

Nothing outside a Claude Code session changes. Your own terminal keeps zsh and the
macOS tools. That split is also the cost: [the trade-off](#the-trade-off).

## The problem

Two things are true of a Claude Code session on a stock Mac, and neither is visible
until a command fails halfway through a task:

1. **The Bash tool is zsh.** Claude Code picks the login shell, which is zsh on every
   Mac since Catalina. Anything the model has learned about bash — `mapfile`,
   `${x^^}`, word splitting, glob behaviour — is subtly off.
2. **The userland is BSD.** `sed -i -e 's/a/b/' file` edits the file, exits 0 and leaves
   a backup called `file-e` beside it, because BSD `sed -i` takes the next argument as
   the backup suffix. `date -d yesterday` is an error. `sed -E 's/\s+/_/'` does not
   match. `stat -c %s` is an error. The model writes the GNU form, because that is what
   almost all shell on the internet is, and then patches around the failure.

And the obvious fix does not do what you want. Your profile does reach the Bash tool,
but only through the terminal that launched `claude`, which inherited its PATH. So an
export there changes `sed` for everything in that terminal, not just for Claude Code.
Guarding it with `CLAUDECODE` doesn't help: that variable isn't set in your terminal,
and although Claude Code runs your profile again with `CLAUDECODE=1` when it captures
its shell snapshot, it writes the snapshot's `export PATH` from its own inherited
environment and drops anything that run added. The snapshot is replayed before every
Bash call. Measured on 2.1.282, in both bash and zsh: the capture shell sourced the rc
file with `CLAUDECODE=1` set, and neither a guarded nor an unguarded PATH prepend in it
reached the Bash tool.

## The fix

`CLAUDE_CODE_SHELL` is read from the `env` block in `settings.json` before the shell is
chosen, so a bare `bash` there puts the Bash tool on the first bash on PATH — Homebrew's.
`SHELL` is set alongside it because the model's environment summary reads that variable,
and it would otherwise still say zsh.

```json
"env": {
  "CLAUDE_CODE_SHELL": "bash",
  "SHELL": "bash"
}
```

`CLAUDE_ENV_FILE` is the other half. A `SessionStart` hook may append shell statements
to the file that variable names, and Claude Code sources that file **after** the
snapshot, before every Bash call. So a PATH prepend written there wins over the
snapshot's. The hook writes one line:

```sh
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:...:${PATH}"
```

Only the gnubin directories of formulas that are actually installed go on PATH, in a
fixed order, and only when a lookup does not already reach them first: one that sits
behind `/usr/bin`, behind another directory with its own `sed`, or behind an empty or
relative PATH entry is prepended.

That path is the Apple Silicon one. On an Intel Mac, or with an x86_64 Homebrew under
Rosetta, the prefix is `/usr/local`, and a PATH entry pointing at a directory that is not
there fails quietly: `sed` stays BSD and nothing says so. The hook detects the prefix
instead of hardcoding it, from `HOMEBREW_PREFIX` when set and otherwise by probing
`/opt/homebrew` and then `/usr/local`. It probes the filesystem rather than asking `brew`
because a hook launched from the desktop app or an IDE does not necessarily have `brew`
on PATH either.

On a Mac the hook also tells the agent, once, at session start: "This session's date,
stat, xargs, awk, sed, tar and which are the GNU builds, not macOS." Putting the tools on
PATH is not enough on its own. Claude Code's environment block says `Platform: darwin`,
and since 2.1.260 its auto-mode and bypass-permissions prompts warn about "sed/awk flags
that differ between GNU and BSD/macOS". With only that in context, the model reads darwin
as BSD and writes `sed -i '' …`, which GNU sed rejects. `find` and `grep` are left out of
the line, because Claude Code answers those two names itself ([below](#what-it-leaves-alone-grep-and-find)).

When it cannot deliver — a formula missing, no Homebrew, or a Claude Code too old to
supply `CLAUDE_ENV_FILE` — the agent's line also names what stayed macOS ("This session's
awk is the macOS build, not GNU."), and you get the fix ("GNU tools missing. Fix: brew
install gawk"). Off a Mac it says nothing.

## Install

Either way, first:

```sh
brew install bash coreutils findutils gawk gnu-sed gnu-tar gnu-which grep
```

Homebrew's g-prefixed names (`gsed`, `gdate`) are untouched and your terminal still
resolves `sed` to `/usr/bin/sed`. Nothing here reaches past the Bash tool.

### As a plugin

Once, for every repository you open:

```
/plugin marketplace add Baune8D/claude-code-macos
/plugin install claude-code-macos@claude-code-macos
```

Then add the `env` block to `~/.claude/settings.json` by hand:

```json
"env": {
  "CLAUDE_CODE_SHELL": "bash",
  "SHELL": "bash"
}
```

**A plugin cannot do that part.** A plugin manifest carries hooks, commands, agents and
MCP servers; it has no `env` block, and `CLAUDE_CODE_SHELL` is read before the shell is
chosen, so no hook can write it either. The plugin delivers the PATH half of the fix;
the shell stays zsh until that block exists.

Which is what `warn-shell-not-bash.sh` is for. It reads `CLAUDE_CODE_SHELL` — measured
on 2.1.278, an `env` block reaches a SessionStart hook's own environment — falls back to
`SHELL` for a Mac whose login shell is already bash, and says one line to each audience
when neither is bash. With the block in place it never speaks.

### As files in a repository

Copy `.claude/settings.json` and `.claude/hooks/` into your repo, or merge the `env` and
`hooks.SessionStart` blocks into a `settings.json` you already have. The hook commands
use `$CLAUDE_PROJECT_DIR`, which Claude Code sets for every hook, so they work from any
checkout location. This is the whole fix in one step, and it travels with the repository
to everyone who clones it.

Both at once is harmless, not clever: each copy of the hook reads its own PATH, which is
Claude Code's and carries neither prepend, so both write one. The Bash tool ends up with
the gnubin directories twice on PATH, resolving to the same builds.

## Verify

Ask Claude to run this in the Bash tool:

```sh
echo "$BASH_VERSION"; sed --version | head -1; date -d yesterday +%F
```

Measured on Claude Code 2.1.266, macOS 26.6, in a session started with a launchd-like
environment (no inherited PATH), from a directory with and without these files:

| | Without | With |
| :-- | :-- | :-- |
| Shell | zsh 5.9 | bash 5.3.15 |
| `sed --version` | `sed: illegal option -- -` | GNU sed 4.10 |
| `date --version` | `date: illegal option -- -` | GNU coreutils 9.11 |
| `awk --version` | error | GNU Awk 5.4.1 |
| `date -d yesterday +%F` | error | `2026-09-08` |

## What it leaves alone: `grep` and `find`

Claude Code ships its own `grep` and `find`. The session snapshot defines both as shell
functions that re-exec the `claude` binary as [ugrep](https://github.com/Genivia/ugrep)
and [bfs](https://github.com/tavianator/bfs), and a function beats a PATH lookup, so
those two names stay Claude Code's even with the GNU builds first on PATH. This hook
does not remove them, on purpose.

An earlier version did, and it was taken out after measuring. Across two dozen common
idioms — `-rn`, `--include`, `-oP` lookahead, `\b`, `\|` in basic regex, `-A`, `-F`,
`-c`, `-printf`, `-regex`, `-mmin`, `-exec {} +` — the two engines never disagreed on
syntax, so the model's GNU habits work as they are. Every difference came from ugrep's
default flags: a bare `grep -r` honours `.gitignore`, skips binaries silently and prints
paths without a `./` prefix. For an agent searching a repository, not walking
`node_modules` is the better default. The GNU `grep` and `findutils` formulas are still
worth installing: scripts, an explicit `command grep`, and the wrapper's own fall-through
for `-z` and `--null` all resolve through PATH and get the GNU builds instead of the
macOS ones.

## What it does not reach

`CLAUDE_ENV_FILE` applies to the Bash tool only. Hooks and stdio MCP servers are spawned
from Claude Code's own environment and see none of this. Measured on 2.1.263: a variable
written to the env file was set in the Bash tool and unset in a `PostToolUse` hook.

On Linux the hook is inert: without a Homebrew prefix it writes nothing and says
nothing, and the plain names already resolve to GNU there.

## The trade-off

Leaving your terminal alone is also what this costs. A Mac set up this way has two
userlands: bash and GNU in the Bash tool, zsh and macOS in your terminal. Two things
follow from that, and neither has a clean fix.

**A script written for macOS fails when the agent runs it.** A script the Bash tool
starts inherits its PATH, whatever the shebang says: a `#!/usr/bin/env bash` and a
`#!/bin/zsh` script both resolved `sed` to the gnubin. So `sed -i '' 's/a/b/' file`,
which works in your terminal, fails for the agent, and a script written with GNU flags
fails in your terminal. GNU sed 4.10 at least fails loudly: `sed: can't read s/a/b/: No
such file or directory`, exit 2, and the file is left unchanged.

What exists are workarounds:

- Write forms both builds accept: `sed -i.bak 's/a/b/' file && rm file.bak`, or
  redirect to a temporary file and `mv` it. That puts the cost on whoever writes the
  script.
- Pin a script that is macOS-only by design to `/usr/bin/sed`, or set PATH at its top.
  That helps only where someone thought to pin.
- Put the gnubin directories first in your terminal as well. That is the only one that
  removes the split, and it changes your terminal, which is what this setup is built
  not to do.

The trade is made on purpose: an agent writes far more one-off commands than it runs
scripts from the repository, and the one-off commands are where its GNU habits show.

**`~/.zshenv` stops reaching the Bash tool.** zsh reads `.zshenv` for every shell,
including the non-interactive `zsh -c` behind each Bash call, so with zsh as the Bash
tool its exports are set again on every call. That holds even after a launch that
strips the environment, as Claude Desktop's does. bash reads no startup file for
`bash -c`. From a terminal you will not notice, because the Bash tool inherits the
terminal's environment and the exports are already in it. From the desktop app, or
anything else launchd starts, they are gone.

Measured on 2.1.296 with `claude -p` under `env -i` and launchd's four-directory PATH
(a launchd-like environment, not Claude Desktop itself), with a throwaway `ZDOTDIR`
whose `.zshenv` logged each time it was sourced:

| Bash tool | `.zshenv` sourced per call | Its variable | Its PATH prepend |
| :-- | :-- | :-- | :-- |
| zsh | yes | set | lost: the snapshot's `export PATH` runs after it |
| bash | no | unset | — |

`BASH_ENV`, bash's own startup file for non-interactive shells, did not bring it back.
Set in the same environment, its file was sourced by other bash processes in the
session, but the variable it exported was never set in the Bash tool. Why is not
established.

## Tests

```sh
bash .claude/hooks/put-gnu-tools-on-path.test.sh
bash .claude/hooks/warn-shell-not-bash.test.sh
bash .claude/hooks/warn-old-bash.test.sh
```

Every case runs against a throwaway Homebrew prefix under `mktemp` and a fake `uname`,
so the suites never read the formulas on the machine they run on or write to a real
`CLAUDE_ENV_FILE`.
