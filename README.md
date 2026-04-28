# homebrew-openlap

Homebrew tap for [openlap.app](https://openlap.app) — internal Mac team installer.

## Install

```sh
brew tap wildreason/openlap
brew install openlap
openlap setup
brew services start openlap
```

## What it bundles

- `pulsed` — local DM/fleet/RPC/socket runtime
- `wrspawn` + `nudge-agent` + `ask-agent` + `clone` — x-man coordinator tooling
- Skill files (`x-man`, `execution-method`) symlinked into `~/.claude/skills/`
- Agent definitions (`x-man`, `adversary`, `admin`) symlinked into `~/.claude/agents/` and `~/wildreason/.claude/agents/`
- npm-installed `@openlap/openlap` proxy (post_install hook)
- Single launchd plist via `brew services` running proxy + pulsed

## Brew dependencies

The formula brings:

- `node` (>=18) — runs the npm proxy
- `tmux` — fleet spawn + x-man pane management

You install separately (flagged by `openlap doctor`):

- Claude CLI 2.x: `npm install -g @anthropic-ai/claude-code`

## Migrating from `go install ./cmd/pulsed`

```sh
pkill pulsed
brew services restart openlap
```

## Status

Tracking lap: [OLP-203](https://openlap.app/barath/openlap-package) — Plan B brew tap installer.

This tap is internal-team-only today. External distribution requires Apple Developer code-signing (parked).
