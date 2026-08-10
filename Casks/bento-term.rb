# Homebrew cask for the Bento Term Mac app.
#
#   brew install --cask NovaShang/BentoTerm/bento-term
#
# A cask, not a formula: this ships a GUI .app bundle, which Homebrew wants
# staged into /Applications rather than symlinked into a bin. The old
# `bento-terminal` formula in NovaShang/bento installed a Go daemon + CLI
# that no longer exists — it is superseded by this file, not renamed.
#
# `version` and `sha256` below are rewritten by .github/workflows/release.yml
# after each tagged release. Do not hand-edit them; edit the release workflow
# if the artifact naming changes.
cask "bento-term" do
  version "0.2.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/NovaShang/BentoTerm/releases/download/v#{version}/BentoTerm-macos-arm64.zip",
      verified: "github.com/NovaShang/BentoTerm/"
  name "Bento Term"
  desc "Terminal that runs a team of AI coding agents in parallel"
  homepage "https://bentoai.dev/term/"

  livecheck do
    url :url
    strategy :github_latest
  end

  # arm64-only by construction: release.yml builds a single-arch app because
  # GitHub's Intel Mac runners are queue-starved post-deprecation.
  depends_on arch: :arm64
  # Sonoma is macOS 14, matching MACOSX_DEPLOYMENT_TARGET in project.yml.
  # A bare symbol is "that version or newer" — the ">= :sonoma" string form
  # means the same thing but is deprecated.
  depends_on macos: :sonoma

  app "BentoTerm.app"

  zap trash: [
    "~/Library/Application Support/Bento",
    "~/Library/Caches/com.bento.term.mac",
    "~/Library/HTTPStorages/com.bento.term.mac",
    "~/Library/Preferences/com.bento.term.mac.plist",
    "~/Library/Saved Application State/com.bento.term.mac.savedState",
  ]
end
