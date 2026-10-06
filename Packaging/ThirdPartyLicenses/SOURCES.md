# Third-party license sources

The 0.11.5 candidate runtime is built from official whisper.cpp v1.9.4 commit 927cfce34f31707e17f2bff35c349632fb9e2c3a, including vendored ggml tree 5b80b54d27a479724e5ee85badf0cbda9eec7f49. Build flags, model revision and SHA256 are locked in Packaging/runtime-lock.json. RuntimeProvenance.plist records input and packaged hashes separately because relocation/signing change Mach-O bytes.

- Current whisper.cpp repository license (also covers vendored sources): https://github.com/ggml-org/whisper.cpp/blob/927cfce34f31707e17f2bff35c349632fb9e2c3a/LICENSE
- Additional ggml upstream MIT notice retained: https://github.com/ggml-org/ggml/blob/ffa4e8b80930029a35991f94e7c8a93cd67730ab/LICENSE
- Model: https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin ; existing bytes match the LFS SHA256.
- OpenAI Whisper license: https://github.com/openai/whisper/blob/86098128c0b4f24f0e2aa2994de830614b474227/LICENSE

Custom runtime distributors must include their own provenance and any additional notices. Filenames alone do not establish source revision. A successful OSV/upstream-advisory query with no result is not proof that the code has no vulnerabilities.
