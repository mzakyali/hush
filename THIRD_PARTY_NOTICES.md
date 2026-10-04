# Third-Party Notices

Hush depends on the following open-source packages. Licences were verified
against the checked-out sources (`Packages/HushKit/.build/checkouts/`).

## Direct dependencies

| Package | Version | Licence |
|---|---|---|
| [argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) (WhisperKit) | 1.1.0 | MIT |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 2.31.3 | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.2.1 | Apache-2.0 |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | MIT |

## Transitive dependencies

| Package | Version | Licence |
|---|---|---|
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | 0.31.6 | MIT |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | 0.11.0 | Apache-2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | 2.5.1 | Apache-2.0 |
| [EventSource](https://github.com/mattt/EventSource) | 1.5.1 | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.3 | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.7.1 | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.2 | Apache-2.0 |
| [swift-numerics](https://github.com/apple/swift-numerics) | 1.1.1 | Apache-2.0 |
| [yyjson](https://github.com/ibireme/yyjson) | 0.12.0 | MIT |

Pinned versions are recorded in `Packages/HushKit/Package.resolved`.

## Bundled fonts

| Font | Source | Licence |
|---|---|---|
| Geist Mono | [vercel/geist-font](https://github.com/vercel/geist-font) | SIL Open Font License 1.1 |
| Instrument Serif | [google/fonts](https://github.com/google/fonts) (`ofl/instrumentserif`) | SIL Open Font License 1.1 |

Licence texts ship in `App/Fonts/`.

## Models

Models are downloaded at runtime and are not redistributed with Hush. Users
are responsible for complying with each model's licence.

| Model | Used for | Licence / terms |
|---|---|---|
| `openai_whisper-large-v3-v20240930_turbo_632MB` via [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) (upstream: OpenAI Whisper large-v3-turbo) | Speech recognition | MIT |
| [mlx-community/Qwen3-4B-Instruct-2507-4bit](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit) | Text cleanup | Apache-2.0 |
| [mlx-community/gemma-3-4b-it-4bit](https://huggingface.co/mlx-community/gemma-3-4b-it-4bit) | Cleanup fallback | [Gemma Terms of Use](https://ai.google.dev/gemma/terms) |
