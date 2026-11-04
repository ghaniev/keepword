# Third-party components (macOS)

## Swift packages

Resolved versions are pinned in `Package.resolved`.

| Package | License |
|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | MIT |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT |
| [swift-embeddings](https://github.com/jkrukowski/swift-embeddings) | MIT |
| [swift-safetensors](https://github.com/jkrukowski/swift-safetensors) | MIT |
| [swift-sentencepiece](https://github.com/jkrukowski/swift-sentencepiece) | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | Apache-2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache-2.0 |
| [EventSource](https://github.com/mattt/EventSource) | MIT |
| [yyjson](https://github.com/ibireme/yyjson) | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 |
| [swift-asn1](https://github.com/apple/swift-asn1) | Apache-2.0 |

## Bundled binary

- [llama.cpp](https://github.com/ggml-org/llama.cpp), MIT, release b11457 (`llama.xcframework`), copied into `MeetNotes.app/Contents/Frameworks`.

## Downloaded models

Models are not part of this repository or the app bundle. They are downloaded on request from their publishers and each one is covered by the license on its model card:

- Parakeet TDT speech recognition (NVIDIA, CC BY 4.0), Core ML conversions by FluidInference, through FluidAudio.
- Speaker diarization models (pyannote segmentation, WeSpeaker embeddings), Core ML conversions by FluidInference, through FluidAudio.
- Whisper (OpenAI, MIT), Core ML conversions by Argmax, through WhisperKit.
- [paraphrase-multilingual-MiniLM-L12-v2](https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2) (sentence-transformers, Apache-2.0).
- Qwen GGUF models for the built-in local AI, quantized by [Unsloth](https://huggingface.co/unsloth) and [bartowski](https://huggingface.co/bartowski).
