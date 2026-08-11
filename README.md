# FnWhisper

**English** | [简体中文](README.zh-CN.md)

FnWhisper is a voice-only macOS menu bar app. Hold `Fn` while speaking, release it, and local `whisper.cpp` transcription is written directly into the text field that was active when recording began.

Audio and transcripts never leave the Mac. An internet connection is needed only for the initial `whisper.cpp` installation and model download; normal use works offline afterward.

## Current behavior

- Hold Fn for 350 ms to start recording; a short press does nothing.
- While the app is running, it consumes Fn press and release events so macOS Globe, emoji, input-source, or dictation actions cannot take over. Other modifier keys continue to work.
- Releasing Fn stops recording and starts local transcription.
- A non-activating floating HUD shows listening, local transcription, result preview, and error states without stealing focus.
- The active text control is captured when recording starts, so the result returns to the same field even if focus changes later. Recording is rejected immediately when the current focus is not editable.
- macOS Terminal is supported: its `AXTextArea` is treated as editable even when Accessibility cannot set its value directly, and Cmd+V writes into the command line.
- Whisper automatically detects Chinese or English and preserves mixed Chinese-English speech. The output policy accepts only Chinese, English, mixed text, and punctuation.
- Whisper segment boundaries are preserved as natural pauses, punctuation next to Chinese text is normalized, and a missing final Chinese sentence mark is restored before insertion. English-only output is not force-punctuated so terminal commands and code remain unchanged.
- The default model is the full-architecture quantized `large-v3-q5_0`, running on Apple Metal GPU. If Metal is unavailable in a restricted environment, that transcription automatically retries on CPU without losing the recording.
- Text insertion first refocuses the captured control and sends Cmd+V for web and Electron compatibility, then falls back to the Accessibility API when needed. The original clipboard is restored afterward.
- The menu bar icon reports ready, recording, transcribing, and error states.
- The app does not read typed content, keep recordings, or call a cloud speech API.

## Requirements

- macOS 13 or later. Apple Silicon is verified; Intel has not been tested on physical hardware.
- Apple Command Line Tools (`swift`) and Homebrew.
- About 1.1 GiB for the initial model, plus a small amount of space for `whisper-cpp`.

## Installation

```bash
git clone https://github.com/Marshall-Qiao/FnWhisper.git
cd FnWhisper
./scripts/setup-whisper.sh large-v3-q5_0
./scripts/install.sh
```

On a new Mac, `./scripts/bootstrap-machine.sh` installs runtime dependencies from `Brewfile`, downloads and verifies `large-v3-q5_0`, then builds and installs the app. See the [verified deployment machine configuration](docs/DEPLOYMENT_MACHINE.md) for the current reference environment.

The app is installed to `~/Applications/FnWhisper.app` and launched. On first launch, allow these permissions under System Settings → Privacy & Security:

1. Input Monitoring;
2. Accessibility;
3. Microphone, requested the first time Fn is held.

After granting access, click the waveform menu bar icon and choose “检查权限与运行环境” (Check permissions and runtime). Quit and reopen the app once if macOS requests it.

If permissions repeatedly appear unauthorized after upgrading an older ad-hoc build, run once:

```bash
tccutil reset All com.marshall.fnwhisper
./scripts/install.sh
```

Then grant the permissions again. Local builds use a stable designated requirement so rebuilding does not invalidate TCC authorization when the executable hash changes. For formal distribution, set `FNWHISPER_SIGN_IDENTITY` to an Apple Development or Developer ID Application identity.

## Usage

1. Click an editable text location and leave the caret there.
2. Hold Fn and start speaking after the menu bar icon changes to a microphone.
3. Release Fn and wait for the icon to return to a waveform; the text appears in the original field.

An editable caret must be visible when recording starts. You may switch windows during transcription; FnWhisper still prioritizes the field captured at recording start. Password fields and other secure input areas reject Accessibility insertion by design.

## End-to-end flow

1. `FnKeyMonitor` observes global Fn events and activates after a 350 ms hold; short presses do not record.
2. The current editable control and owning application are captured so the result can return to the original location.
3. `AudioRecorder` records the microphone and converts the result on release to 16 kHz, mono, 16-bit PCM WAV.
4. `WhisperTranscriber` calls the local `whisper-cli` with `large-v3-q5_0` and Metal GPU; a failed GPU process is retried on CPU.
5. The output parser restores punctuation at Whisper segment boundaries, normalizes Chinese punctuation, and then rejects scripts other than Chinese and English.
6. `TextInjector` locates the original field, prefers Cmd+V, falls back to Accessibility when necessary, restores the original clipboard, and deletes the temporary recording.

All audio and model inference remain local. See [Architecture](docs/ARCHITECTURE.md) for module boundaries, permission rationale, and failure handling.

## Latency and accuracy trade-offs

The following measurements were taken locally on the reference Apple M4 Pro machine with a 12-core CPU, 16-core GPU, and 48 GiB memory. Times include each `whisper-cli` process startup and model load, but not the time spent speaking.

| Choice | Measurement or impact | Trade-off |
| --- | --- | --- |
| Metal GPU with `large-v3-q5_0` | 3.03 s for an 11 s English sample | Current default; identical output to CPU on this sample and about 4.2× faster |
| 8-thread CPU with `large-v3-q5_0` | 12.60 s for the same English sample | Suitable when Metal is unavailable; substantially higher CPU use and latency |
| CPU thread count | Mixed sample: 16.97 s at 4 threads, 12.34 s at 8, and 12.46 s at 10 | Eight threads were fastest on the reference Mac; more threads were not faster, and all three outputs matched |
| `large-v3-q5_0` | 1,081,140,203 bytes, about 1.01 GiB | Current accuracy-first default; higher disk use and model-load cost |
| `large-v3-turbo-q5_0` | 574,041,195 bytes, about 548 MiB | Smaller and generally faster, but may lose accuracy on accents, noise, and mixed Chinese-English speech; this project has not assigned an error-rate number without a real user-voice benchmark |

The 350 ms Fn threshold trades accidental activations against responsiveness and can be changed with `holdMilliseconds`. The current design launches one CLI process per utterance. This keeps state simple, isolates failures, and releases model memory after each result, but even short utterances pay model-loading latency. A persistent model service could reduce repeated-input latency, at the cost of keeping more than 1 GiB of memory resident and adding process recovery and upgrade complexity.

## Development and verification

```bash
./scripts/test.sh
swift build
./scripts/build-app.sh
# Optional: exercise the real whisper-cli with a 16 kHz WAV
./scripts/smoke-test-whisper.sh /absolute/path/to/audio.wav
# Inspect the installed app's effective permissions and runtime
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --diagnose
# Print raw Fn key codes for up to 15 seconds
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --probe-fn 15
# Test text insertion independently of recording and transcription
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --test-insert "FnWhisper input test"
```

The reference machine has Apple Command Line Tools rather than full Xcode, so core tests use a standalone Swift test runner. Coverage includes the Fn hold state machine, event-conflict handling, 48 kHz stereo to 16 kHz mono WAV conversion, Whisper output cleanup, and backend argument selection. `swift build` verifies the full AppKit and AVFoundation target. GitHub Actions runs the same checks on a `macos-26` arm64 runner.

## Configuration

Apps launched from Finder can be configured with `defaults`:

```bash
# Automatically detect Chinese or English and preserve mixed speech
defaults write com.marshall.fnwhisper language auto

# Or explicitly pin one language
defaults write com.marshall.fnwhisper language en
defaults write com.marshall.fnwhisper language zh

# Fn hold threshold in milliseconds, clamped to 150–2000
defaults write com.marshall.fnwhisper holdMilliseconds 450

# Whisper CPU threads; eight were fastest on the reference M4 Pro
defaults write com.marshall.fnwhisper threadCount 8

# Metal is enabled by default; false forces CPU-only transcription
defaults write com.marshall.fnwhisper useGPU true

# Select another local GGML model
defaults write com.marshall.fnwhisper modelPath "/absolute/path/ggml-small.bin"
```

During development, `FNWHISPER_LANGUAGE`, `FNWHISPER_HOLD_MS`, `FNWHISPER_THREADS`, `FNWHISPER_GPU`, `FNWHISPER_MODEL`, and `FNWHISPER_WHISPER_CLI` override the corresponding settings. Language accepts `auto`, `zh`, or `en`; other values fall back to `auto`, and final output is still limited to Chinese and English scripts. `FNWHISPER_GPU` accepts `true/false`, `1/0`, `yes/no`, or `on/off`.

Available model downloads:

```bash
./scripts/setup-whisper.sh large-v3-turbo-q5_0
./scripts/setup-whisper.sh large-v3-q5_0
./scripts/setup-whisper.sh tiny
./scripts/setup-whisper.sh base
./scripts/setup-whisper.sh small
./scripts/setup-whisper.sh medium
```

After downloading another model, point `modelPath` to its file. Larger models generally improve Chinese accuracy while increasing latency, memory use, and storage.

## Known limitations

- Some external keyboards and remapping tools do not expose a distinct Fn flag to macOS, so FnWhisper cannot use those keys as a trigger.
- If a remapping utility handles Fn before the CGEvent layer, disable that mapping for FnWhisper to receive the event.
- FnWhisper suppresses the native macOS short-press Fn action while running; quitting the app restores it immediately.
- The current interaction records while held and transcribes the complete utterance after release. It does not stream partial text while speaking.
- Temporary audio is deleted after transcription. A force-terminated process may leave an incomplete file in the system temporary directory for a short time.

See [Architecture](docs/ARCHITECTURE.md) for implementation trade-offs and permission boundaries.
