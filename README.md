# Desktop Companion

<img src="docs/mochi.png" width="160" alt="Mochi, the original desktop companion">

[简体中文](README.zh-CN.md) · English

A small native macOS desktop companion with a friendly original mascot, readable system information, and Apple Bluetooth accessory battery levels. Built with Swift and AppKit. The app works without an account, Python, or an AI model.

## What it does

- **Mochi**, an original companion drawn in code, with adjustable size and position.
- CPU/GPU use, readable temperature sensors, memory pressure, and available storage in a resizable window.
- Battery readings for supported Apple headphones, mice, keyboards, and trackpads, using the records macOS makes available.
- Optional hourly speech bubbles, hide/pause controls, and complete quit from the menu bar.
- Chinese and English interface settings.
- Experimental roaming, off by default. Roaming hides the input field and makes the pet ignore mouse clicks; switching it off restores your previous settings.
- Optional local Qwen3-1.7B text chat. Model files and their runtime are installed separately. Experimental Chinese push-to-talk transcription and system-voice reading remain optional; there is no wake-word listener.

## Requirements

| Feature | Requirement |
|---|---|
| Desktop companion and monitors | Apple Silicon Mac, macOS 14 or newer |
| Optional local text model | Apple Silicon, macOS 26 or newer, at least 3 GiB free space during optional installation |
| Experimental voice input | Microphone and speech-recognition permission, plus an available on-device recognizer |
| Build from source | Xcode Command Line Tools with a compatible macOS SDK |

There is no Intel release. Sensor and accessory support varies with the hardware and macOS version. Missing information is displayed as unavailable rather than estimated.

## Install

1. Download the Apple Silicon ZIP from [Releases](https://github.com/Bf190t/mac-desktop-companion/releases).
2. Extract it and move **Desktop Companion.app** into your Applications folder.
3. Launch the app. Use its **✿** menu-bar item to open settings, system information, or battery information.
4. Open **Settings → Language** to choose English or 简体中文.

The initial release is ad-hoc signed, **not signed with an Apple Developer ID or notarized by Apple**. A downloaded copy may trigger a Gatekeeper warning. Review the source and the release checksum before deciding whether to trust it. Apple documents the per-app “Open Anyway” procedure in [Safely open apps on your Mac](https://support.apple.com/en-us/102445). Building the app locally is another option. The project does not ask you to disable Gatekeeper or change system-wide security settings.

To stop the app, choose **Quit** from its menu-bar item. It does not install a login item or background service.

## Build and test

Install Apple's Command Line Tools if needed, then run:

```sh
git clone https://github.com/Bf190t/mac-desktop-companion.git
cd mac-desktop-companion
./scripts/build.sh
./scripts/test.sh
```

The result is `dist/Desktop Companion.app`. The default build includes no downloaded model, Python runtime, or user data. Build and test outputs stay outside the source files. See [development and validation notes](docs/DEVELOPMENT.md) for the checks and their limits.

## Optional local chat

The core app is useful without chat. If you choose to install the optional model, open **Local model · Status & debugging → Install optional chat model…**. Installation needs an internet connection; normal model inference is local and its worker process is denied network access.

- Model: [Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B), using the pinned [MLX community 4-bit conversion](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/tree/3b1b1768f8f8cf8351c712464f906e86c2b8269e).
- Model files total approximately **984 MB**. The tested complete installation uses about **1.42 GiB** including the Python runtime and dependencies; allow **3 GiB** free during installation.
- Files are downloaded and checked against the shipped version/hash manifests. They are stored in this app's own Application Support directory, not inside the signed app bundle.
- The model normally unloads after **120 seconds** without activity. A longer 30-minute residency is optional. Locking/sleep, app shutdown, or high memory pressure can unload it sooner.
- The conversation stays in memory. It is not a system-control agent: the model does not receive your computer metrics, accessory records, screen, or files, and it cannot execute actions.
- This is a small model. It can misunderstand, invent facts, or lose details from a long conversation; the prompt and output filters do not guarantee factual accuracy.

[Model and data details](docs/PRIVACY.md) explain the local data, permissions, and experimental voice behavior.

## Reading the numbers

CPU/GPU and temperature sampling runs while the status window is visible, with slower sampling under energy-saving conditions. Storage refreshes at most hourly unless you request a refresh. Memory pressure summarizes the observed portions of the last hour; time the app was suspended is not fabricated as green time.

Bluetooth values are **macOS's latest available records**, not a promise of continuous live telemetry. A closed earbud case or disconnected accessory may report an older value or no value. Temperature and GPU fields, and some accessory records, rely on non-public read-only interfaces that may change in a macOS update. The app does not control fans or install a privileged helper.

## Privacy, contribution, and license

There is no app analytics service or cloud chat backend. Downloading the optional component contacts its upstream hosting services. See [Privacy](docs/PRIVACY.md), [Security](SECURITY.md), and [Contributing](CONTRIBUTING.md).

The project's code and original Mochi artwork are under the [MIT License](LICENSE). Optional models and third-party components retain their own licenses; see [Third-party notices](THIRD_PARTY_NOTICES.md). This project is independent and is not endorsed by Apple or the model authors.
