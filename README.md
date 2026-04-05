# CamillaDSP-Swift

A faithful Swift reimplementation of [CamillaDSP](https://github.com/HEnquist/camilladsp) — a flexible, real-time audio DSP engine for crossovers, room correction, and general audio filtering on macOS — plus a native SwiftUI monitor app inspired by [CamillaDSP-Monitor](https://github.com/Wang-Yue/CamillaDSP-Monitor).

All filter algorithms, coefficient formulas, and DSP processing have been verified line-by-line against the Rust source with matching test vectors and tolerances.

The project ships three products:

| Product | Description |
|---------|-------------|
| **CamillaDSPLib** | Core DSP library — filters, pipeline, CoreAudio backend, WebSocket API |
| **camilladsp** | Command-line tool for headless operation |
| **CamillaDSPMonitor** | Native macOS SwiftUI app with real-time monitoring and pipeline configuration |

## Requirements

- macOS 14+ (Sonoma)
- Swift 5.9+
- Xcode 15+ (or Swift toolchain)

## Building

```bash
# Debug build
swift build

# Release build (recommended for real-time audio)
swift build -c release
```

## Testing

```bash
swift test
```

173 tests across 10 test files, all verified against the Rust CamillaDSP test suite with matching parameters, expected values, and tolerances. Covers biquad coefficients (all 16 subtypes + bandwidth variants), FFT convolution, mixer routing, sample format conversions, configuration parsing/validation, pipeline execution, processors (compressor, noise gate, RACE), dither (22 types), resampler, and signal generator.

---

## CamillaDSPLib — Core Library

The library provides the full CamillaDSP feature set as a Swift package, optimized with Apple's Accelerate framework (vDSP FFT, vector math, biquad processing). Every filter faithfully matches the Rust implementation with per-filter config validation and runtime parameter updates.

### Filters

| Filter | Description |
|--------|-------------|
| **Biquad** | 16 subtypes via Audio EQ Cookbook — Lowpass, Highpass, Bandpass, Notch, Allpass, Peaking, Lowshelf, Highshelf, GeneralNotch, LinkwitzTransform, and first-order variants. Q and bandwidth modes for Notch/Bandpass/Allpass. Slope mode for shelves. |
| **BiquadCombo** | Butterworth, Linkwitz-Riley (proper Q computation for all even orders), Graphic EQ, Tilt EQ (110/3500 Hz, Q=0.35), Five-Point PEQ |
| **Convolution** | FIR via FFT overlap-add with segmented impulse response, vDSP-optimized |
| **Delay** | Integer sample delay + 1st/2nd order Thiran allpass for fractional-sample precision |
| **DiffEq** | Arbitrary-order IIR (direct form) with a[0] normalization |
| **Gain** | Static gain with optional phase inversion and mute |
| **Volume** | Fader-linked gain with chunk-granular smooth ramping |
| **Loudness** | Fletcher-Munson compensation (70 Hz low shelf, 3500 Hz high shelf, 12 dB/oct slope) with optional mid attenuation |
| **Limiter** | Hard clip and cubic polynomial soft clip |
| **Dither** | 22 types: None, Flat, Highpass (violet noise), Fweighted (3 variants), Gesemann (44.1/48), Lipshitz (2 variants), Shibata (44.1/48/88.2/96/192 in standard/high/low variants) |

### Processors

- **Compressor** — dB-domain envelope detection, configurable attack/release/threshold/ratio, makeup gain, optional limiter
- **Noise Gate** — dB-domain envelope, configurable attenuation (not hard mute), attack/release
- **RACE** — Recursive Ambiophonic Crosstalk Eliminator with per-sample feedback loop and subsample delay

### Mixer

Arbitrary channel routing (N-in to M-out) with per-source gain (dB or linear), phase inversion, muting, and runtime parameter updates.

### Pipeline

Sequential processing chain with:
- Implicit main volume filter with smooth chunk-granular ramping
- Channel count tracking through mixer steps
- Filter steps auto-expand to all channels when no explicit list given
- Per-filter `validateConfig` and `updateParameters` matching Rust
- Processing load measurement

### Backends

- **CoreAudio** — Native macOS capture and playback via HAL AudioUnit, device enumeration, exclusive (hog) mode, sample rate detection and hardware rate switching
- **File** — Raw PCM file, stdin/stdout, WAV
- **Signal Generator** — Sine, square, white noise with configurable frequency and level (dB)

### Resampler

- **AsyncSinc** — Windowed-sinc interpolation (vDSP-optimized) with anti-aliasing cutoff scaling. Profiles: Very Fast (64), Fast (128), Balanced (192), Accurate (256) matching Rust sinc lengths
- **AsyncPoly** — Polynomial interpolation with per-channel phase continuity across chunks
- **Synchronous** — Fixed-ratio resampling via AsyncSinc

### WebSocket Control API

Network.framework-based server implementing all 71 CamillaDSP WebSocket commands:

| Category | Commands |
|----------|----------|
| **State** | GetVersion, GetState, GetStopReason, Stop, Exit |
| **Volume** | GetVolume, SetVolume, AdjustVolume, GetMute, SetMute, ToggleMute |
| **Faders** | GetFaders, GetFaderVolume, SetFaderVolume, AdjustFaderVolume, GetFaderMute, SetFaderMute, ToggleFaderMute, SetFaderExternalVolume |
| **Signal Levels** | GetCaptureSignalPeak/Rms, GetPlaybackSignalPeak/Rms, all *Since/*SinceLast variants, GetSignalLevels, GetSignalRange |
| **Peaks** | GetSignalPeaksSinceStart, ResetSignalPeaksSinceStart |
| **Metrics** | GetProcessingLoad, GetResamplerLoad, GetRateAdjust, GetBufferLevel, GetClippedSamples, ResetClippedSamples, GetUpdateInterval, SetUpdateInterval |
| **Config** | GetConfig, SetConfig, GetConfigJson, SetConfigJson, PatchConfig, GetConfigValue, SetConfigValue, ValidateConfig, ValidateConfigJson, Reload, GetConfigTitle, GetConfigDescription, GetPreviousConfig |
| **Config Files** | GetConfigFilePath, SetConfigFilePath, ReadConfig, ReadConfigFile, ReadConfigJson |
| **State File** | GetStateFilePath, GetStateFileUpdated |
| **Devices** | GetAvailableCaptureDevices, GetAvailablePlaybackDevices, GetSupportedDeviceTypes, GetCaptureRate, GetChannelLabels |

### State File

YAML-based state persistence matching Rust format — saves/restores config path, volume, and mute state for all 5 faders across restarts.

### Configuration

YAML configuration via [Yams](https://github.com/jpsim/Yams) with token substitution (`$samplerate$`, `$channels$`) and comprehensive validation:
- Per-filter validation (frequency < Nyquist, Q > 0, slope bounds, stability checks)
- Per-mixer validation (channel bounds, no duplicates)
- Per-processor validation (attack/release > 0, channel bounds)
- Pipeline channel-count consistency walk (mixer in/out, filter bounds, playback match)
- Rust-compatible YAML keys for config interoperability

---

## camilladsp — Command-Line Tool

Headless DSP engine driven by a YAML configuration file.

```bash
# List available audio devices
swift run camilladsp --list-devices

# Validate a configuration file
swift run camilladsp --check config.yml

# Run with a configuration
swift run camilladsp config.yml

# Run with WebSocket control API on port 1234
swift run camilladsp config.yml -p 1234

# Verbose logging
swift run camilladsp config.yml -v
```

### Options

| Flag | Description |
|------|-------------|
| `<config-file>` | Path to YAML configuration file |
| `-p, --port <port>` | Enable WebSocket server on this port |
| `-a, --address <addr>` | WebSocket bind address (default: 127.0.0.1) |
| `-c, --check` | Validate configuration and exit |
| `-v, --verbose` | Enable debug-level logging |
| `--list-devices` | Print available capture/playback devices and exit |

---

## CamillaDSPMonitor — macOS App

A native SwiftUI application that directly uses CamillaDSPLib for real-time audio processing, monitoring, and pipeline configuration — no Python or WebSocket intermediary required.

```bash
swift run CamillaDSPMonitor
```

### Features

- **Device selection** — Capture and playback device picker with auto-detected sample rates, channel count, exclusive (hog) mode
- **Auto-start** — Engine starts automatically on launch with soft volume ramp (-30 dB to target over 4 seconds)
- **Device safety** — Auto-stops engine when a device is disconnected; won't start if selected device is unavailable
- **Live level meters** — Dual RMS/Peak meters for capture and playback (L/R), split-bar design with separate dB readouts
- **Spectrum analyzer** — FFT and Filter Bank modes, pre/post processing source, 30-band ISO 1/3-octave display
- **Signal chain** — Interactive pipeline visualization with tappable stage chips
- **Volume control** — Toolbar mute button and slider (-60 to +20 dB, red indicator for positive gain)
- **Processing load** — Real-time CPU usage display
- **Sample rate** — Auto-detected, hardware rate switching, external change listener
- **Resampler** — Pipeline sidebar item with dedicated detail page (AsyncSinc/AsyncPoly/Synchronous)
- **EQ Presets** — Biquad parametric EQ editor with three modes:
  - **Diagram** — Interactive frequency response with draggable color-coded band handles
  - **Form** — Table-based editor with type picker, freq/gain/Q fields
  - **YAML** — Raw CamillaDSP-compatible text editor with copy/paste
- **Mini player** — Floating translucent overlay (PiP button) visible above all windows including fullscreen. Three modes: spectrum, pipeline, meters
- **Stereo width** — Continuous slider (-100% swapped to 200% extra-wide) via Mid/Side matrix
- **Crossfeed** — L1–L5 presets or custom Fc/Db with computed filter parameters
- **Loudness** — Adjustable reference level (-50 to +20 dB) and boost
- **EQ preamp** — Per-stage gain control to prevent clipping from boost filters
- **Settings persistence** — All preferences, pipeline stages, and EQ presets saved across launches

### Pipeline Stages

| Stage | Description |
|-------|-------------|
| **Balance** | L/R pan with linear pan law |
| **Width** | Continuous stereo width (-100% to 200%) via Mid/Side |
| **M/S Proc** | Mid-Side encoding |
| **Phase Invert** | Left / Right / Both channel inversion |
| **Crossfeed** | L1–L5 presets or custom Fc/Db |
| **EQ** | Same L/R or Separate L/R with preset selection and preamp |
| **Loudness** | Fletcher-Munson compensation |
| **Emphasis** | De-emphasis / Pre-emphasis |
| **DC Protection** | First-order highpass at 7 Hz |

---

## Project Structure

```
Sources/
  CamillaDSP/                    # CLI executable
    main.swift
  CamillaDSPLib/                  # Core DSP library
    Audio/                        # AudioChunk, PrcFmt, ProcessingParameters, SampleFormat
    Backend/                      # CoreAudio, File, SignalGenerator backends
    Config/                       # ConfigTypes, Configuration, StateFile
    Engine/                       # Multi-threaded DSP engine
    Filters/                      # Biquad, BiquadCombo, Convolution, Delay, DiffEq,
                                  # Dither, Filter, Gain, Limiter, Loudness, Volume
    Mixer/                        # Channel routing mixer
    Pipeline/                     # Processing pipeline with implicit volume
    Processors/                   # Compressor, NoiseGate, RACE
    Resampler/                    # AsyncSinc, AsyncPoly, Synchronous resamplers
    Server/                       # WebSocket control server (71 commands)
  CamillaDSPMonitor/              # macOS SwiftUI app
    Models/
      AppState.swift              # Core state and properties
      AppState+Devices.swift      # Device management and listeners
      AppState+Engine.swift       # Engine control and config building
      AppState+Monitoring.swift   # Meters, spectrum analyzers, MeterState
      AppState+Pipeline.swift     # Pipeline stage persistence
      PipelineStage.swift         # Stage types and properties
      PipelineStage+Builders.swift # Config generation
      PipelineStage+Crossfeed.swift # Crossfeed computation
      PipelineStage+Defaults.swift # Factory and snapshot persistence
      EQPreset.swift              # EQ band/preset models
      EQPreset+Persistence.swift  # Preset save/load/defaults
    Views/
      ContentView.swift           # NavigationSplitView layout
      DashboardView.swift         # Pipeline overview + meters + spectrum
      DevicePickerView.swift      # Device selection
      StageDetailView.swift       # Per-stage configuration
      EQPresetDetailView.swift    # EQ preset editor (3 modes)
      EQDiagramMode.swift         # Frequency response diagram
      EQFormMode.swift            # Form-based band editor
      EQYAMLMode.swift            # YAML text editor
      MiniPlayerView.swift        # Floating mini player
      MiniPlayerContent.swift     # Mini player display modes
      MiniPlayerWindowController.swift # NSPanel management
      LevelMeterView.swift        # Dual RMS/Peak meters
      SpectrumView.swift          # 30-band spectrum display
      VolumeControlView.swift     # Toolbar volume/mute
      SettingsView.swift          # App settings
Tests/
  CamillaDSPTests/                # 173 tests matching Rust test suite
examples/
  example_config.yml              # 2-way crossover with room EQ
  signal_generator_test.yml       # Test config using signal generator
```

## Architecture

The engine runs three real-time threads:

```
Capture Thread ──→ Processing Thread ──→ Playback Thread
                        │
                   Audio Taps (pre/post)
                        │
                   Spectrum Queue
                        │
                   UI Timer (5 Hz)
```

- **Capture thread** reads from CoreAudio input, updates capture peak/RMS levels
- **Processing thread** runs the filter/mixer/processor pipeline with implicit volume ramp
- **Playback thread** writes processed audio to CoreAudio output
- **Audio taps** provide pre/post-processing samples for spectrum analysis
- **Spectrum analysis** runs on a dedicated dispatch queue (FFT or filter bank)
- **Rate adjustment** compensates clock drift with synchronized ratio updates
- **Processing errors** stop the engine (no silent audio dropouts)

## Dependencies

| Package | Purpose |
|---------|---------|
| [Yams](https://github.com/jpsim/Yams) | YAML configuration parsing |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI argument parsing |
| [swift-log](https://github.com/apple/swift-log) | Structured logging |

System frameworks: CoreAudio, AudioToolbox, Accelerate, Network, SwiftUI.

## License

This is a Swift reimplementation of [CamillaDSP](https://github.com/HEnquist/camilladsp) by Henrik Enquist, originally written in Rust under GPL-3.0.

## Acknowledgments

- [CamillaDSP](https://github.com/HEnquist/camilladsp) by Henrik Enquist — the original Rust implementation
- [CamillaDSP-Monitor](https://github.com/Wang-Yue/CamillaDSP-Monitor) by Wang Yue — the Python/WebSocket monitor that inspired the SwiftUI app
- [camilladsp-crossfeed](https://github.com/Wang-Yue/camilladsp-crossfeed/) — crossfeed parameter computation
- Audio EQ Cookbook by Robert Bristow-Johnson — biquad filter coefficient formulas
- Apple Accelerate framework — vDSP FFT and vector operations
