# Changelog

All notable changes to rtl-sca are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project uses
[Semantic Versioning](https://semver.org/) — pre-1.0, so the CLI may still change.

## [0.2.0] — 2026-06-30

A sharper `scan`: a uniform MPX inventory, source-level fixes for the false-positive
classes that were biting (phantom/stale subcarriers, split RDS, stereo splatter), a
saner gain default, and a configurable integration window for fading subcarriers.

### Changed
- **`scan` output is now a uniform MPX inventory** — every baseband component is a
  table row with the same columns (center · type · bandwidth · strength · role): the
  0 kHz main program, the 19 kHz pilot, the 38 kHz stereo L−R, 57 kHz RDS, and any
  67/92 kHz SCAs. The prose `stereo: yes/no` line is gone — stereo now shows as the
  presence of the pilot row. Easier to read by eye and to parse by machine.
- **Default tuner gain is now manual 0 dB** (was the tuner AGC, which pumps with
  signal level and isn't reproducible). AGC is opt-in via `--gain auto`, and the gain
  is printed in `scan` output. Note: unlike rtl_sdr, here `--gain 0` means a literal
  0 dB, not auto — a deliberate floor you dial up from.
- The 38 kHz L−R now reports its **measured sideband energy** (live stereo
  separation, which drops on mono program content) instead of echoing the pilot's SNR.

### Added
- **`--scan-seconds N`** — configurable `scan` integration window (1–300 s, default 4).
  A longer window catches intermittent or fading SCAs that a 4 s snapshot misses.
- **`--gain auto`** — opt into the RTL tuner's automatic gain control.

### Fixed
- **`scan` flushes the tune-in window** on live sources, discarding the stale
  previous-station data `rtl_tcp` delivers after a retune (it has no flush-on-retune
  command). This eliminated phantom subcarriers — e.g. a fake 67 kHz SCA and stereo
  flag carried over from the previously-tuned frequency.
- **More robust subcarrier detection** from the known MPX structure: the 38 kHz L−R
  is inferred from the pilot rather than its content-dependent SNR; the 57 kHz RDS is
  coalesced into one slot (was splitting into phantom 56/58 kHz pairs); stereo-skirt
  splatter below 54 kHz is suppressed on stereo stations; and the search band is
  capped at the 110 kHz anti-alias cutoff.

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

[0.2.0]: https://github.com/emilio2601/rtl-sca/releases/tag/v0.2.0
[0.1.0]: https://github.com/emilio2601/rtl-sca/releases/tag/v0.1.0
