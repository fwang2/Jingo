<div align="center">
  <a href="https://github.com/fwang2/Jingo">
    <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/ios-marketing.png" width="88" alt="Jingo icon">
  </a>

  <h1>Jingo</h1>

  <p><strong>Private, on-device bilingual transcription for Mac, iPhone, and iPad.</strong></p>
  <p>Jingo turns English, Chinese, and code-switched conversations into readable transcripts with speaker attribution—without uploading recordings to a transcription service.</p>
</div>

<p align="center">
  <img src="https://img.shields.io/badge/release-0.2-1685F8.svg" alt="Jingo 0.2">
  <img src="https://img.shields.io/badge/macOS-14%2B-1685F8.svg" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/iOS-18%2B-1685F8.svg" alt="iOS 18 or later">
  <img src="https://img.shields.io/badge/Xcode-27-blue.svg" alt="Tested with Xcode 27">
  <img src="https://img.shields.io/github/license/fwang2/Jingo?style=flat" alt="License">
</p>

<p align="center">
  <img src=".github/jingo-desktop.png" width="900" alt="Jingo for Mac showing a two-speaker transcript">
</p>

## What Jingo Does

- Defaults to low-latency English transcription on Mac with NVIDIA Parakeet Unified EN.
- Offers English-optimized Qwen3-ASR and Whisper Large-v3-Turbo alternatives on Mac, while the iPhone and iPad pipeline retains English, Chinese, and mixed-language transcription.
- Supports optional hands-free listening on Mac so transcription can start automatically while Jingo is running.
- Separates conversations into timestamped speaker turns with FluidAudio diarization.
- Keeps live transcription lightweight, then offers a separate full-recording offline pass for improved alignment and speaker attribution.
- Learns known speakers from conversations or dedicated voice samples, then recognizes them in later recordings.
- Creates structured meeting summaries locally on Mac, including findings, decisions, unresolved items, participant contributions, actions, risks, and meeting status.
- Keeps recordings, transcripts, voice profiles, and model inference on the device.
- Optionally backs up Mac settings and recordings through a cloud-synced folder you control.
- Provides a native Mac workspace alongside the iPhone and iPad experience.

Speaker diarization and speaker identification are different stages: diarization determines *who spoke when* within a recording, while a saved voice profile gives that speaker a persistent name across recordings.

## Two Device-Appropriate Pipelines

Jingo does not make the mobile app pay the memory cost of the desktop pipeline, or limit the Mac to mobile-scale processing.

| Platform | Transcription | Speaker processing | Meeting summaries |
| --- | --- | --- | --- |
| Mac | Parakeet Unified EN by default; selectable Qwen3-ASR 1.7B, 4-bit or Whisper Large-v3-Turbo | Live checkpoints plus an explicit full-recording offline refinement action | Qwen3 4B Instruct, 4-bit |
| iPhone and iPad | Qwen3-ASR 0.6B, 4-bit | Resource-constrained sequential pipeline that unloads large auxiliary models between stages | Not currently available |

Both paths use Qwen forced alignment to place words on the timeline and FluidAudio to perform speaker diarization.

On Mac, Parakeet Unified EN is optimized for real-time English with punctuation and capitalization and is selected for new installations. The selectable Qwen and Whisper engines also constrain decoding to English for lower language-selection overhead and more stable English output. The iPhone and iPad Qwen pipeline remains multilingual.

For a saved Mac recording, choose **Transcribe Offline** or **Retranscribe Offline** from its actions menu. Jingo uses Whisper Large-v3-Turbo by default to reprocess the complete audio, performs bounded forced alignment and diarization, and replaces the live result. If speaker alignment is incomplete, Jingo keeps the complete raw transcript instead of displaying misleading partial speaker turns. Once text is available, the recording's **Transcript** link opens it in a tab beside the recordings list. The transcript records which model and audio source produced it. Manual speaker-name corrections stay attached to that transcript and take precedence over automatic voice matching.

## Privacy and Model Downloads

Audio and transcripts stay on the device by default. If you configure **Backup & Restore** on Mac, Jingo also writes the selected settings and recording backups to the cloud-synced folder you choose. Jingo downloads the selected open transcription model and its supporting speaker models the first time they are prepared; after that, transcription and speaker processing run locally. Switching Mac transcription engines may require an additional one-time download.

Known-speaker voice samples are stored locally. A sample needs at least six seconds of clear, single-speaker speech; recording 10–15 seconds is recommended.

## Local Meeting Summaries on Mac

Jingo creates a summary when you choose **Create Summary** from a recording's transcript tab. The separate Qwen3 4B Instruct model runs through MLX on Apple silicon and can be downloaded from **Settings → Meeting Summaries**.

Summary detail scales with the recording duration and transcript density. Brief recordings receive a correspondingly short result, while substantive meetings can include:

- key findings and confirmed decisions;
- unresolved, deferred, or rejected items;
- important participant contributions;
- explicitly assigned action items;
- material risks and follow-up questions;
- source-linked highlights and an overall meeting-status assessment.

The default summary prompt is editable Markdown. Settings provides separate **Edit** and **Preview** tabs, plus an option to restore the bundled default. Factual grounding, the structured result, and adaptive length limits remain enforced even when the prompt is customized.

## Backup & Restore on Mac

Jingo can synchronize supported preferences and recording backups through a cloud-synced shared folder. Open **Backup & Restore** and choose a parent location managed by iCloud Drive, Dropbox, Google Drive, OneDrive, or another service that exposes a folder in Finder. Jingo creates and uses a `Jingo` folder inside that location, so you do not need to create it yourself.

The selected location is confirmed once and remembered on that Mac. A connected card shows the active Jingo folder and its full path. This folder-based approach does not require a paid Apple Developer membership or a private iCloud app container.

Recording audio, transcripts, speaker details, and summaries can be backed up and restored manually. Automatic recording backup is opt-in and disabled by default. Backups are incremental; restores verify file integrity, skip recordings already on the Mac, and never overwrite existing local audio.

## Build and Run

### Requirements

- Apple silicon Mac
- macOS 14 or later
- Xcode 27 with the iOS 27 simulator runtime
- `make` and `curl`

The repository pins Tuist, SwiftLint, and SwiftFormat through `mise`; the setup command installs the declared versions.

```sh
git clone git@github.com:fwang2/Jingo.git
cd Jingo
make
open Jingo.xcworkspace
```

Open the generated `Jingo.xcworkspace`, not the `.xcodeproj`.

### Run the Mac app

1. Select the `JingoMac` scheme.
2. Choose **My Mac** as the destination.
3. Press **Run**.
4. In Jingo, prepare the selected transcription model and grant microphone access when macOS asks.

The Mac app defaults to Parakeet Unified EN. Open **Settings → Model** to select Qwen3-ASR or Whisper Large-v3-Turbo, or enable **Hands-free listening** to begin listening automatically while Jingo is running.

### Run on iPhone or iPad

1. Connect a physical device and select the `JingoDev` scheme.
2. Choose the device as the destination.
3. Press **Run** and grant microphone access.

The simulator is useful for interface and unit tests, but Qwen and FluidAudio integration inference requires a physical Apple device.

## Testing

The project includes model-independent unit tests, speaker attribution and execution-policy tests, physical-device inference tests, iOS snapshots, and Mac UI tests.

Run tests against the existing generated workspace with `xcodebuild test` or `mise exec -- tuist xcodebuild test`. Do not run `tuist test` in the working checkout: filtered test runs regenerate the workspace around the selected test graph and temporarily remove unrelated schemes such as `JingoMac`. If that happens, restore the complete workspace with:

```sh
mise exec -- tuist generate --no-open
```

For the Mac app:

```sh
xcodebuild -workspace Jingo.xcworkspace \
  -scheme JingoMac \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -workspace Jingo.xcworkspace \
  -scheme JingoMacUITests \
  -destination 'platform=macOS' test
```

The iOS test schemes can be run from Xcode with an iOS simulator. Tests that exercise MLX and FluidAudio inference are intentionally skipped unless they run on a compatible physical device.

## Toolchain

| Component | Version |
| --- | --- |
| Xcode | 27.0 |
| Swift compiler | 6.4 |
| Project Swift language mode | 5.10 |
| Minimum macOS deployment | 14.0 |
| Minimum iOS deployment | 18.0 |
| Tuist | 4.208.0 |
| SwiftLint | 0.65.1 |
| SwiftFormat | 0.63.0 |

## Project Lineage and Direction

Jingo began as a fork of [Saik0s/Whisperboard](https://github.com/Saik0s/Whisperboard), whose original work remains an important inspiration and foundation.

By version 0.2, little implementation lineage remains in the core transcription experience. Jingo now has its own Qwen-based ASR stack, FluidAudio speaker pipeline, device-specific execution policies, native Mac app, transcript interface, and known-speaker system. It is independently maintained and is not intended to track or merge back into Whisperboard.

Future development follows Jingo's own roadmap, prioritizing transcription quality, speaker identity, long-session reliability, and a coherent private workflow across desktop and mobile. Original authorship and license attribution remain preserved.

## License and Acknowledgements

Jingo is licensed under GPL-3.0. The bundled Poppins and Karla fonts are licensed under the SIL Open Font License.

Core projects and prior work:

- [Whisperboard](https://github.com/Saik0s/Whisperboard)
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)
- [NVIDIA NeMo / Parakeet](https://github.com/NVIDIA-NeMo/NeMo)
- [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [MLX Swift](https://github.com/ml-explore/mlx-swift)
- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
