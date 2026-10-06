#!/usr/bin/env python3
"""Build the locked upstream runtime without modifying an existing installation."""
import argparse
import hashlib
import json
import platform
import shutil
import subprocess
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def main():
    repo = Path(__file__).resolve().parents[1]
    lock = json.loads((repo / "Packaging/runtime-lock.json").read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=repo / ".build/pinned-whisper")
    parser.add_argument("--model", type=Path, required=True, help="Existing local small model; hash checked before copy")
    parser.add_argument("--cmake", default=shutil.which("cmake"))
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("The locked build currently targets Apple Silicon macOS only")
    if not args.cmake:
        parser.error("Install CMake from its official source or pass --cmake")
    if sha256(args.model) != lock["model"]["sha256"]:
        parser.error("Local model does not match the locked official SHA256")
    root = args.output.resolve()
    if not root.exists():
        subprocess.run(["git", "clone", "--depth", "1", "--branch", lock["whisper"]["tag"], lock["whisper"]["repository"], str(root)], check=True)
    if not (root / ".git").is_dir():
        parser.error("Output already exists and is not a dedicated runtime checkout")
    if run(["git", "-C", str(root), "rev-parse", "HEAD"]) != lock["whisper"]["commit"]:
        parser.error("Checkout differs from locked commit; use a new output directory")
    for flags in [[], ["--cached"]]:
        subprocess.run(["git", "-C", str(root), "diff", "--quiet", *flags], check=True)
    options = [f"-D{name}={value}" for name, value in lock["cmake_options"].items()]
    path_map = f"-ffile-prefix-map={root}=whisper-source"
    options += [f"-DCMAKE_C_FLAGS={path_map}", f"-DCMAKE_CXX_FLAGS={path_map}"]
    subprocess.run([args.cmake, "-S", str(root), "-B", str(root / "build"), *options], check=True)
    subprocess.run([args.cmake, "--build", str(root / "build"), "--config", "Release", "--target", "whisper-cli", "-j", "6"], check=True)
    model = root / "models" / lock["model"]["filename"]
    if args.model.resolve() != model.resolve():
        shutil.copy2(args.model, model)
    bin_dir = root / "build/bin"
    files = {str(p.relative_to(root)): sha256(p) for p in sorted(bin_dir.iterdir())
             if p.is_file() and (p.name == "whisper-cli" or p.suffix == ".dylib")}
    files[str(model.relative_to(root))] = sha256(model)
    provenance = {
        "schema_version": 1,
        "source": lock["whisper"],
        "vendored_ggml_tree": run(["git", "-C", str(root), "rev-parse", "HEAD:ggml"]),
        "model": lock["model"],
        "cmake_options": lock["cmake_options"],
        "path_prefix_map": "source root mapped to whisper-source",
        "compiler": run(["xcrun", "clang", "--version"]).splitlines()[0],
        "cmake_version": run([args.cmake, "--version"]).splitlines()[0],
        "files_sha256": files,
    }
    (root / "runtime-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Locked runtime built: {root}")


if __name__ == "__main__":
    main()
