# claude-code-macos

Claude Code plugin that makes the Bash tool behave like Linux on a Mac: bash 5 instead of zsh, and Homebrew's GNU builds (`sed`, `date`, `stat`, `awk`, `tar`, `which`, `xargs`, ...) ahead of the BSD ones. It is also the source of the `claude-code-macos` plugin that the other Baune8D repositories enable in their `.claude/settings.json`.

- `.claude/hooks/`: the three SessionStart hooks (`put-gnu-tools-on-path.sh`, `warn-shell-not-bash.sh`, `warn-old-bash.sh`), each with a `.test.sh` suite.
- `.claude/settings.json` wires the hooks up for the copy-in route (and for this repository); `.claude-plugin/hooks.json` wires them up for the plugin. They list the same hooks, so change both together.
- A plugin can't set `env`, so plugin users add the `CLAUDE_CODE_SHELL`/`SHELL` block to their own settings by hand. The README explains both routes.
- Off a Mac, every hook exits before doing anything.

## Workflow

- Conventional commits (`feat:`, `fix:`, `chore(deps):`, `ci:`, `build:`, `docs:`), one commit per concern, directly on `main`.
- Only push, tag, publish or edit GitHub releases when asked.
- Commit messages must be accurate. If one turns out to be wrong before it is pushed, reword it (replay the commits and check that the tree is unchanged). Never rewrite pushed history.

## Releasing

- Bump `version` in `.claude-plugin/plugin.json` and in the plugin entry of `.claude-plugin/marketplace.json` together, push a lightweight tag `vX.Y.Z` on `main`, and create a GitHub release.

### GitHub release notes

Use these sections, omitting empty ones, and end with a compare link:

```markdown
## Breaking changes

## Features

## Fixes

## Known issues

## Other

**Full Changelog**: https://github.com/Baune8D/claude-code-macos/compare/vA...vB
```

- Write for users of the plugin: name the hooks, settings and before/after behavior. Leave out internal changes (tests, CI, IDE files).
- When a release fixes a bug from an earlier release, add a "Known issues" entry to the earlier release saying "Fixed in vX.Y.Z".

## Dependencies

- Dependabot updates the GitHub Actions weekly on Monday with a 7-day cooldown, in one grouped pull request.

## Testing

- `bash .claude/hooks/<hook>.test.sh` runs a hook's suite. The suites run against a throwaway Homebrew prefix under `mktemp` and a fake `uname`, so they never read the machine's formulas or write to a real `CLAUDE_ENV_FILE`.
- The hooks and suites need bash 5; macOS ships 3.2 (`brew install bash`).
- CI runs the three suites on Ubuntu and macOS, and `shellcheck .claude/hooks/*.sh`. Run shellcheck locally before committing.
