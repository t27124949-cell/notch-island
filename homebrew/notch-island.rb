# Homebrew cask for Notch Island.
# Lives in its own GitHub repo named "homebrew-notch-island", at Casks/notch-island.rb.
# After each release: update `version` and `sha256` (make_dmg.sh prints the sha256).
cask "notch-island" do
  version "1.3"
  sha256 "9a29192412232e00cc2d7fbc1b6880da0ba54693376d746cc44fe88f3fbbc861"

  url "https://github.com/t27124949-cell/notch-island/releases/download/v#{version}/NotchIsland.dmg"
  name "Notch Island"
  desc "Dynamic-island-style hub for the MacBook notch"
  homepage "https://github.com/t27124949-cell/notch-island"

  depends_on macos: :ventura

  app "NotchIsland.app"

  # The app is not signed with an Apple Developer ID yet, so clear the download quarantine flag.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "/Applications/NotchIsland.app"], must_succeed: false
  end

  zap trash: [
    "~/.notchisland",
    "~/Library/Application Support/NotchIsland",
    "~/Library/Logs/NotchIsland.log",
    "~/Library/Preferences/io.github.t27124949-cell.notchisland.plist",
  ]
end
