# anmolAudio

**anmolAudio** is a lightweight, low-latency, system-wide parametric equalizer and audio routing manager for macOS (14.2+).

It routes system audio through a private Core Audio Process Tap and a vDSP biquad filter cascade, letting you apply headphone correction curves (from AutoEq or your own presets) without virtual soundcards, third-party kernel extensions, or high latency.

---

## Highlights

* **Automatic Output Management:**
  * **Monitor / TV Filtering:** Automatically blocks HDMI and DisplayPort displays from being auto-selected or cluttering your output picker.
  * **Smart Dock Protection:** Office docks (like HP Dock Audio or Dell WD19) default to *Manual Only* mode so your audio never jumps to an empty 3.5mm jack.
  * **Device-to-Preset Memory:** Remembers your preferred EQ profile for every device ever connected and automatically restores it on switch.
* **AEC-Safe Call Audio Handling:**
  * Fixes the notorious FaceTime / Zoom "whisper quiet audio" bug.
  * Direct support for `avconferenced` and `TelephonyUtilities`.
  * **Surgical Call Bypass (Default):** Call audio routes cleanly to macOS hardware with native Apple Acoustic Echo Cancellation (AEC) and full volume, while background music in Spotify or Safari continues playing with your full custom EQ curve.
  * **Flatten & Preamp (Optional):** Retains your preset's volume gain while flattening frequency filters during calls.
* **Unified Application Rules:**
  * **Bypass EQ:** Let DAWs (Logic, Ableton) or games play untouched audio directly to the DAC.
  * **Call App:** Mark conferencing apps to trigger intelligent call handling when your microphone is in use.
* **Integrated AutoEq Library:**
  * Built-in browser for thousands of headphone frequency response measurements (Oratory1990, Crinacle, etc.).
* **A/B Blind Testing:**
  * Level-matched blind comparison tool to test if your EQ tweaks actually improve sound quality.

---

## Building from Source

### Prerequisites

* macOS 14.2 or newer
* Xcode 15 or newer
* [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Build & Run

Clone the repository and run the development script:

```bash
git clone https://github.com/anmolbyte/anmolAudio.git
cd anmolAudio
./scripts/dev.sh
```

Or generate the project and open in Xcode:

```bash
xcodegen generate
open anmolAudio.xcodeproj
```

---

## State & Storage

* **`~/Library/Application Support/anmolAudio/`** — User presets (`presets.json`) and AutoEq catalog cache.
* **`~/Library/Preferences/app.anmol.anmolAudio.plist`** — UserDefaults (device memories, volume preferences, and app rules).

---

## License & Attribution

`anmolAudio` is released under the **MIT License**. See [LICENSE](LICENSE) for details.

anmolAudio is built upon open-source macOS Core Audio foundations by Linus Sjöberg, extended with advanced output device policies, smart dock/monitor filtering, unified application routing, and AEC-safe call audio management.
