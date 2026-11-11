# Third-party notices

The repository's root MIT license covers its own code and original procedural Mochi artwork. It does not replace licenses for models, downloaded dependencies, system frameworks, or third-party material listed here.

## Stats: system monitoring references

The monitoring code uses independently implemented, read-only access informed by the GPU registry fields, SMC protocol, sensor-key mapping, and Bluetooth field names documented in [Stats](https://github.com/exelban/stats).

- Upstream author: **Serhiy Mytrovtsiy**.
- License: MIT, **Copyright (c) 2019 Serhiy Mytrovtsiy**.
- Full retained license: [docs/licenses/Stats-MIT.txt](docs/licenses/Stats-MIT.txt).
- References: [GPU reader](https://github.com/exelban/stats/blob/master/Modules/GPU/reader.swift), [sensor mapping](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift), [SMC interface](https://github.com/exelban/stats/blob/master/SMC/smc.swift), and [Bluetooth reader](https://github.com/exelban/stats/blob/master/Modules/Bluetooth/readers.swift).

The app does not bundle or run Stats, its updater, fan controller, or privileged helpers.

## Qwen3-1.7B: optional model

- Base model: [Qwen/Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B).
- Conversion: [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/tree/3b1b1768f8f8cf8351c712464f906e86c2b8269e).
- Pinned conversion revision: `3b1b1768f8f8cf8351c712464f906e86c2b8269e`.
- License: Apache License 2.0. Full text and the upstream Alibaba Cloud copyright notice are retained in [chat/MODEL-LICENSE.txt](chat/MODEL-LICENSE.txt).
- Downloaded files are listed and hashed in [chat/model-manifest.json](chat/model-manifest.json).

The project does not train or modify the model weights. The companion persona and output formatting are application behavior, separate from the upstream model. No weights are included in the source repository or the base app release.

## Qwen3-TTS: optional reading voice

- Base model: [Qwen/Qwen3-TTS-12Hz-0.6B-Base](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base).
- Conversion: [mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit/tree/50f45ef0047cde7e84c2ef04326acb8ada2436a7), pinned revision `50f45ef0047cde7e84c2ef04326acb8ada2436a7`.
- License: Apache License 2.0; full text in [voice/MODEL-LICENSE.txt](voice/MODEL-LICENSE.txt). Downloaded files are listed and hashed in [voice/model-manifest.json](voice/model-manifest.json).
- [voice/companion_voice.wav](voice/companion_voice.wav) (7 s) was generated once from a text description with [mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit) (Apache 2.0); its description, seed and text are in [voice/companion_voice.json](voice/companion_voice.json). It is synthetic and is released with this project under the MIT license as part of Mochi's original design.
- The reading-voice packages are hash-locked in [voice/requirements-lock.txt](voice/requirements-lock.txt), including [mlx-audio](https://github.com/Blaizzy/mlx-audio) (MIT); [voice/THIRD-PARTY-NOTICES.txt](voice/THIRD-PARTY-NOTICES.txt) lists each package with its declared license.

## Optional Python and MLX runtime

The optional installer obtains a pinned standalone CPython runtime from [Astral's python-build-standalone](https://github.com/astral-sh/python-build-standalone) and pinned prebuilt Python wheels. Runtime and package licenses must remain with those installed files; the root MIT license does not relicense them.

The dependency version/hash lock is [chat/requirements-lock.txt](chat/requirements-lock.txt). [chat/THIRD-PARTY-NOTICES.txt](chat/THIRD-PARTY-NOTICES.txt) records the wheel sources and declared licenses. The installed distributions retain their metadata, license files, and notices. The dependencies include MLX and MLX-LM (MIT), Transformers and Hugging Face components (Apache 2.0), CPython (PSF and bundled third-party notices), and dependencies with BSD, MIT, Apache, MPL, and other compatible terms. Consult each distribution's full license before redistributing an optional runtime pack.

Additional full upstream license texts for packages whose wheels did not include them are in [app/Resources/ChatLicenses](app/Resources/ChatLicenses). Their exact upstream commits and content hashes are recorded there in `SOURCES.json`.

## Apple system interfaces and voices

The application links to frameworks supplied by macOS, including AppKit, Core Animation, IOKit, AVFoundation, and Speech. Apple source references were used for interface signatures and field facts; no Apple system framework implementation is redistributed.

Useful interface references include [memory pressure](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure), [thermal state](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum), [IOPowerSources private declarations](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPowerSourcesPrivate.h), and [IOPS private keys](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeysPrivate.h).

System speech is generated on the user's Mac using installed system voices. No prerecorded system voice samples or Apple voice models are distributed. Their use remains subject to the applicable Apple software license.

## Crisis support numbers

The support lines shown after a message that suggests someone is in crisis were checked against each service's own or a government page on 2026-11-12; the sources are listed in [docs/CRISIS_LINES.md](docs/CRISIS_LINES.md). Numbers and hours can change; corrections are welcome.
