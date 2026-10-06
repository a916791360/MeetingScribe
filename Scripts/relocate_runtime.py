#!/usr/bin/env python3
"""Relocate copied runtime binaries before signing; never edit the source runtime."""
import pathlib
import re
import subprocess
import sys


def rpaths(binary):
    output = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    paths = []
    for command in output.split("Load command "):
        if re.search(r"\bcmd LC_RPATH\b", command):
            match = re.search(r"\bpath (.+) \(offset \d+\)", command)
            if match:
                paths.append(match[1])
    return paths


def relocate(directory):
    directory = pathlib.Path(directory).resolve()
    for binary in sorted(directory.iterdir()):
        if not binary.is_file() or not (binary.suffix == ".dylib" or binary.name in {"whisper-cli", "MeetingScribe"}):
            continue
        subprocess.run(["codesign", "--remove-signature", str(binary)], capture_output=True)
        if binary.suffix == ".dylib":
            subprocess.run(["install_name_tool", "-id", "@rpath/" + binary.name, str(binary)], check=True)
        dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            local = directory / pathlib.Path(dependency).name
            if local.is_file():
                subprocess.run(["install_name_tool", "-change", dependency, "@loader_path/" + local.name, str(binary)], check=True)
            elif dependency.startswith("/"):
                raise ValueError("Unbundled non-system dependency: " + binary.name)
        paths = rpaths(binary)
        for path in paths:
            if not path.startswith(("@loader_path", "@executable_path")) and path != "/usr/lib/swift":
                subprocess.run(["install_name_tool", "-delete_rpath", path, str(binary)], check=True)
        if "@loader_path" not in paths:
            subprocess.run(["install_name_tool", "-add_rpath", "@loader_path", str(binary)], check=True)


if __name__ == "__main__":
    relocate(sys.argv[1])
