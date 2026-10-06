#!/usr/bin/env python3
"""Build an isolated native UI fixture; launching remains a separate UI action.

Uses synthetic meetings and a delayed fake recorder, without capturing devices.
The temporary bundle identifier isolates preferences from the installed app.
"""
from pathlib import Path
import plistlib
import subprocess
import tempfile

evidence = Path(__file__).resolve().parent
repo = evidence.parents[2]
root = Path(tempfile.mkdtemp(prefix="ms-closure-ui-"))
app = root / "MSClosureReview.app"
binary = app / "Contents/MacOS/MSClosureReview"
binary.parent.mkdir(parents=True)
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.qingmeng.meetingscribe.review.closure",
    "CFBundleName": "MSClosureReview",
    "CFBundleExecutable": "MSClosureReview",
    "CFBundlePackageType": "APPL",
    "NSHighResolutionCapable": True,
    "LSMinimumSystemVersion": "15.0",
}))
sources = sorted(str(p) for p in repo.glob("*.swift")
                 if p.name not in {"Package.swift", "MeetingScribeApp.swift"})
log_path = root / "build.log"
with log_path.open("w") as log:
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-O", "-swift-version", "6",
        "-warnings-as-errors", "-target", "arm64-apple-macosx15.0",
        "-module-cache-path", str(repo / ".build/module-cache"),
        *sources, str(evidence / "ReviewClosureUIHarness.swift"), "-o", str(binary),
    ], check=True, stdout=log, stderr=subprocess.STDOUT)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)],
                   check=True, stdout=log, stderr=subprocess.STDOUT)
print(app)
