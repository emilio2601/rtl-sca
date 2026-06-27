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

Working through the build phases (see Roadmap). `rec` decodes a recorded IQ file to a
WAV, `play` plays a subcarrier live — from a file or an `rtl_tcp` network server — out
the speakers, and `scan` surveys a station's MPX (pilot, subcarrier slots, modulation,
bandwidth, SNR). Validated end to end over the air: a blind band sweep + `scan` found a
live 67 kHz SCA on 92.3 MHz, which `rec` then decoded to intelligible audio.

## Requirements

- **Zig 0.16+** (`brew install zig`).
- Live playback links a small C shim over the vendored [miniaudio](https://miniaud.io)
  (`c/`); the build needs libc and, on macOS, the CoreAudio/AudioToolbox frameworks
  (wired automatically in `build.zig`).
- An RTL-SDR is only needed for live use. For the network source, run
  `rtl_tcp -a 0.0.0.0 -f <freq> -s 1024000` on the radio host.

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
rtl-sca scan capture.cu8                                      # survey the MPX: pilot, slots, mod, SNR
rtl-sca play capture.cu8 --sub 0 --bw 15k --deemph 75us       # play a capture's mono program
rtl-sca play capture.cu8 --sub 67k                            # play the 67 kHz SCA from a file
rtl-sca play 89.9M --rtl-tcp 192.168.1.50:1234 --sub 0        # play live from an rtl_tcp server
rtl-sca rec  89.9M --rtl-tcp 192.168.1.50:1234 --sub 67k -o out.wav   # record live to a WAV
rtl-sca rec  capture.cu8 --sub 67k -o gatewave.wav            # decode a capture to a WAV
```

Live commands run until Ctrl-C (which finalizes the WAV). `--rtl-tcp` takes an
`IP:port` (numeric IP); the positional `<input>` is then the tune frequency.

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
| `--audio-rate HZ` | output audio rate (resampled to any rate) | `48k`¹ |
| `--gain DB` | tuner gain (radio only) | auto |
| `--device N` | USB dongle index (radio only) | `0` |
| `--ppm N` | crystal correction in ppm (radio only) | `0` |
| `-o FILE` | output WAV path (`rec`) | — |
| `-v` | verbose: per-slot classifier metrics (`scan`) | off |

De-emphasis is a continuous time constant, not a fixed set. `150us` is the SCA
standard (the default); `75us` (US) and `50us` (EU) are the main-channel values;
`off` is no de-emphasis.

¹ A rational resampler bridges the internal content rate to any output rate. Live
`play` defaults to the audio device's native rate; `rec`/files default to 48 kHz.

## Roadmap

| Phase | Scope | |
|-------|-------|---|
| 1 | Offline MVP: file source → FM demod → 67 kHz FM subcarrier → de-emphasis → WAV | ✅ |
| 2 | Live: `rtl_tcp` network source + audio playback via miniaudio (USB source deferred) | ✅ |
| 4 | `scan` survey mode: PSD, pilot/slot detection, AM-vs-FM classification, SNR | ✅ |
| 3 | AM demod paths (`am-env`, `am-coherent` Costas); configurable `--mod` | ✅ |
| — | `UsbSource` (local librtlsdr) — deferred; Pi + `rtl_tcp` covers live | |
| — | Arbitrary-rate resampler (`--audio-rate`, any output rate) | ✅ |
| 5 | Stretch: RDS decode, headless Pi daemon | |

## Project layout

- `src/main.zig` — entry point; wires the CLI to the pipeline.
- `src/cli.zig` — argument and subcommand parsing.
- `SPEC.md` — source of truth for the design and build phases.
- `CLAUDE.md` — conventions for working in this repo (incl. Zig 0.16 notes).

## License

MIT — see [LICENSE](LICENSE).
