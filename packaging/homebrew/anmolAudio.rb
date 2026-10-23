cask "anmolAudio" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/anmolbyte/anmolAudio/releases/download/v#{version}/anmolAudio-#{version}.dmg",
      verified: "github.com/anmolbyte/anmolAudio/"
  name "anmolAudio"
  desc "System-wide parametric headphone EQ with intelligent device routing and AutoEq"
  homepage "https://github.com/anmolbyte/anmolAudio"

  auto_updates true
  depends_on macos: :sonoma

  app "anmolAudio.app"

  zap trash: [
    "~/Library/Application Support/anmolAudio",
    "~/Library/Caches/app.anmol.anmolAudio",
    "~/Library/HTTPStorages/app.anmol.anmolAudio",
    "~/Library/Preferences/app.anmol.anmolAudio.plist",
  ]
end
