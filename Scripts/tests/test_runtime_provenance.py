import importlib.util
import json
import plistlib
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("provenance", Path(__file__).resolve().parents[1] / "runtime_provenance.py")
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


class RuntimeProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ms-provenance-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "build/bin").mkdir(parents=True)
        (self.root / "models").mkdir()
        (self.root / "build/bin/whisper-cli").write_bytes(b"synthetic engine")
        (self.root / "models/ggml-small.bin").write_bytes(b"synthetic model")
        self.lock = {"whisper": {"commit": "fixed"}, "model": {"filename": "ggml-small.bin", "sha256": provenance.digest(self.root / "models/ggml-small.bin")}, "cmake_options": {"GGML_NATIVE": "OFF"}}
        self.manifest = {
            "source": self.lock["whisper"], "model": self.lock["model"],
            "cmake_options": self.lock["cmake_options"],
            "files_sha256": {name: provenance.digest(self.root / name) for name in ["build/bin/whisper-cli", "models/ggml-small.bin"]},
        }
        self.save()

    def save(self):
        (self.root / "runtime-provenance.json").write_text(json.dumps(self.manifest))

    def test_valid_input_and_modified_binary_rejection(self):
        provenance.verify(self.root, self.lock)
        (self.root / "build/bin/whisper-cli").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            provenance.verify(self.root, self.lock)

    def test_missing_required_hash_rejected(self):
        del self.manifest["files_sha256"]["build/bin/whisper-cli"]
        self.save()
        with self.assertRaises(ValueError):
            provenance.verify(self.root, self.lock)

    def test_source_and_build_options_must_match_lock(self):
        self.manifest["source"] = {"commit": "unrecognized"}
        self.save()
        with self.assertRaises(ValueError):
            provenance.verify(self.root, self.lock)
        self.manifest["source"] = self.lock["whisper"]
        self.manifest["cmake_options"] = {"GGML_NATIVE": "ON"}
        self.save()
        with self.assertRaises(ValueError):
            provenance.verify(self.root, self.lock)

    def test_unrecorded_runtime_library_rejected(self):
        (self.root / "build/bin/libwhisper.dylib").write_bytes(b"unrecorded library")
        with self.assertRaises(ValueError):
            provenance.verify(self.root, self.lock)

    def test_model_with_self_consistent_but_unofficial_hash_rejected(self):
        model = self.root / "models/ggml-small.bin"
        model.write_bytes(b"different model")
        self.manifest["files_sha256"]["models/ggml-small.bin"] = provenance.digest(model)
        self.save()
        with self.assertRaises(ValueError):
            provenance.verify(self.root, self.lock)

    def test_unsafe_file_path_rejected(self):
        for unsafe in ["../private", "/private"]:
            self.manifest["files_sha256"][unsafe] = "fake"
            self.save()
            with self.assertRaises(ValueError):
                provenance.verify(self.root, self.lock)
            del self.manifest["files_sha256"][unsafe]

    def test_packaged_hashes_are_distinct_from_input_hashes(self):
        bundle = self.root / "Fixture.app"
        engine = bundle / "Contents/Resources/whisper/bin/whisper-cli"
        engine.parent.mkdir(parents=True)
        engine.write_bytes(b"relocated and signed engine")
        model = bundle / "Contents/Resources/whisper/models/ggml-small.bin"
        model.parent.mkdir(parents=True)
        model.write_bytes(b"synthetic model")
        provenance.write_bundle(self.root, bundle, self.lock)
        doc = plistlib.loads((bundle / "Contents/Resources/RuntimeProvenance.plist").read_bytes())
        self.assertEqual(doc["bundled_files_sha256"]["bin/whisper-cli"], provenance.digest(engine))
        self.assertNotEqual(doc["input_files_sha256"]["build/bin/whisper-cli"], doc["bundled_files_sha256"]["bin/whisper-cli"])
        provenance.audit_bundle(bundle, self.lock)
        engine.write_bytes(b"tampered engine")
        with self.assertRaises(ValueError):
            provenance.audit_bundle(bundle, self.lock)


if __name__ == "__main__":
    unittest.main()
