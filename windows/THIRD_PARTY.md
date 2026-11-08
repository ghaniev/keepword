# Third-party notices

The Parakeet ONNX decoder in `app/src-tauri/src/asr.rs` adapts the TDT decoding approach from
[meetily](https://github.com/Zackriya-Solutions/meetily), `frontend/src-tauri/src/parakeet_engine/model.rs`.

MIT License

Copyright (c) 2024 Zackriya Solutions

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Downloaded models and runtimes

- [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), NVIDIA;
  [ONNX conversion](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx), istupakov.
  CC BY 4.0. Downloaded separately, converted/quantized model; Keepword does not train these weights.
- ONNX Runtime 1.22.0, Microsoft, MIT. Its LICENSE is bundled in `onnxruntime/`.
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), Apache-2.0, official Rust/static Windows bindings.
- [pyannote segmentation 3.0](https://huggingface.co/pyannote/segmentation-3.0), MIT,
  ONNX conversion distributed by sherpa-onnx. The model archive's LICENSE is retained with the downloaded model.
- [NVIDIA TitaNet-S](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/titanet_small),
  NeMo Toolkit license (Apache-2.0); ONNX export distributed by sherpa-onnx.
- [Multilingual MiniLM L12 v2](https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2),
  sentence-transformers, Apache-2.0; downloaded separately at the pinned revision in `models.rs`.
- [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), Apache-2.0;
  optional Q4_K_M GGUF conversion by [Unsloth](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF), downloaded separately.
- [llama.cpp](https://github.com/ggml-org/llama.cpp), MIT, build b11457.
  Its license and LLVM OpenMP notice accompany the runtime in `llama/`.
- [FFmpeg](https://ffmpeg.org/), LGPL-3.0 shared build from
  [BtbN](https://github.com/BtbN/FFmpeg-Builds/releases/tag/autobuild-2026-11-07-12-47),
  n8.1.3-34-ga35157abb9. FFmpeg is invoked as a separate process. The shared libraries may be replaced
  by compatible user builds; Keepword does not impose a restriction on reverse engineering for debugging
  modifications to those libraries. The LGPL text is included in `media/LICENSE.txt`.
  Corresponding FFmpeg source: [a35157abb9](https://github.com/FFmpeg/FFmpeg/tree/a35157abb9);
  build recipes and dependency source retrieval instructions: [FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds).
- [ical.js](https://github.com/kewisch/ical.js), Mozilla Public License 2.0;
  used without source modifications. Its source and license are available from its npm package/repository.

The installer also includes `notices/packages.json` and the available LICENSE/COPYING/NOTICE/COPYRIGHT
files from the exact locked Rust and npm dependency packages. `scripts/prepare-notices.ps1` generates
this inventory from Cargo metadata and installed npm packages. Development-tool notices may also appear
in this conservative inventory. Model weights are downloaded on request and are not embedded in the installer.
