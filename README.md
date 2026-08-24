# FnWhisper

**English** | [简体中文](README.zh-CN.md)

FnWhisper is a voice-only macOS menu bar app. Hold `Fn` while speaking, release it, and on-device models make the local `whisper.cpp` transcript clearer, more concise, and better structured before it is written into the original text field.

Audio and transcripts never leave the Mac. Internet access is needed only to install `whisper.cpp` / `llama.cpp`, download the Whisper, CT-Punc, and Qwen models, and fetch pinned static inference libraries during the first build; normal use works offline afterward.

## README index

- [Quick installation](#quick-installation): go from a new Mac to a runnable app, including source, dependencies, and models.
- [What gets installed](#what-gets-installed): Homebrew packages, three local models, system-model behavior, and file locations.
- [Step-by-step installation](#step-by-step-installation): run every setup stage and core tests before installation.
- [First-launch permissions](#first-launch-permissions): Input Monitoring, Accessibility, and Microphone access.
- [Verify the installation](#verify-the-installation): check permissions, models, signing, and the running process.
- [Upgrade](#upgrade): safely rebuild and replace the local app after pulling new code.
- [Usage](#usage): hold Fn to dictate into the current field.
- [Development and verification](#development-and-verification): developer checks and real-model diagnostics.

If you only want to install the app, start with [Quick installation](#quick-installation).

## Current behavior

- Hold Fn for 350 ms to start recording; a short press does nothing.
- While the app is running, it consumes Fn press and release events so macOS Globe, emoji, input-source, or dictation actions cannot take over. Other modifier keys continue to work.
- Releasing Fn stops recording and starts local transcription.
- A non-activating floating HUD shows listening and local transcription without stealing focus. On completion it shows only one marker that is never inserted into the text: `Ⓠ` for Qwen, `Ⓐ` for Apple, `Ⓦ` when the Whisper/normalized result is kept, or `⌘` for command/code passthrough.
- The active text control is captured when recording starts, so the result returns to the same field even if focus changes later. Recording is rejected immediately when the current focus is not editable.
- macOS Terminal is supported: its `AXTextArea` is treated as editable even when Accessibility cannot set its value directly, and Cmd+V writes into the command line.
- Whisper automatically detects Chinese or English and preserves mixed Chinese-English speech. The output policy accepts only Chinese, English, mixed text, and punctuation.
- Prose fields use the local `sherpa-onnx` bilingual CT-Punc INT8 model for semantic punctuation. Terminal and common IDE/code-editor targets use command mode: CT-Punc and automatic sentence endings are bypassed so commands and code stay intact.
- Chinese, English, and mixed prose is organized without changing its meaning: filler and stutters are removed, hotwords and spoken numbers are normalized, explicit corrections are applied, and reliably signaled parallel tasks, steps, or requirements become numbered lists—even when they are introduced only by cues such as “then”, “also”, or “finally”. The models must not translate, answer, or invent information.
- Local `Qwen3-4B-Instruct-2507 Q4_K_M` runs through `llama-server` in fast/non-thinking mode in parallel with Apple Foundation Models. A valid Qwen result wins within an adaptive 3–5 second request window based on transcript length; otherwise the already-running Apple result is used. If both fail validation, the deterministically normalized, punctuated transcript is preserved.
- The default model is the full-architecture quantized `large-v3-q5_0`, running on Apple Metal GPU. The app warms a `whisper-server` bound only to `127.0.0.1`, so consecutive utterances do not reload the model. A failed Metal service visibly falls back to CPU, then to the slower one-shot `whisper-cli` if the service is unavailable.
- Text insertion first refocuses the captured control and sends Cmd+V for web and Electron compatibility, then falls back to the Accessibility API when needed. The original clipboard is restored afterward.
- The menu bar icon reports ready, recording, transcribing, and error states. The complete processing path remains available in the menu bar tooltip during completion and in local logs.
- The app does not read typed content, keep recordings, or call a cloud speech API.

## Requirements

- macOS 13 or later. Apple Silicon is verified; Intel has not been tested on physical hardware.
- Apple Command Line Tools (`swift`) and Homebrew.
- About 1.01 GiB for Whisper, 72 MiB for CT-Punc INT8, and 2.33 GiB for Qwen, plus Homebrew runtime dependencies. Allow about 4.66 GiB of free space while the Qwen download is being verified and installed.

## Quick installation

This is the recommended entry point for a new machine. The installer supports macOS only; Apple Silicon is the currently verified architecture.

### 1. Install the one-time prerequisites

Install Apple Command Line Tools:

```bash
xcode-select --install
```

Install Homebrew from [brew.sh](https://brew.sh), then confirm both tools are available:

```bash
xcode-select -p
brew --version
```

### 2. Clone and run the complete installer

```bash
git clone https://github.com/Marshall-Qiao/FnWhisper.git
cd FnWhisper
./scripts/bootstrap-machine.sh
```

`bootstrap-machine.sh` performs these steps in order:

1. installs `whisper-cpp` and `llama.cpp` from `Brewfile`;
2. downloads and verifies the local Whisper, CT-Punc, and Qwen models;
3. lets Swift Package Manager fetch pinned sherpa-onnx and ONNX Runtime static libraries;
4. builds, signs, and installs `~/Applications/FnWhisper.app`;
5. backs up the old app, stops its helper processes, and launches the new app.

The script is safe to rerun. Existing models with valid checksums are not downloaded again.

## What gets installed

### Code and runtime dependencies

| Component | Purpose | Source/install method |
| --- | --- | --- |
| Apple Swift, AppKit, AVFoundation | App compilation, microphone recording, and menu bar UI | Apple Command Line Tools / macOS |
| `whisper-cli`, `whisper-server` | Local speech recognition with CLI fallback | Homebrew `whisper-cpp` |
| `llama-server` | Runs the local Qwen text-refinement model | Homebrew `llama.cpp` |
| sherpa-onnx 1.13.5 | Local bilingual CT-Punc punctuation restoration | Pinned SwiftPM static XCFramework |
| ONNX Runtime 1.27.1 | Executes the CT-Punc ONNX model | Pinned SwiftPM static XCFramework |

### Local models

| Model | Purpose | Size | Default location |
| --- | --- | ---: | --- |
| `ggml-large-v3-q5_0.bin` | Whisper Chinese, English, and mixed-speech recognition | About 1.01 GiB | `~/Library/Application Support/FnWhisper/Models/ggml-large-v3-q5_0.bin` |
| `model.int8.onnx` | sherpa-onnx bilingual CT-Punc punctuation | About 72 MiB | `~/Library/Application Support/FnWhisper/Models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx` |
| `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | Local fast/non-thinking text refinement | About 2.33 GiB | `~/Library/Application Support/FnWhisper/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` |

Each model setup script verifies a pinned checksum before writing the final file. The Qwen download and installation briefly keep two copies, so allow at least 4.66 GiB of free space for that stage, plus additional space for Whisper, CT-Punc, Homebrew packages, and build caches.

Apple Foundation Models is not downloaded by this project. It is an optional macOS 26 system capability. If it is unavailable, FnWhisper can still use local Qwen or keep the transcript after Whisper, punctuation, and deterministic normalization.

The primary installed files are:

```text
~/Applications/FnWhisper.app
~/Library/Application Support/FnWhisper/Models/ggml-large-v3-q5_0.bin
~/Library/Application Support/FnWhisper/Models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx
~/Library/Application Support/FnWhisper/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

See the [verified deployment machine configuration](docs/DEPLOYMENT_MACHINE.md) for pinned hashes, verified software versions, and the reference hardware.

## Step-by-step installation

To inspect each dependency, model, and test stage separately, run:

```bash
brew bundle --file Brewfile
./scripts/setup-whisper.sh large-v3-q5_0
./scripts/setup-punctuation.sh
./scripts/setup-qwen.sh
./scripts/test.sh
./scripts/install.sh
```

Script responsibilities:

| Script | Responsibility |
| --- | --- |
| `scripts/setup-whisper.sh` | Installs/checks `whisper.cpp`, then downloads and verifies the selected Whisper model |
| `scripts/setup-punctuation.sh` | Downloads, extracts, and verifies the CT-Punc INT8 model |
| `scripts/setup-qwen.sh` | Checks required `llama-server` flags, then downloads and verifies Qwen GGUF from a pinned revision |
| `scripts/test.sh` | Runs the standalone Swift core tests without XCTest |
| `scripts/build-app.sh` | Produces a Release build, assembles the app, bundles licenses, and verifies code signing |
| `scripts/install.sh` | Builds, backs up and replaces the old app, stops old helpers, and launches the new app |

The default install directory is `~/Applications`. Developers may set `FNWHISPER_INSTALL_DIR` before installation to select another destination; `FNWHISPER_APP_SUPPORT_DIR` changes the model root.

## First-launch permissions

After the first launch, allow these permissions under System Settings → Privacy & Security:

1. Input Monitoring;
2. Accessibility;
3. Microphone, requested the first time Fn is held.

These permissions belong to the current macOS user and cannot be granted by the installer. After granting access, click the waveform menu bar icon and choose “检查权限与运行环境” (Check permissions and runtime). Quit and reopen the app once if macOS requests it.

If permissions repeatedly appear unauthorized after upgrading an older ad-hoc build, run once:

```bash
tccutil reset All com.marshall.fnwhisper
./scripts/install.sh
```

Then grant the permissions again. Local builds use a stable designated requirement so rebuilding does not invalidate TCC authorization when the executable hash changes. For formal distribution, set `FNWHISPER_SIGN_IDENTITY` to an Apple Development or Developer ID Application identity.

## Verify the installation

After granting permissions, run:

```bash
# Check dependencies, all three models, and current permissions; missing permissions return a nonzero status
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --diagnose

# Verify app signing
codesign --verify --deep --strict ~/Applications/FnWhisper.app

# Confirm that the app is running
pgrep -fl '/FnWhisper.app/Contents/MacOS/FnWhisper'
```

Finish with a real end-to-end check in any prose field: leave the caret visible, hold Fn while speaking Chinese, English, or mixed speech, release it, and confirm the text returns to the same field.

## Upgrade

From a clean worktree, update the source and rerun the complete installer:

```bash
git pull --ff-only
./scripts/bootstrap-machine.sh
```

The installer moves the current app to a timestamped `FnWhisper.app.backup-*` in the same directory before installing and launching the new build. Models with valid checksums are not downloaded again. Upgrading does not commit, push, or delete files from the source worktree.

## Usage

1. Click an editable text location and leave the caret there.
2. Hold Fn and start speaking after the menu bar icon changes to a microphone.
3. Release Fn and wait for the icon to return to a waveform; the text appears in the original field.

An editable caret must be visible when recording starts. You may switch windows during transcription; FnWhisper still prioritizes the field captured at recording start. Password fields and other secure input areas reject Accessibility insertion by design.

## End-to-end flow

1. `FnKeyMonitor` observes global Fn events and activates after a 350 ms hold; short presses do not record.
2. The current editable control and owning application are captured so the result can return to the original location.
3. `AudioRecorder` records the microphone and converts the result on release to 16 kHz, mono, 16-bit PCM WAV.
4. `WhisperRuntime` sends the WAV to a resident `whisper-server` on the local loopback interface, using `large-v3-q5_0` and Metal. Failure handling is explicit: resident CPU, then one-shot CLI compatibility mode.
5. Prose targets restore punctuation with CT-Punc, apply deterministic filler, hotword, and spoken-number normalization, then request local Qwen fast mode and Apple Foundation Models concurrently. The Qwen timer starts only after speech, Whisper transcription, and punctuation are complete: short, medium, and long transcripts receive 3, 4, or 5 seconds respectively. A valid Qwen result wins within that window; otherwise Apple is used. If neither result passes structural and semantic checks, the deterministically normalized, punctuated transcript is kept.
6. Terminal/IDE targets bypass both punctuation and text refinement so commands and code remain unchanged. Both paths reject scripts other than Chinese and English.
7. `TextInjector` locates the original field, prefers Cmd+V, falls back to Accessibility when necessary, restores the original clipboard, and deletes the temporary recording.

All audio and model inference remain local. See [Architecture](docs/ARCHITECTURE.md) for module boundaries, permission rationale, and failure handling.

## Latency and accuracy trade-offs

The following measurements were taken locally on the reference Apple M4 Pro machine with a 12-core CPU, 16-core GPU, and 48 GiB memory. Times exclude the time spent speaking.

| Choice | Measurement or impact | Trade-off |
| --- | --- | --- |
| Resident Metal with `large-v3-q5_0` | 6.95 s Chinese sample: 2.967–3.206 s across cold first requests and 1.949–1.999 s for warm requests in the same process | Current default; the first request may include warm-up, while consecutive input is about 2 s |
| One-shot CLI Metal with `large-v3-q5_0` | 3.03 s for an 11 s English sample | Compatibility path when the resident service is unavailable; reloads the model for every utterance |
| 8-thread CPU with `large-v3-q5_0` | 12.60 s for the same English sample | Suitable when Metal is unavailable; substantially higher CPU use and latency |
| CPU thread count | Mixed sample: 16.97 s at 4 threads, 12.34 s at 8, and 12.46 s at 10 | Eight threads were fastest on the reference Mac; more threads were not faster, and all three outputs matched |
| `large-v3-q5_0` | 1,081,140,203 bytes, about 1.01 GiB | Current accuracy-first default; higher disk use and model-load cost |
| `large-v3-turbo-q5_0` | 574,041,195 bytes, about 548 MiB | Smaller and generally faster, but may lose accuracy on accents, noise, and mixed Chinese-English speech; this project has not assigned an error-rate number without a real user-voice benchmark |
| Bilingual CT-Punc INT8 | 75,519,198 bytes, about 72 MiB; 0.08 s total for a cold standalone test sentence | Runs only on final text and adds little beside Whisper inference; punctuation is more natural than basic segment heuristics, but question marks and commas can still be misclassified |
| Qwen3-4B-Instruct-2507 Q4_K_M fast mode | 2,497,281,120 bytes; 1.5–2.7 s to warm and 0.18–1.31 s across the 27-case warm corpus | Default text refiner; resident and local, with thinking disabled and a transcript-length-based 3–5 s fallback window |
| Apple Foundation Models fallback | Current end-to-end samples completed in about 0.9–1.7 s | Fast fallback on macOS 26 when the system model is available; the same structural and semantic checks still apply |

The 350 ms Fn threshold trades accidental activations against responsiveness and can be changed with `holdMilliseconds`. The resident Whisper process removes repeated model loading, but keeps more than 1 GiB of model memory while the app is running; quitting the app synchronously stops the helper it launched. FnWhisper still performs one final full-utterance decode after Fn is released instead of inserting partial results while you speak, prioritizing accuracy and stable insertion over first-token latency.

## Development and verification

```bash
./scripts/test.sh
swift build
./scripts/build-app.sh
# Optional: exercise the real whisper-cli with a 16 kHz WAV
./scripts/smoke-test-whisper.sh /absolute/path/to/audio.wav
# Exercise consecutive resident Whisper requests and report backend/latency
.build/FnWhisper.app/Contents/MacOS/FnWhisper --test-whisper-runtime /absolute/path/to/audio.wav 3
# Exercise the real CT-Punc model
.build/FnWhisper.app/Contents/MacOS/FnWhisper --test-punctuation "hello this is a punctuation test"
# Exercise Qwen/Apple selection and report the provider and latency
.build/FnWhisper.app/Contents/MacOS/FnWhisper --test-text-refinement "um use cloud code to fix this bug"
# Inspect the installed app's effective permissions and runtime
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --diagnose
# Print raw Fn key codes for up to 15 seconds
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --probe-fn 15
# Test text insertion independently of recording and transcription
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --test-insert "FnWhisper input test"
```

The reference machine has Apple Command Line Tools rather than full Xcode, so core tests use a standalone Swift test runner. Coverage includes the Fn state machine, audio conversion, target classification, Whisper server protocol, CLI fallback arguments, punctuation normalization, spoken-number normalization, text-refinement validation, Qwen fast-mode arguments, and adaptive timeouts. `./scripts/build-app.sh` verifies the full Release link across AppKit, AVFoundation, sherpa-onnx, and ONNX Runtime. GitHub Actions runs automated checks on a `macos-26` arm64 runner.

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

# Select another local CT-Punc INT8 model
defaults write com.marshall.fnwhisper punctuationModelPath "/absolute/path/model.int8.onnx"

# Select another local Qwen GGUF model
defaults write com.marshall.fnwhisper textModelPath "/absolute/path/model.gguf"
```

During development, `FNWHISPER_LANGUAGE`, `FNWHISPER_HOLD_MS`, `FNWHISPER_THREADS`, `FNWHISPER_GPU`, `FNWHISPER_MODEL`, `FNWHISPER_TEXT_MODEL`, `FNWHISPER_PUNCTUATION_MODEL`, `FNWHISPER_LLAMA_SERVER`, `FNWHISPER_WHISPER_SERVER`, and `FNWHISPER_WHISPER_CLI` override the corresponding settings. Language accepts `auto`, `zh`, or `en`; other values fall back to `auto`, and final output is still limited to Chinese and English scripts. `FNWHISPER_GPU` accepts `true/false`, `1/0`, `yes/no`, or `on/off`.

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
- Terminal and common IDE/code-editor targets intentionally bypass CT-Punc. A terminal-like app not yet listed in the target classifier may need its bundle identifier added.
- Apple Foundation Models requires macOS 26 and an available system model. Qwen continues to work by itself when Apple is unavailable. A timed-out or semantically invalid Qwen result is never inserted; FnWhisper uses Apple or preserves the deterministically normalized, punctuated transcript.
- Temporary audio is deleted after transcription. A force-terminated process may leave an incomplete file in the system temporary directory for a short time.

See [Architecture](docs/ARCHITECTURE.md) for implementation trade-offs and permission boundaries.
