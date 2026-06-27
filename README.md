# rtl-sca

A command-line tool to detect, demodulate, and play back FM broadcast **subcarriers**
(SCA) from an RTL-SDR. Written in Zig.

US FM stations carry more than the stereo program: above the audible 0–53 kHz region,
the composite MPX baseband often hides narrowband audio subcarriers — commonly at
**67 kHz** and **92 kHz** (reading services for the blind, background music, niche
broadcasts). `rtl-sca` recovers the FM main carrier, reaches into a chosen subcarrier
slot, demodulates it (FM or AM), and plays it back or writes a WAV.

See [`SPEC.md`](SPEC.md) for the full signal-chain design and background.

## What it does

- **`scan`** surveys a station's MPX baseband — pilot, subcarrier slots, modulation
  (FM / AM-DSB / data), bandwidth, and SNR.
- **`play`** demodulates a chosen subcarrier and plays it live out the speakers.
- **`rec`** writes the demodulated audio to a WAV.

Each command reads from a **local RTL-SDR** (just give a frequency), an **`rtl_tcp`**
network server, or a **recorded IQ file**. Verified over the air on both macOS and a
Raspberry Pi 4 — a blind band sweep + `scan` locates a live 67 kHz SCA, which `play`
and `rec` then decode to intelligible audio, drop-free in real time.

## Requirements

- **Zig 0.16+** — macOS: `brew install zig`.
- **librtlsdr** — required to build (the program links against it).
  - macOS: `brew install librtlsdr`
  - Debian / Raspberry Pi OS: `apt install librtlsdr-dev` (or build from source)
  - Found on the default search path on Linux; via `brew --prefix` on macOS.
- libc, plus the CoreAudio/AudioToolbox frameworks on macOS for live playback (wired
  automatically in `build.zig`). [miniaudio](https://miniaud.io) is fetched by the
  package manager (`build.zig.zon`) — nothing to install.
- An **RTL-SDR dongle** for live use; files need no hardware. To drive a radio on
  another host, run `rtl_tcp -a 0.0.0.0 -f <freq> -s 1024000` there and pass `--rtl-tcp`.

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

`<input>` is auto-detected: a frequency (`89.9M`, `89900000`) tunes a radio — a local
RTL-SDR by default, or an `rtl_tcp` server with `--rtl-tcp`; anything else is treated
as a recorded IQ file path.

```sh
rtl-sca scan 89.9M                                           # survey a station live off a local dongle
rtl-sca play 89.9M --sub 67k                                 # demodulate the 67 kHz SCA live
rtl-sca rec  89.9M --sub 67k -o out.wav                      # record the SCA to a WAV (Ctrl-C to stop)
rtl-sca scan capture.cu8                                     # survey a recorded IQ file instead
rtl-sca play capture.cu8 --sub 0 --bw 15k --deemph 75us      # play a capture's mono program
rtl-sca play 89.9M --rtl-tcp 192.168.1.50:1234 --sub 0       # drive a remote radio over rtl_tcp
```

Live commands run until Ctrl-C (which finalizes the WAV). `--rtl-tcp` takes an
`IP:port` (numeric IP); the positional `<input>` is then the tune frequency. Use
`--device N` to pick among multiple local dongles.

The **main program audio is the slot at 0 Hz**: `--sub 0` (with ~15 kHz bandwidth and
75 µs de-emphasis) recovers normal mono FM. It's supported as a validation/utility
mode — if the station is audible, the front-end and FM demod are proven before
chasing a weak subcarrier.

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
| `--audio-rate HZ` | output audio rate (resampled to any rate) | `48k`¹ |
| `--gain DB` | tuner gain (radio only) | auto |
| `--device N` | USB dongle index (radio only) | `0` |
| `--ppm N` | crystal correction in ppm (radio only) | `0` |
| `-o FILE` | output WAV path (`rec`) | — |
| `-v`, `-vv` | diagnostics (see below) | off |

De-emphasis is a continuous time constant, not a fixed set. `150us` is the SCA
standard (the default); `75us` (US) and `50us` (EU) are the main-channel values;
`off` is no de-emphasis.

**Verbose.** `-v` prints the derived rate plan and a one-line health summary at exit
(DSP speed vs. real time, USB sample drops, audio underruns); in `scan` it also adds
per-slot classifier metrics. `-vv` logs that health line live (~every 2 s) so you can
watch for drops or underruns during a long capture.

¹ A rational resampler bridges the internal content rate to any output rate. Live
`play` defaults to the audio device's native rate; `rec`/files default to 48 kHz.

## Not yet

- RDS decode (57 kHz data subcarrier)
- Headless Raspberry Pi daemon
- Stereo (L−R) decode is out of scope — `--sub 0` recovers mono only.

## Project layout

- `src/main.zig` — entry point; wires the CLI to the pipeline.
- `src/cli.zig` — argument and subcommand parsing.
- `SPEC.md` — the design and signal-chain reference.
- `CLAUDE.md` — conventions for working in this repo (incl. Zig 0.16 notes).

## License

MIT — see [LICENSE](LICENSE).
