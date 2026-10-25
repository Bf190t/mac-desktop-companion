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

## Optional Python and MLX runtime

The optional installer obtains a pinned standalone CPython runtime from [Astral's python-build-standalone](https://github.com/astral-sh/python-build-standalone) and pinned prebuilt Python wheels. Runtime and package licenses must remain with those installed files; the root MIT license does not relicense them.

The dependency version/hash lock is [chat/requirements-lock.txt](chat/requirements-lock.txt). [chat/THIRD-PARTY-NOTICES.txt](chat/THIRD-PARTY-NOTICES.txt) records the wheel sources and declared licenses. The installed distributions retain their metadata, license files, and notices. The dependencies include MLX and MLX-LM (MIT), Transformers and Hugging Face components (Apache 2.0), CPython (PSF and bundled third-party notices), and dependencies with BSD, MIT, Apache, MPL, and other compatible terms. Consult each distribution's full license before redistributing an optional runtime pack.

Additional full upstream license texts for packages whose wheels did not include them are in [app/Resources/ChatLicenses](app/Resources/ChatLicenses). Their exact upstream commits and content hashes are recorded there in `SOURCES.json`.

## Apple system interfaces and voices

The application links to frameworks supplied by macOS, including AppKit, Core Animation, IOKit, AVFoundation, and Speech. Apple source references were used for interface signatures and field facts; no Apple system framework implementation is redistributed.

Useful interface references include [memory pressure](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure), [thermal state](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum), [IOPowerSources private declarations](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPowerSourcesPrivate.h), and [IOPS private keys](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeysPrivate.h).

System speech is generated on the user's Mac using installed system voices. No prerecorded system voice samples or Apple voice models are distributed. Their use remains subject to the applicable Apple software license.
