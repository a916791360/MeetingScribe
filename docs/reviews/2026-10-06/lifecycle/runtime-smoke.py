#!/usr/bin/env python3
"""Test signed runtime loading/absolute offsets on synthetic tone; not accuracy."""
import argparse
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
args = parser.parse_args()
runtime = args.app.resolve() / "Contents/Resources/whisper"
with tempfile.TemporaryDirectory(prefix="ms-lifecycle-runtime-") as name:
    root = Path(name)
    audio = root / "synthetic.wav"
    with wave.open(str(audio), "wb") as output:
        output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        output.writeframes(b"\0\0" * (599 * 16000))
        output.writeframes(b"".join(struct.pack("<h", int(6000 * math.sin(2 * math.pi * 440 * i / 16000)))
                                  for i in range(3 * 16000)))
    for mode, extra in [("gpu", []), ("cpu", ["-ng"])]:
        prefix = root / mode
        command = [str(runtime / "bin/whisper-cli"), "-m", str(runtime / "models/ggml-small.bin"),
                   "-f", str(audio), "-l", "zh", "-t", "2", "-ojf", "-of", str(prefix),
                   "-ot", "599000", "-d", "3000", *extra]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        print(mode, "exit=", result.returncode)
        print(result.stdout)
        assert result.returncode == 0
        segments = json.loads(prefix.with_suffix(".json").read_text())["transcription"]
        assert segments
        assert all(s["offsets"]["from"] >= 599000 and s["offsets"]["to"] >= s["offsets"]["from"] for s in segments)
        print(mode, "JSON parsed; absolute offsets preserved. Runtime smoke only.")
