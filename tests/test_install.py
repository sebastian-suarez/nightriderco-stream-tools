"""Filesystem-only acceptance tests; no OBS, services or credential access."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).absolute().parents[1] / "install.py"
SPEC = importlib.util.spec_from_file_location("staging_installer", MODULE_PATH)
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=os.path.realpath(tempfile.gettempdir()))
        self.root = Path(self.temporary.name)
        self.payload = self.root / "source repository" / "payload"
        self.payload.mkdir(parents=True)
        self.destination = self.root / "installed tools with spaces"
        self.write("Example/config.js", b"const setting = 'default';\n")
        self.write("Example/run.command", b"#!/bin/sh\nexit 0\n", 0o755)
        self.write("Helper.app/Contents/MacOS/Helper", b"native binary fixture\x00", 0o755)
        self.write("Helper.app/Contents/_CodeSignature/CodeResources", b"bundle signature fixture")
        self.write("Helper.app/Contents/Resources/asset.png", b"image fixture")

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, relative, content, mode=0o644):
        target = self.payload / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        target.chmod(mode)

    def install(self, **options):
        return installer.stage_install(self.payload, self.destination, **options)

    def test_install_preserves_bundle_bytes_modes_and_records_paths(self):
        result = self.install()
        self.assertEqual(result["status"], "installed")
        self.assertEqual((self.destination / "Helper.app/Contents/MacOS/Helper").read_bytes(), b"native binary fixture\x00")
        self.assertEqual(stat.S_IMODE((self.destination / "Example/run.command").stat().st_mode), 0o755)
        self.assertTrue((self.destination / "Helper.app/Contents/_CodeSignature/CodeResources").is_file())
        receipt = json.loads((self.destination / installer.RECEIPT).read_text())
        self.assertEqual(len(receipt["payload"]["files"]), 5)
        self.assertNotIn(str(self.payload), (self.destination / installer.RECEIPT).read_text())
        self.assertIn(str(self.destination / "Example"), (self.destination / installer.SETUP).read_text())
        self.assertEqual(self.install(verify=True)["status"], "verified")
        self.assertFalse(list(self.root.glob(".*.staging-*")))

    def test_dry_run_has_no_filesystem_side_effects(self):
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        self.assertEqual(self.install(dry_run=True)["status"], "dry-run")
        self.assertEqual(before, sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")))
        self.assertFalse(self.destination.exists())

    def test_repeating_install_does_not_rewrite_files(self):
        self.install()
        before = {str(path): path.stat().st_mtime_ns for path in self.destination.rglob("*")}
        self.assertEqual(self.install()["status"], "unchanged")
        self.assertEqual(before, {str(path): path.stat().st_mtime_ns for path in self.destination.rglob("*")})

    def test_user_configuration_survives_repeat_and_verification(self):
        self.install()
        config = self.destination / "Example/config.js"
        config.write_text("const setting = 'my custom value';\n")
        before = config.stat().st_mtime_ns
        for options in ({}, {"verify": True}, {"dry_run": True}):
            self.assertEqual(self.install(**options)["changed_config"], ["Example/config.js"])
        self.assertEqual(config.read_text(), "const setting = 'my custom value';\n")
        self.assertEqual(config.stat().st_mtime_ns, before)

    def test_unowned_destination_is_not_overwritten(self):
        self.destination.mkdir()
        sentinel = self.destination / "keep.txt"
        sentinel.write_text("keep me")
        with self.assertRaises(installer.InstallError):
            self.install()
        self.assertEqual(sentinel.read_text(), "keep me")
        self.assertEqual(list(self.destination.iterdir()), [sentinel])

    def test_empty_existing_destination_is_not_claimed(self):
        self.destination.mkdir()
        with self.assertRaises(installer.InstallError):
            self.install()
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_tampered_owned_file_fails_verification_and_repeat(self):
        self.install()
        target = self.destination / "Example/run.command"
        target.write_text("edited locally")
        for options in ({}, {"verify": True}):
            with self.assertRaises(installer.InstallError):
                self.install(**options)
        self.assertEqual(target.read_text(), "edited locally")

    def test_unowned_addition_is_preserved_and_rejected(self):
        self.install()
        extra = self.destination / "personal.txt"
        extra.write_text("personal")
        with self.assertRaises(installer.InstallError):
            self.install()
        self.assertEqual(extra.read_text(), "personal")

    def test_generated_runtime_and_finder_files_survive_repeat_and_verification(self):
        self.write("NIGHTRIDERCO-OBS-AUTOSTART/start-services.py", b"startup fixture")
        self.write("NIGHTRIDERCO-Resolution-Dock/server.py", b"resolution fixture")
        self.install()
        generated = [
            "NIGHTRIDERCO-OBS-AUTOSTART/runtime/status.json",
            "NIGHTRIDERCO-OBS-AUTOSTART/runtime/worker/worker.pid",
            "NIGHTRIDERCO-OBS-AUTOSTART/logs/startup.log",
            "NIGHTRIDERCO-OBS-AUTOSTART/obs-status.json",
            "NIGHTRIDERCO-OBS-AUTOSTART/obs-startup.log",
            "NIGHTRIDERCO-Resolution-Dock/runtime/displays.json",
            ".DS_Store",
            "Helper.app/Contents/Resources/.DS_Store",
        ]
        for name in generated:
            target = self.destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("generated contents: " + name)
        before = {
            name: ((self.destination / name).read_bytes(), (self.destination / name).stat().st_mtime_ns)
            for name in generated
        }
        self.assertEqual(self.install(verify=True)["status"], "verified")
        self.assertEqual(self.install()["status"], "unchanged")
        self.assertEqual(self.install(dry_run=True)["status"], "unchanged")
        self.assertEqual(before, {
            name: ((self.destination / name).read_bytes(), (self.destination / name).stat().st_mtime_ns)
            for name in generated
        })

    def test_runtime_directory_and_nested_file_symlinks_are_rejected(self):
        self.write("NIGHTRIDERCO-OBS-AUTOSTART/start-services.py", b"startup fixture")
        self.install()
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "status.json").write_text("outside contents")
        runtime = self.destination / "NIGHTRIDERCO-OBS-AUTOSTART/runtime"
        runtime.symlink_to(outside, target_is_directory=True)
        for options in ({}, {"verify": True}):
            with self.assertRaises(installer.InstallError):
                self.install(**options)
        runtime.unlink()
        runtime.mkdir()
        (runtime / "status.json").symlink_to(outside / "status.json")
        with self.assertRaises(installer.InstallError):
            self.install(verify=True)
        self.assertEqual((outside / "status.json").read_text(), "outside contents")

    def test_runtime_allowlist_does_not_allow_similar_or_unrelated_paths(self):
        self.write("NIGHTRIDERCO-OBS-AUTOSTART/start-services.py", b"startup fixture")
        self.install()
        for name in (
            "NIGHTRIDERCO-OBS-AUTOSTART/runtime-other/status.json",
            "Example/runtime/status.json",
            "Example/__pycache__/module.pyc",
        ):
            with self.subTest(path=name):
                extra = self.destination / name
                extra.parent.mkdir()
                extra.write_text("unexpected contents")
                with self.assertRaises(installer.InstallError):
                    self.install(verify=True)
                self.assertEqual(extra.read_text(), "unexpected contents")
                extra.unlink()
                extra.parent.rmdir()

    def test_finder_exception_only_allows_regular_files(self):
        self.install()
        finder = self.destination / "Example/.DS_Store"
        finder.mkdir()
        with self.assertRaises(installer.InstallError):
            self.install(verify=True)
        finder.rmdir()
        finder.symlink_to(self.payload / "Example/config.js")
        with self.assertRaises(installer.InstallError):
            self.install(verify=True)

    def test_runtime_allowlist_does_not_hide_changed_package_files(self):
        self.write("NIGHTRIDERCO-OBS-AUTOSTART/runtime/preset.json", b"packaged preset")
        self.install()
        preset = self.destination / "NIGHTRIDERCO-OBS-AUTOSTART/runtime/preset.json"
        preset.write_text("changed preset")
        with self.assertRaises(installer.InstallError):
            self.install(verify=True)
        self.assertEqual(preset.read_text(), "changed preset")

    def test_changed_package_requires_new_destination(self):
        self.install()
        original = (self.destination / "Example/run.command").read_bytes()
        self.write("Example/run.command", b"new version", 0o755)
        with self.assertRaises(installer.InstallError):
            self.install()
        self.assertEqual((self.destination / "Example/run.command").read_bytes(), original)

    def test_source_symlinks_are_rejected(self):
        outside = self.root / "outside.txt"
        outside.write_text("must not be copied")
        (self.payload / "external.txt").symlink_to(outside)
        with self.assertRaises(installer.InstallError):
            self.install()
        self.assertFalse(self.destination.exists())

    def test_destination_symlink_and_symlink_parent_are_rejected(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        self.destination.symlink_to(elsewhere, target_is_directory=True)
        with self.assertRaises(installer.InstallError):
            self.install()
        with self.assertRaises(installer.InstallError):
            installer.stage_install(self.payload, self.destination / "nested")
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_symlink_inserted_into_owned_install_is_rejected(self):
        self.install()
        config = self.destination / "Example/config.js"
        config.unlink()
        config.symlink_to(self.payload / "Example/config.js")
        with self.assertRaises(installer.InstallError):
            self.install(verify=True)

    def test_source_destination_overlap_is_rejected(self):
        for destination in (self.payload, self.payload / "nested", self.payload.parent, self.root):
            with self.assertRaises(installer.InstallError):
                installer.stage_install(self.payload, destination)

    def test_missing_payload_and_missing_verification_target_fail(self):
        with self.assertRaises(installer.InstallError):
            installer.stage_install(self.root / "missing repository/payload", self.destination)
        with self.assertRaises(installer.InstallError):
            self.install(verify=True)
        self.assertFalse(self.destination.exists())

    def test_copy_failure_cleans_stage_without_creating_destination(self):
        with mock.patch.object(installer.shutil, "copyfileobj", side_effect=OSError("simulated failure")):
            with self.assertRaises(OSError):
                self.install()
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.root.glob(".*.staging-*")))

    def test_atomic_commit_refuses_destination_created_during_copy(self):
        actual_commit = installer.rename_without_replacement

        def conflict(source, destination):
            destination.mkdir()
            (destination / "keep.txt").write_text("concurrent contents")
            actual_commit(source, destination)

        with mock.patch.object(installer, "rename_without_replacement", side_effect=conflict):
            with self.assertRaises(installer.InstallError):
                self.install()
        self.assertEqual((self.destination / "keep.txt").read_text(), "concurrent contents")
        self.assertFalse(list(self.root.glob(".*.staging-*")))

    def test_cli_dry_run_and_missing_payload_status(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(installer.main(["--destination", str(self.destination), "--dry-run"], payload=self.payload), 0)
            self.assertEqual(installer.main(["--destination", str(self.destination)], payload=self.root / "missing/payload"), 1)


if __name__ == "__main__":
    unittest.main()
