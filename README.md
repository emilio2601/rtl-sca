# rtl-sca

A command-line tool to detect, demodulate, and play back FM broadcast **subcarriers**
(SCA) from an RTL-SDR. Written in Zig.

US FM stations carry more than the stereo program: above the audible 0–53 kHz region,
the composite MPX baseband often hides narrowband audio subcarriers — commonly at
**67 kHz** and **92 kHz** (reading services for the blind, background music, niche
broadcasts). `rtl-sca` recovers the FM main carrier, reaches into a chosen subcarrier
slot, demodulates it (FM or AM), and plays it back or writes a WAV.

See [`SPEC.md`](SPEC.md) for the full signal-chain design and background.

## Status

Early. The CLI and argument parsing are in place; the DSP pipeline is being built
phase by phase (see Roadmap). Today the binary parses a command and prints the
resolved plan — it does not yet demodulate.

## Requirements

- **Zig 0.16+** (`brew install zig`).
- An RTL-SDR is only needed for live capture (a later phase). The DSP chain is
  developed and validated against recorded IQ files first.

## Build

```sh
zig build              # builds zig-out/bin/rtl-sca
zig build test         # runs unit tests
zig build run -- scan 89.9M
```

## Usage

```
rtl-sca <command> <input> [flags]
```

`<input>` is auto-detected: a frequency (`89.9M`, `89900000`) tunes a radio; anything
else is treated as a recorded IQ file path.

```sh
rtl-sca scan 89.9M                                   # survey the MPX for subcarriers
rtl-sca play 89.9M --sub 67k --mod fm --deemph 150us # demodulate and play live
rtl-sca rec  89.9M --sub 67k -o gatewave.wav         # demodulate and write a WAV
rtl-sca play capture.cu8 --sub 86k --mod am-env      # work offline from a capture
rtl-sca play 89.9M --sub 0 --bw 15k --deemph 75us    # main program audio (mono)
```

The **main program audio is the slot at 0 Hz**: `--sub 0` (with ~15 kHz bandwidth and
75 µs de-emphasis) recovers normal mono FM. It's supported as a validation/utility
mode — if the station is audible, the front-end and FM demod are proven before
chasing a weak subcarrier. Stereo decode is out of scope.

Key flags (run `rtl-sca` with no command for the full list):

| flag | meaning | default |
|------|---------|---------|
| `--source PATH` | explicit file source (overrides the positional) | — |
| `--rtl-tcp H:PORT` | tune `<input>` over an `rtl_tcp` network server | — |
| `--sub HZ` | subcarrier center (`67k`, `92k`, …); `0` = main channel | `67k` |
| `--bw HZ` | channel bandwidth (`8k` SCA, `15k` main) | `8k` |
| `--mod MODE` | `fm` \| `am-env` \| `am-coherent` | `fm` |
| `--deemph TAU` | de-emphasis time constant (`120us`, `off`, …) | `150us` |
| `--rate HZ` | RTL / recording sample rate | `1.024M` |
| `--gain DB` | tuner gain (radio only) | auto |
| `--device N` | USB dongle index (radio only) | `0` |
| `--ppm N` | crystal correction in ppm (radio only) | `0` |
| `-o FILE` | output WAV path (`rec`) | — |

De-emphasis is a continuous time constant, not a fixed set. `150us` is the SCA
standard (the default); `75us` (US) and `50us` (EU) are the main-channel values;
`off` is no de-emphasis.

## Roadmap

| Phase | Scope |
|-------|-------|
| 1 | Offline MVP: file source → FM demod → 67 kHz FM subcarrier → de-emphasis → WAV |
| 2 | Live: `rtl_tcp` and USB sources, audio playback via miniaudio |
| 3 | Configurable: main/subcarrier freq, modulation mode, de-emphasis; AM demod paths |
| 4 | `scan` survey mode: PSD, pilot/slot detection, AM-vs-FM classification, SNR |
| 5 | Stretch: RDS decode, headless Pi daemon, arbitrary-rate resampler |

## Project layout

- `src/main.zig` — entry point; wires the CLI to the pipeline.
- `src/cli.zig` — argument and subcommand parsing.
- `SPEC.md` — source of truth for the design and build phases.
- `CLAUDE.md` — conventions for working in this repo (incl. Zig 0.16 notes).
