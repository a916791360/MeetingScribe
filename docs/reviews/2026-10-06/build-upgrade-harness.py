#!/usr/bin/env python3
"""Build baseline UI with synthetic meetings in a unique local app bundle.

Run this script, then open the printed .app path. Never import actual meeting data.
No external dependencies, recording, cloud requests, or key saving are required.
"""
import pathlib
import plistlib
import re
import subprocess
import tempfile

evidence = pathlib.Path(__file__).resolve().parent
repo = evidence.parents[2]
root = pathlib.Path(tempfile.mkdtemp(prefix="ms-review-upgrade-"))
app = root / "MeetingScribeReview.app"
binary = app / "Contents" / "MacOS" / "MeetingScribeReview"
binary.parent.mkdir(parents=True)
metadata = {
    "CFBundleIdentifier": "local.codex.MeetingScribeReview.upgrade",
    "CFBundleName": "MeetingScribeReview",
    "CFBundleExecutable": "MeetingScribeReview",
    "CFBundlePackageType": "APPL",
    "NSHighResolutionCapable": True,
}
(app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(metadata))
sources = re.findall(r'"([A-Za-z]+\.swift)"', (repo / "Package.swift").read_text())
sources = [str(repo / source) for source in sources if source != "MeetingScribeApp.swift"]
with (evidence / "upgrade-ui-build.log").open("w") as log:
    result = subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
        *sources, str(evidence / "ReviewUpgradeUIHarness.swift"), "-o", str(binary),
    ], stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    raise SystemExit((evidence / "upgrade-ui-build.log").read_text())
print(app)
