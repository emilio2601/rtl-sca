# Changelog

All notable changes to rtl-sca are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project uses
[Semantic Versioning](https://semver.org/) — pre-1.0, so the CLI may still change.

## [0.1.0] — 2026-06-28

First tagged release. An RTL-SDR FM **subcarrier (SCA)** decoder: find, demodulate,
and play or record the narrowband audio subcarriers (commonly 67 / 92 kHz) hidden
above a station's stereo program. Verified over the air on macOS and a Raspberry Pi 4.

### Added
- **`scan`** — survey a station's MPX baseband and report the pilot and each
  subcarrier slot (center, modulation, bandwidth, SNR) with a best-guess role.
  Content-independent carrier-presence classification (FM / AM-DSB / data); results
  go to stdout.
- **`play`** — demodulate a chosen subcarrier and play it live.
- **`rec`** — record the demodulated subcarrier to a 16-bit mono WAV; `-o -` streams
  the WAV to stdout.
- **Sources** — a local RTL-SDR, an `rtl_tcp` server (`--remote host[:port]`, IP or
  hostname with the port defaulting to 1234), or a recorded IQ file (`.cu8` / `.cs16`).
- **Demodulation** — narrowband FM, envelope AM, and coherent (Costas) AM for
  suppressed-carrier DSB-SC; a continuous `--deemph` time constant; any `--audio-rate`
  via a rational resampler.
- **Diagnostics** — a one-line startup summary on every `play`/`rec`, and `-v`/`-vv`
  health and signal lines (DSP throughput, USB/audio drops, front-end level and
  clipping, Costas lock and carrier offset). `-V`/`--version`.
- Deviation-matched output gains, a dropped tune-in transient on live sources, a
  clean end-of-stream on a live disconnect, and facts-only error messages — including
  a check that catches a tune frequency typed without its suffix (`89.9` → "add a
  k/M/G suffix").

[0.1.0]: https://github.com/emilio2601/rtl-sca/releases/tag/v0.1.0
