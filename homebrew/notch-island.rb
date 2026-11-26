# Homebrew cask for Notch Island.
# Lives in its own GitHub repo named "homebrew-notch-island", at Casks/notch-island.rb.
# After each release: update `version` and `sha256` (make_dmg.sh prints the sha256).
cask "notch-island" do
  version "1.3"
  sha256 "35861f516be477d14152ce4e4b77cfc17e3994aeeb7d5f938f320d411663a31a"

  url "https://github.com/t27124949-cell/notch-island/releases/download/v#{version}/NotchIsland.dmg"
  name "Notch Island"
  desc "Dynamic-island-style hub for the MacBook notch"
  homepage "https://github.com/t27124949-cell/notch-island"

  depends_on macos: ">= :ventura"

  app "NotchIsland.app"

  # The app is not signed with an Apple Developer ID yet, so clear the download quarantine flag.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/NotchIsland.app"]
  end

  zap trash: [
    "~/.notchisland",
    "~/Library/Application Support/NotchIsland",
    "~/Library/Logs/NotchIsland.log",
    "~/Library/Preferences/io.github.t27124949-cell.notchisland.plist",
  ]
end
