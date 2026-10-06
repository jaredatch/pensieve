# typed: strict
# frozen_string_literal: true

cask "pensieve" do
  version "0.9.0"
  sha256 :no_check

  url "https://github.com/jaredatch/pensieve/releases/download/v#{version}/Pensieve-#{version}.dmg"
  name "Pensieve"
  desc "Manage and sync AI skills across agents and machines"
  homepage "https://github.com/jaredatch/pensieve"

  depends_on macos: :tahoe

  livecheck do
    url "https://raw.githubusercontent.com/jaredatch/pensieve/master/appcast.xml"
    strategy :sparkle
  end

  app "Pensieve.app"

  zap trash: [
    "~/Library/Caches/com.jaredatch.Pensieve",
    "~/Library/Preferences/com.jaredatch.Pensieve.plist",
  ]
end
