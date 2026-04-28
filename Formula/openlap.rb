# Homebrew formula for @openlap/openlap — internal Mac team installer.
#
# Bundles the local runtime that openlap.app needs on every team member's box:
#   - pulsed (Go static binary, the local DM/fleet/RPC/socket runtime)
#   - wrspawn + nudge-agent + ask-agent + clone (x-man coordinator tooling)
#   - skill files + agent definitions (symlinked into ~/.claude on post_install)
#   - npm-installed proxy (@openlap/openlap, runs the stdio MCP bridge)
#
# Lifecycle: `brew services start openlap` boots a single launchd unit running
# both `openlap start` (proxy) and `pulsed` via a wrapper script.
#
# Out of scope here (parked in OLP-203):
#   - .pkg double-click installer (Plan D)
#   - Apple Developer code-signing (defer until external distribution)
#   - Linux primary (Linuxbrew should work on the same release artifacts;
#     smoke test deferred)
#
# See: https://github.com/wildreason/openlap/blob/main/CLAUDE.md
class Openlap < Formula
  desc "Local runtime for openlap.app — agent coordination MCP proxy + pulsed"
  homepage "https://openlap.app"
  version "0.1.2"
  license "MIT"

  # url + sha256 point at the GitHub Release artifacts produced by the
  # release.yml workflow in wildreason/openlap on `v*` tag push. Bump
  # both fields in lockstep with each new release tag (criterion #11
  # tightens this with an automated PR-bump).
  depends_on "node"
  depends_on "tmux"

  on_macos do
    on_arm do
      url "https://github.com/wildreason/homebrew-openlap/releases/download/v0.1.2/openlap-0.1.2-darwin-arm64.tar.gz"
      sha256 "21ab878c75400f5280d7459cde76994a60737028863171fa6452ef1e7bf1b126"
    end
    on_intel do
      url "https://github.com/wildreason/homebrew-openlap/releases/download/v0.1.2/openlap-0.1.2-darwin-amd64.tar.gz"
      sha256 "f7b55aa32f2e20efeed8f8daf1922a3dcde27871b7c481ce5ffa66502facc9d4"
    end
  end

  # Why each runtime dep:
  #   node    runs the npm-installed @openlap/openlap proxy
  #   tmux    fleet spawn handler + x-man pane management

  # Intentionally not declared above (doctor-flagged in criterion #9):
  #   - claude CLI 2.x — Anthropic, no brew formula exists; `openlap doctor`
  #     prints a one-line install hint. Listing it here would silently fail
  #     the brew install with a confusing error.

  def install
    # Compiled binaries — pulsed (this repo) + wrspawn (wildreason/spawn).
    # Bash helpers (nudge-agent, ask-agent, clone) live inside
    # share/openlap/skills/x-man/scripts/ as of spawn v0.1.1's reorg —
    # post_install creates ~/.local/bin/ symlinks for back-compat.
    bin.install "bin/pulsed"
    bin.install "bin/wrspawn"

    # Wrapper script that launchd runs (boots the long-running daemon).
    # Today only `pulsed` is a daemon — the MCP proxy is stdio-only and
    # gets invoked by Claude Code per-session, not by launchd. After
    # OLP-197 ships (pulsed → TS, single Node process for proxy+pulsed),
    # this wrapper bumps to `openlap start` instead. Until then: pulsed
    # alone, started under brew services for autostart-on-login.
    (bin/"openlap-wrapper").write <<~SH
      #!/bin/bash
      # openlap-wrapper: launchd entrypoint for the local runtime.
      # Currently boots only pulsed; npm proxy is stdio (per-session, not
      # daemonized). Bumps to combined `openlap start` after OLP-197.
      set -e
      mkdir -p "$HOME/.openlap/logs"
      exec "#{opt_bin}/pulsed"
    SH
    (bin/"openlap-wrapper").chmod 0755

    # Skill files + agent definitions, kept under share/openlap/ so brew
    # owns them. post_install symlinks into ~/.claude/.
    (share/"openlap/skills").install Dir["share/openlap/skills/*"]
    (share/"openlap/agents").install Dir["share/openlap/agents/*"]
  end

  def post_install
    # Order matters: do the always-safe filesystem steps first (symlinks),
    # then the failure-prone npm install last. If npm install dies (most
    # commonly EPERM from stale ~/.npm permissions), the rest of the install
    # is still complete and the user can fix npm + retry the proxy step.

    # Criterion #5: symlink skills + agents into ~/.claude. Idempotent —
    # safe_link replaces existing symlinks transparently and backs up real
    # files/dirs aside (never clobbers user content).
    home = Dir.home
    skills_target = "#{home}/.claude/skills"
    agents_target = "#{home}/.claude/agents"
    org_agents_target = "#{home}/wildreason/.claude/agents"
    legacy_bin = "#{home}/.local/bin"

    [skills_target, agents_target, org_agents_target, legacy_bin].each do |dir|
      mkdir_p(dir)
    end

    # Whole-tree symlinks: scripts/ rides along inside skills/x-man so the
    # skill, its docs, and its helper scripts stay co-located.
    Dir["#{share}/openlap/skills/*"].each do |src|
      name = File.basename(src)
      safe_link(src, "#{skills_target}/#{name}")
    end

    %w[x-man].each do |agent|
      src = "#{share}/openlap/agents/#{agent}.md"
      next unless File.exist?(src)

      safe_link(src, "#{agents_target}/#{agent}.md")
    end

    %w[adversary admin].each do |agent|
      src = "#{share}/openlap/agents/#{agent}.md"
      next unless File.exist?(src)

      safe_link(src, "#{org_agents_target}/#{agent}.md")
    end

    # Back-compat: ~/.local/bin/ symlinks pointing into the skill's scripts/.
    # Anything that calls `nudge-agent` / `ask-agent` / `clone` directly
    # (via PATH) keeps working post-spawn-v0.1.1 reorg. ~/.local/bin/ is
    # already on PATH for x-man's setup; harmless on machines that don't
    # have it on PATH.
    %w[nudge-agent ask-agent clone].each do |script|
      src = "#{share}/openlap/skills/x-man/scripts/#{script}"
      next unless File.exist?(src)

      safe_link(src, "#{legacy_bin}/#{script}")
    end

    # Criterion #4: install/upgrade the npm proxy LAST. Failure-tolerant —
    # the most common cause of a post_install failure is stale ~/.npm
    # permissions (root-owned files from an older sudo npm). When that
    # happens we still want symlinks + service plist already in place;
    # the user can fix npm + retry the one command, no full reinstall.
    npm = "#{Formula["node"].opt_bin}/npm"
    unless quiet_system(npm, "install", "-g", "@openlap/openlap")
      opoo "npm install -g @openlap/openlap failed."
      opoo "Most common cause: ~/.npm has root-owned cache files."
      opoo "Fix and retry:"
      opoo "  sudo chown -R $(id -u):$(id -g) ~/.npm"
      opoo "  npm install -g @openlap/openlap"
      opoo "Skills, agents, service plist are already installed."
    end

    # Criterion #8: legacy-pulsed probe. Warn (do not fail) if :7788 is
    # bound by a foreign process — typically the old `go install ./cmd/pulsed`.
    if system("lsof -iTCP:7788 -sTCP:LISTEN -n -P >/dev/null 2>&1")
      ohai "Heads-up: port 7788 is already bound."
      opoo "A legacy pulsed binary appears to be running."
      opoo "Stop it before starting the brew-managed service:"
      opoo "  pkill pulsed"
      opoo "  brew services restart openlap"
    end
  end

  # Symlink that never clobbers user content. Cases:
  #   - dst missing                 → create symlink
  #   - dst is a symlink (any kind) → replace it (ln_sf semantics)
  #   - dst is a real file/dir      → move aside to dst.pre-brew-<epoch>
  #                                   then create symlink
  # The backup-aside path catches users who hand-rolled skills/agents
  # before installing the brew tap (e.g. cloned spawn manually first).
  # Loud + reversible — better than silent overwrite or silent skip.
  def safe_link(src, dst)
    # Three cases the helper has to clear before `ln -s`:
    #   1. dst is a symlink                  → rm it (any kind of dst link is
    #                                           safe to replace; we never
    #                                           recurse into the target)
    #   2. dst is a real file/dir            → mv it aside as <dst>.pre-brew-<epoch>
    #   3. dst doesn't exist                 → no-op
    #
    # Both rm + mv are routed through shell utils (not File.delete /
    # FileUtils.mv) so macOS extended attributes (com.apple.provenance,
    # quarantine etc.) get the same EPERM treatment we recover from. On
    # a fresh Mac (criterion #13 target) none of these branches fire.
    if File.symlink?(dst)
      unless quiet_system("/bin/rm", "-f", dst)
        opoo "Could not remove existing symlink at #{dst} — skipping."
        opoo "Manual fix: xattr -c #{dst} && rm #{dst} && ln -s #{src} #{dst}"
        return
      end
    elsif File.exist?(dst)
      backup = "#{dst}.pre-brew-#{Time.now.to_i}"
      if quiet_system("/bin/mv", dst, backup)
        opoo "Moved existing #{dst} aside to:"
        opoo "  #{backup}"
      else
        opoo "Existing #{dst} could not be moved aside (likely macOS"
        opoo "extended-attribute lock). Skipping symlink for this entry."
        opoo "To migrate manually:"
        opoo "  xattr -dr com.apple.provenance #{dst}"
        opoo "  mv #{dst} #{backup}"
        opoo "  ln -s #{src} #{dst}"
        return
      end
    end
    File.symlink(src, dst)
  end

  # Criterion #6: brew services launchd integration. Single unit boots both
  # the proxy and pulsed via the wrapper script.
  service do
    run [opt_bin/"openlap-wrapper"]
    keep_alive true
    log_path "#{Dir.home}/.openlap/logs/openlap.log"
    error_log_path "#{Dir.home}/.openlap/logs/openlap-err.log"
    working_dir Dir.home
  end

  def caveats
    <<~EOS
      First-run setup:
        openlap setup       # Abe OAuth + provision x-man under your deployer
        openlap doctor      # verify everything is wired
        brew services start openlap

      Required external dep (not brew-installable):
        Claude CLI 2.x — install via `npm install -g @anthropic-ai/claude-code`
        `openlap doctor` flags it if missing.

      If you previously ran `go install ./cmd/pulsed`, stop it first:
        pkill pulsed
        brew services restart openlap
    EOS
  end

  test do
    # Smoke check — binaries are present and respond. Real coverage lives in
    # the OLP-203 #13 / #14 manual rehearsal.
    assert_match(/pulsed/i, shell_output("#{bin}/pulsed --help 2>&1", 0..2))
    assert_match(/wrspawn/i, shell_output("#{bin}/wrspawn --help 2>&1", 0..2))
  end
end
