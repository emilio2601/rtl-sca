# rtl-sca

A command-line tool to detect, demodulate, and play back FM broadcast **subcarriers**
(SCA) from an RTL-SDR. Written in Zig.

US FM stations carry more than the stereo program: above the audible 0–53 kHz region,
the composite MPX baseband often hides narrowband audio subcarriers — commonly at
**67 kHz** and **92 kHz** (reading services for the blind, background music, niche
broadcasts). `rtl-sca` recovers the FM main carrier, reaches into a chosen subcarrier
slot, demodulates it (FM or AM), and plays it back or writes a WAV.

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
  another host, run `rtl_tcp -a 0.0.0.0 -f <freq> -s 1024000` there and pass `--remote`.

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

`<input>` auto-detects: a frequency (`89.9M`, `89900000`) tunes a radio — local by
default, or an `rtl_tcp` server with `--remote`; anything else is a recorded IQ file.
Live commands run until Ctrl-C (which finalizes the WAV).

```sh
rtl-sca scan 89.9M                                      # survey a station's MPX for subcarriers
rtl-sca play 89.9M --sub 67k                            # demodulate the 67 kHz SCA live
rtl-sca rec  89.9M --sub 67k -o out.wav                 # record the SCA to a WAV
rtl-sca play 89.9M --sub 0 --bw 15k --deemph 75us       # main mono program (a quick front-end check)
rtl-sca scan capture.cu8                                # survey a recorded IQ file
rtl-sca play 89.9M --remote raspberrypi.local --sub 67k # drive a remote radio over rtl_tcp
```

| flag | meaning | default |
|------|---------|---------|
| `--sub HZ` | subcarrier center (`67k`, `92k`, …); `0` = main channel | `67k` |
| `--bw HZ` | bandwidth recovered (slot width for a subcarrier, ±bw/2 → audio) | `8k` |
| `--mod MODE` | `fm` \| `am-env` \| `am-coherent` | `fm` |
| `--deemph TAU` | de-emphasis time constant (`150us`, `75us`, `off`, …) | `150us` |
| `--remote H[:PORT]` | tune over an `rtl_tcp` server (IP or hostname) | — |
| `--gain DB` | tuner gain (radio only) | auto |
| `-o FILE` | output WAV path (`rec`); `-` streams to stdout | — |
| `-v`, `-vv` | diagnostics to stderr | off |

Run `rtl-sca` with no command for the full flag list. **See [GUIDE.md](GUIDE.md)** for
the details — bandwidth semantics, de-emphasis, output streams, diagnostics, and
operating notes (gain/overload, the tune-in transient, rtl_tcp behavior).

## Project layout

- `src/main.zig` — entry point; wires the CLI to the pipeline.
- `src/cli.zig` — argument and subcommand parsing.
- [`GUIDE.md`](GUIDE.md) — full usage reference and operating notes.
- [`SPEC.md`](SPEC.md) — original design notes & signal-chain reference (Carson
  bandwidth, de-emphasis, the rate chain). The shipped code is now authoritative;
  kept for DSP background and rationale.
- `CLAUDE.md` — conventions for working in this repo (incl. Zig 0.16 notes).

## License

MIT — see [LICENSE](LICENSE).
