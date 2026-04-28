# homebrew-openlap

Homebrew tap for [openlap.app](https://openlap.app) — internal Mac team installer.

Bundles `pulsed` (local DM/fleet/RPC runtime) + `wrspawn` (x-man coordinator) + skill files + agent definitions + npm-installed proxy into a single `brew install` command. Source stays private; release artifacts live in this tap repo.

## Install

```sh
brew tap wildreason/openlap
brew install openlap
```

## First-run setup (3 commands, run once in this order)

```sh
openlap setup                              # adds openlap MCP server to Claude Code
openlap login                              # signs you in via Abe OAuth (browser opens)
openlap workspace --agent-handle=x-man     # provisions x-man under your deployer
```

Then start the local runtime under launchd:

```sh
brew services start openlap                # autostart on login + restart on crash
```

Verify everything is wired:

```sh
openlap doctor
```

`doctor` runs ~14 checks across Node/npm/claude/tmux/git, the `:7788` port state, your auth token freshness, the `x-man` agent provisioning, `~/.claude/{skills,agents}/` symlinks, and the `brew services` unit. Each non-PASS check prints a one-line fix hint.

## What's bundled

| Artifact | Path | Notes |
|---|---|---|
| `pulsed` | `bin/` | Local DM/fleet/RPC/socket runtime |
| `wrspawn` | `bin/` | x-man's primary CLI |
| `nudge-agent`, `ask-agent`, `clone` | `share/openlap/skills/x-man/scripts/` + `~/.local/bin/` symlinks | Bash helpers, ride along with the skill |
| `x-man` skill | `share/openlap/skills/x-man/` → `~/.claude/skills/x-man` | Behavioral doc + scripts |
| `execution-method` skill | `share/openlap/skills/execution-method/` → `~/.claude/skills/execution-method` | Patterns |
| `x-man` agent def | `share/openlap/agents/x-man.md` → `~/.claude/agents/x-man.md` | Claude Code agent |
| `@openlap/openlap` proxy | post-install: `npm install -g @openlap/openlap` | Stdio MCP bridge |
| launchd plist | `brew services start openlap` | Runs `pulsed` |

## Brew dependencies

The formula brings (declared `depends_on`):

- `node` (>=18) — runs the npm proxy
- `tmux` — fleet spawn handler + x-man pane management

You install separately (flagged by `openlap doctor`):

- Claude CLI 2.x: `npm install -g @anthropic-ai/claude-code`

## Migrating from `go install ./cmd/pulsed`

If you previously ran the legacy Go pulsed daemon, stop it before starting the brew-managed service:

```sh
pkill pulsed
brew services restart openlap
```

`brew install` and `openlap doctor` both detect the legacy daemon on `:7788` and print this hint automatically.

## Auto-update

The npm proxy (`@openlap/openlap`) self-updates from npm on every `openlap` invocation per its v1.10.0+ behavior — preserved across the brew install path. To opt out:

```sh
export OPENLAP_SKIP_AUTOUPDATE=1
```

For the bundled binaries (`pulsed`, `wrspawn`) and skill/agent files, run `brew upgrade openlap` to pull a new release.

## Service lifecycle

```sh
brew services start openlap     # boot pulsed under launchd, autostart on login
brew services stop openlap      # stop + release :7788
brew services restart openlap   # graceful restart (e.g. after upgrade)
brew services list              # status
```

## Tracking

[OLP-203](https://openlap.app/barath/openlap-package) — Plan B brew tap installer.

Internal-team scope. External distribution requires Apple Developer code-signing (parked, not on roadmap today).

## Maintainer Notes

### `HOMEBREW_TAP_PAT` rotation

The release pipeline (`wildreason/openlap` → `.github/workflows/release.yml`) uses a fine-grained PAT named `HOMEBREW_TAP_PAT` to upload release artifacts to this tap. **PATs expire after 90 days** (currently expires Thu, May 28 2026 — bump this date when rotated).

If the PAT lapses, the release workflow will fail at the upload step with `HTTP 401`. Every release post-expiry 401s with no other warning.

**At day-75 (~Sat, May 13 2026):**

1. Generate a new fine-grained PAT at https://github.com/settings/personal-access-tokens/new
   - Resource owner: `wildreason` (NOT your personal account — check the dropdown)
   - Repository access: only `wildreason/homebrew-openlap`
   - Permissions: Contents → Read and write
   - Expiration: 90 days
2. Update the secret: `gh secret set HOMEBREW_TAP_PAT --repo wildreason/openlap --body "github_pat_NEW_TOKEN"`
3. Bump the expiry date in this section so the next maintainer knows when to rotate.
4. Optionally re-run a recent failed release to confirm it now succeeds: `gh run rerun <id> --repo wildreason/openlap`

A calendar reminder for the day-75 mark in your team calendar is the simplest forcing function. A doctor-side health probe (pinging the GitHub API with the secret to verify it still authenticates) is the proper engineering answer; tracked under a follow-up lap.
