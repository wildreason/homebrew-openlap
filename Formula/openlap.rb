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
  version "0.1.0"
  license "MIT"

  # NOTE: (OLP-203 criterion #1): url + sha256 are placeholders. Criterion #2
  # wires up the GitHub Actions release pipeline that cross-compiles pulsed +
  # wrspawn for darwin-arm64/amd64 on tag push, uploads the tarball to
  # GitHub Releases, and PR-bumps these fields. Until then this formula will
  # not actually install — `brew install --dry-run` is the only thing wired
  # up at #1. See OLP-203 body for the full pipeline plan.
  depends_on "node"
  depends_on "tmux"

  on_macos do
    on_arm do
      url "https://github.com/wildreason/openlap/releases/download/v0.1.0/openlap-0.1.0-darwin-arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/wildreason/openlap/releases/download/v0.1.0/openlap-0.1.0-darwin-amd64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
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

    # Wrapper script that launchd runs (boots both proxy + pulsed).
    # Generated here so it can reference Cellar paths cleanly.
    (bin/"openlap-wrapper").write <<~SH
      #!/bin/bash
      # openlap-wrapper: launchd entrypoint — boots npm proxy + pulsed.
      # Logs to ~/.openlap/logs/{openlap,pulsed}.log via openlap start's
      # built-in log rotation (OLP-197 criterion #10 — TS port lap).
      set -e
      exec "#{HOMEBREW_PREFIX}/bin/openlap" start --with-pulsed "#{opt_bin}/pulsed"
    SH
    (bin/"openlap-wrapper").chmod 0755

    # Skill files + agent definitions, kept under share/openlap/ so brew
    # owns them. post_install symlinks into ~/.claude/.
    (share/"openlap/skills").install Dir["share/openlap/skills/*"]
    (share/"openlap/agents").install Dir["share/openlap/agents/*"]
  end

  def post_install
    # Criterion #4: install/upgrade the npm proxy. Idempotent — npm install
    # -g is a no-op when the requested version is already present.
    system "#{Formula["node"].opt_bin}/npm", "install", "-g", "@openlap/openlap"

    # Criterion #5: symlink skills + agents into ~/.claude. Idempotent —
    # ln_sf replaces existing symlinks but leaves real files alone.
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
      dst = "#{skills_target}/#{name}"
      ln_sf(src, dst)
    end

    %w[x-man].each do |agent|
      src = "#{share}/openlap/agents/#{agent}.md"
      next unless File.exist?(src)

      ln_sf(src, "#{agents_target}/#{agent}.md")
    end

    %w[adversary admin].each do |agent|
      src = "#{share}/openlap/agents/#{agent}.md"
      next unless File.exist?(src)

      ln_sf(src, "#{org_agents_target}/#{agent}.md")
    end

    # Back-compat: ~/.local/bin/ symlinks pointing into the skill's scripts/.
    # Anything that calls `nudge-agent` / `ask-agent` / `clone` directly
    # (via PATH) keeps working post-spawn-v0.1.1 reorg. ~/.local/bin/ is
    # already on PATH for x-man's setup; harmless on machines that don't
    # have it on PATH.
    %w[nudge-agent ask-agent clone].each do |script|
      src = "#{share}/openlap/skills/x-man/scripts/#{script}"
      next unless File.exist?(src)

      ln_sf(src, "#{legacy_bin}/#{script}")
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
