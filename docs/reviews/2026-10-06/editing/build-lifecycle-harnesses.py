#!/usr/bin/env python3
"""Build isolated UI and persistence benchmarks; does not launch the UI app."""
from pathlib import Path
import json
import plistlib
import subprocess
import tempfile

evidence = Path(__file__).resolve().parent
repo = evidence.parents[3]
root = Path(tempfile.mkdtemp(prefix="ms-editing-harnesses-"))
app = root / "MSLifecycleReview.app"
binary = app / "Contents/MacOS/MSLifecycleReview"
binary.parent.mkdir(parents=True)
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.qingmeng.meetingscribe.review.editing",
    "CFBundleName": "MSLifecycleReview", "CFBundleExecutable": "MSLifecycleReview",
    "CFBundlePackageType": "APPL", "NSHighResolutionCapable": True,
    "LSMinimumSystemVersion": "15.0",
}))
sources = sorted(str(p) for p in repo.glob("*.swift")
                 if p.name not in {"Package.swift", "MeetingScribeApp.swift"})
compiler = ["xcrun", "swiftc", "-parse-as-library", "-O", "-swift-version", "6",
            "-warnings-as-errors", "-target", "arm64-apple-macosx15.0",
            "-module-cache-path", str(root / "module-cache"), *sources]
with (evidence / "harness-build.log").open("w") as log:
    subprocess.run([*compiler, str(evidence / "ReviewLifecycleUIHarness.swift"), "-o", str(binary)],
                   check=True, stdout=log, stderr=subprocess.STDOUT)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)],
                   check=True, stdout=log, stderr=subprocess.STDOUT)
    benchmark = root / "persistence-benchmark"
    subprocess.run([*compiler, str(evidence / "ReviewPersistenceBenchmark.swift"), "-o", str(benchmark)],
                   check=True, stdout=log, stderr=subprocess.STDOUT)
(evidence / "harness-paths.json").write_text(json.dumps({"app": str(app), "benchmark": str(benchmark)}, indent=2) + "\n")
with (evidence / "persistence-benchmark.json").open("w") as output:
    subprocess.run([str(benchmark)], check=True, stdout=output)
print(app)
