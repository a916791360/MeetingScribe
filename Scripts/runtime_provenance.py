#!/usr/bin/env python3
"""Verify locked runtime inputs and record hashes after relocation and signing."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def verify(root, lock):
    source = json.loads((root / "runtime-provenance.json").read_text())
    for key, expected in [("source", lock["whisper"]), ("model", lock["model"]), ("cmake_options", lock["cmake_options"])]:
        if source.get(key) != expected:
            raise ValueError(f"Runtime provenance differs from lock: {key}")
    files = source["files_sha256"]
    model_name = "models/" + lock["model"]["filename"]
    required = {"build/bin/whisper-cli", model_name}
    if not required.issubset(files):
        raise ValueError("Runtime provenance is missing engine or model hashes")
    runtime_files = {str(p.relative_to(root)) for p in (root / "build/bin").iterdir()
                     if p.is_file() and (p.name == "whisper-cli" or p.suffix == ".dylib")}
    if set(files) != runtime_files | {model_name}:
        raise ValueError("Runtime provenance must cover every packaged input")
    if files[model_name] != lock["model"]["sha256"]:
        raise ValueError("Runtime input model differs from official locked SHA256")
    for name, expected in files.items():
        p = Path(name)
        if p.is_absolute() or ".." in p.parts:
            raise ValueError("Unsafe provenance file path")
        (root / p).resolve().relative_to(root.resolve())
        if digest(root / p) != expected:
            raise ValueError(f"Runtime input hash mismatch: {name}")
    return source


def write_bundle(root, bundle, lock):
    source = verify(root, lock)
    runtime = bundle / "Contents/Resources/whisper"
    # Input and packaged hashes differ because Mach-O relocation and signing modify bytes.
    result = dict(source)
    result["input_files_sha256"] = result.pop("files_sha256")
    result["bundled_files_sha256"] = {
        str(p.relative_to(runtime)): digest(p) for p in sorted(runtime.rglob("*")) if p.is_file()
    }
    (bundle / "Contents/Resources/RuntimeProvenance.plist").write_bytes(plistlib.dumps(result))


def audit_bundle(bundle, lock):
    source = plistlib.loads((bundle / "Contents/Resources/RuntimeProvenance.plist").read_bytes())
    for key, expected in [("source", lock["whisper"]), ("model", lock["model"]), ("cmake_options", lock["cmake_options"])]:
        if source.get(key) != expected:
            raise ValueError(f"Packaged runtime differs from lock: {key}")
    runtime = bundle / "Contents/Resources/whisper"
    actual = {}
    for path in runtime.rglob("*"):
        if path.is_file():
            path.resolve().relative_to(runtime.resolve())
            actual[str(path.relative_to(runtime))] = digest(path)
    if actual != source["bundled_files_sha256"]:
        raise ValueError("Packaged runtime hashes differ from signed provenance")
    if actual.get("models/" + lock["model"]["filename"]) != lock["model"]["sha256"]:
        raise ValueError("Packaged model does not match official locked SHA256")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--audit-bundle", type=Path)
    args = parser.parse_args()
    lock = json.loads((Path(__file__).resolve().parents[1] / "Packaging/runtime-lock.json").read_text())
    if args.audit_bundle:
        audit_bundle(args.audit_bundle, lock)
    elif args.bundle and args.runtime:
        write_bundle(args.runtime, args.bundle, lock)
    elif args.runtime:
        verify(args.runtime, lock)
    else:
        parser.error("Specify --runtime or --audit-bundle")
    print("Locked runtime provenance and input hashes verified")


if __name__ == "__main__":
    main()
