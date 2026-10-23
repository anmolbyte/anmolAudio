# Changelog

All notable changes to **anmolAudio** will be documented in this file.

## [1.0.0] - 2026-10-23

### Features
- **Smart Output Device Policies**: Filter out monitor displays (DisplayPort / HDMI) from auto-switching audio. Configure devices to `Auto`, `Manual only` (ideal for USB/Thunderbolt office docks like HP Docks), or `Ignored`.
- **Per-Device EQ Preset Pairing**: Automatically recall your preferred EQ profile when switching between headphones, speakers, and external DACs.
- **Unified Apps Management**: Consolidated excluded apps and VoIP apps into a single intuitive settings interface with instant bypass and call detection toggles.
- **Intelligent FaceTime & VoIP Handling**: Automatic detection of macOS call daemons (`com.apple.avconferenced`, `com.apple.TelephonyUtilities`) with selectable behavior:
  - *Bypass Call Audio (Default)*: Keep call audio untouched through macOS's native acoustic echo cancellation engine to eliminate quiet audio bugs.
  - *Flatten EQ & Keep Preamp*: Preserve custom volume preamps while removing EQ filter phase distortions.
  - *Pause Engine During Calls*: Automatically pause the audio tap while any call is in progress.
- **Sleek Native Branding**: Modern waveform symbol design replacing legacy cartoon graphics.
- **System-Wide AutoEq Engine**: Integrated parametric EQ with 5,000+ headphone presets from the AutoEq database and lossless Core Audio processing.
