"""Fault-inject installer commands against temporary fake bundles only."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which("zsh"), "installer requires zsh")
class SafeInstallTests(unittest.TestCase):
    def run_install(self, failure=""):
        with tempfile.TemporaryDirectory(prefix="ms-install-test-") as directory:
            root = pathlib.Path(directory)
            (root / "Scripts").mkdir()
            installer = pathlib.Path(__file__).resolve().parents[1] / "install_app.sh"
            shutil.copy(installer, root / "Scripts/install_app.sh")
            package = root / "Scripts/package_app.sh"
            package.write_text("#!/bin/sh\nexit 0\n")
            package.chmod(0o755)
            app = root / ".build/MeetingScribe.app"
            app.mkdir(parents=True)
            (app / "version").write_text("new")
            destination = root / "Applications"
            installed = destination / "MeetingScribe.app"
            installed.mkdir(parents=True)
            (installed / "version").write_text("old")
            commands = root / "bin"
            commands.mkdir()
            stubs = {
                "pgrep": '[ "$MS_INSTALL_TEST_FAILURE" = running ]',
                "ditto": '[ "$MS_INSTALL_TEST_FAILURE" != copy ] || exit 42\n/bin/cp -R "$1" "$2"',
                "codesign": '[ "$MS_INSTALL_TEST_FAILURE" != signature ]',
                "open": 'exit 0',
                "mv": 'case "$1" in *-install.*) [ "$MS_INSTALL_TEST_FAILURE" != swap ] || exit 42;; esac\n/bin/mv "$@"',
            }
            for name, body in stubs.items():
                path = commands / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o755)
            env = os.environ.copy()
            env.update(INSTALL_DIR=str(destination), MS_INSTALL_TEST_FAILURE=failure,
                       PATH=str(commands) + os.pathsep + env["PATH"])
            result = subprocess.run(["zsh", str(root / "Scripts/install_app.sh")],
                                    env=env, capture_output=True, text=True)
            self.assertEqual((installed / "version").read_text(), "old" if failure else "new")
            self.assertEqual(result.returncode != 0, bool(failure), result.stdout + result.stderr)
            backups = list(destination.glob(".MeetingScribe-backup-*.app"))
            if not failure:
                self.assertEqual(len(backups), 1)
                self.assertEqual((backups[0] / "version").read_text(), "old")
            self.assertEqual(list(destination.glob(".MeetingScribe-install.*")), [])

    def test_running_app_is_not_terminated_or_replaced(self):
        self.run_install("running")

    def test_copy_failure_preserves_previous_app(self):
        self.run_install("copy")

    def test_invalid_signature_preserves_previous_app(self):
        self.run_install("signature")

    def test_failed_swap_restores_previous_app(self):
        self.run_install("swap")

    def test_success_retains_backup(self):
        self.run_install()


if __name__ == "__main__":
    unittest.main()
