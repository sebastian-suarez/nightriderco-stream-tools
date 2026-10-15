#!/usr/bin/env python3
"""Stage the bundled payload without starting or configuring any service."""

import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile


RECEIPT = ".nightriderco-install.json"
SETUP = "INSTALLATION.txt"
RESERVED = {RECEIPT, SETUP}
DEFAULT_DESTINATION = "~/Documents/NIGHTRIDERCO-TOOLS"
RUNTIME_DIRECTORIES = {
    "NIGHTRIDERCO-OBS-AUTOSTART/runtime",
    "NIGHTRIDERCO-OBS-AUTOSTART/logs",
    "NIGHTRIDERCO-Resolution-Dock/runtime",
}
RUNTIME_FILES = {
    "NIGHTRIDERCO-OBS-AUTOSTART/obs-status.json",
    "NIGHTRIDERCO-OBS-AUTOSTART/obs-startup.log",
}


class InstallError(Exception):
    """An unsafe or incomplete installation request."""


def absolute_path(value):
    return Path(os.path.abspath(os.path.expanduser(os.fspath(value))))


def reject_symlinks(path):
    """Check existing path components without resolving through a symlink."""
    for item in reversed((path, *path.parents)):
        try:
            mode = item.lstat().st_mode
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(mode):
            raise InstallError(f"Symlinks are not allowed: {item}")


def open_regular(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise InstallError(f"Expected a regular file: {path}")
    return os.fdopen(descriptor, "rb")


def file_hash(path):
    digest = hashlib.sha256()
    with open_regular(path) as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inventory(root):
    files, directories = {}, {}
    pending = [root]
    while pending:
        current = pending.pop()
        for path in sorted(current.iterdir()):
            info = path.lstat()
            relative = path.relative_to(root).as_posix()
            mode = stat.S_IMODE(info.st_mode) & 0o777
            if stat.S_ISLNK(info.st_mode):
                raise InstallError(f"Symlinks are not allowed: {path}")
            if stat.S_ISDIR(info.st_mode):
                directories[relative] = mode
                pending.append(path)
            elif stat.S_ISREG(info.st_mode):
                files[relative] = {"sha256": file_hash(path), "mode": mode}
            else:
                raise InstallError(f"Unsupported file type: {path}")
    return {"files": files, "directories": directories}


def setup_text(destination, manifest):
    top_level = sorted({Path(name).parts[0] for group in manifest.values() for name in group})
    paths = "\n".join(f"- {destination / name}" for name in top_level)
    return (
        "NIGHTRIDERCO tools: staged installation\n\n"
        f"Destination: {destination}\n\nInstalled paths:\n{paths}\n\n"
        "No helpers were started or registered. OBS and Keychain were not changed.\n"
        "Follow the repository README for prerequisites, credentials, macOS permissions,\n"
        "manual OBS setup and startup order before using these files.\n\n"
        "Re-run the repository installer with --verify and this --destination to check\n"
        "the installation. Edited config.js files are preserved and reported.\n"
        "Install an updated package into a new versioned folder and migrate local\n"
        "configuration manually; this installer does not overwrite an existing install.\n"
    )


def generated_addition(name, kind):
    if Path(name).name == ".DS_Store":
        return kind == "files"
    if kind == "files" and name in RUNTIME_FILES:
        return True
    if kind == "directories" and name in RUNTIME_DIRECTORIES:
        return True
    return any(name.startswith(directory + "/") for directory in RUNTIME_DIRECTORIES)


def verify_existing(destination, manifest, receipt):
    # Inspect every entry first, including runtime output, so symlinks and special
    # files are always rejected. Only expected additions are omitted from comparison.
    actual = inventory(destination)
    if RECEIPT not in actual["files"] or SETUP not in actual["files"]:
        raise InstallError("Destination is not an owned installation. Choose a new, nonexistent path.")
    with open_regular(destination / RECEIPT) as stream:
        try:
            saved = json.load(stream)
        except (UnicodeError, ValueError) as error:
            raise InstallError("Installation receipt is invalid; destination was left untouched.") from error
    if saved != receipt:
        raise InstallError("Package or receipt differs. Install into a new versioned folder.")
    comparable = {
        kind: {
            name: metadata
            for name, metadata in actual[kind].items()
            if name in manifest[kind] or not generated_addition(name, kind)
        }
        for kind in ("files", "directories")
    }
    if comparable["directories"] != manifest["directories"]:
        raise InstallError("Installed directories differ. Destination was left untouched.")
    expected_names = set(manifest["files"]) | RESERVED
    if set(comparable["files"]) != expected_names:
        raise InstallError("Missing or unowned files in destination; it was left untouched.")
    expected_setup = hashlib.sha256(setup_text(destination, manifest).encode("utf-8")).hexdigest()
    if actual["files"][SETUP] != {"sha256": expected_setup, "mode": 0o644}:
        raise InstallError("Installation instructions changed; destination was left untouched.")
    changed_config = []
    for name, expected in manifest["files"].items():
        if actual["files"][name] != expected:
            if Path(name).name == "config.js":
                changed_config.append(name)
            else:
                raise InstallError(f"Installed file changed: {name}. Use a new destination.")
    return sorted(changed_config)


def rename_without_replacement(source, destination):
    """Commit atomically, including when another process creates the target."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        arguments = (os.fsencode(source), os.fsencode(destination), 0x00000004)  # RENAME_EXCL
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        arguments = (-100, os.fsencode(source), -100, os.fsencode(destination), 1)  # RENAME_NOREPLACE
    else:
        raise InstallError("This system cannot safely commit the staged installation.")
    rename.restype = ctypes.c_int
    if rename(*arguments) != 0:
        code = ctypes.get_errno()
        if code in (errno.EEXIST, errno.ENOTEMPTY):
            raise InstallError("Destination appeared during staging; it was left untouched.")
        raise OSError(code, os.strerror(code), os.fspath(destination))


def remove_staging(path):
    # Read-only payload directories must still be removable after a failed copy.
    for current, directories, _ in os.walk(path):
        os.chmod(current, 0o700)
        for name in directories:
            child = Path(current) / name
            if not child.is_symlink():
                os.chmod(child, 0o700)
    shutil.rmtree(path)


def stage_install(payload, destination, *, dry_run=False, verify=False):
    payload, destination = absolute_path(payload), absolute_path(destination)
    reject_symlinks(payload)
    reject_symlinks(destination)
    repository = payload.parent
    if repository == destination or repository in destination.parents or destination in repository.parents:
        raise InstallError("Source repository and destination must not overlap.")
    if not payload.is_dir():
        raise InstallError(f"Payload directory is missing: {payload}")
    manifest = inventory(payload)
    if not manifest["files"]:
        raise InstallError("Payload has no files; nothing was installed.")
    top_level = {Path(name).parts[0].casefold() for group in manifest.values() for name in group}
    if top_level & {name.casefold() for name in RESERVED}:
        raise InstallError("Payload contains a reserved installer metadata path.")
    receipt = {"format": 1, "package": "nightriderco-stream-tools", "payload": manifest}
    result = {"destination": str(destination), "files": len(manifest["files"]), "changed_config": []}
    if destination.exists():
        if not destination.is_dir():
            raise InstallError("Destination exists and is not a directory.")
        result["changed_config"] = verify_existing(destination, manifest, receipt)
        result["status"] = "verified" if verify else "unchanged"
        return result
    if verify:
        raise InstallError("Destination does not exist; there is nothing to verify.")
    if not destination.parent.is_dir():
        raise InstallError("Destination parent must already exist. Create it and retry.")
    if dry_run:
        result["status"] = "dry-run"
        return result

    staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.staging-", dir=destination.parent))
    try:
        for name in sorted(manifest["directories"], key=lambda value: (len(Path(value).parts), value)):
            (staging / name).mkdir()
        for name, metadata in manifest["files"].items():
            with open_regular(payload / name) as source, (staging / name).open("xb") as target:
                shutil.copyfileobj(source, target)
            os.chmod(staging / name, metadata["mode"])
        for name, mode in sorted(manifest["directories"].items(), reverse=True):
            os.chmod(staging / name, mode)
        if inventory(staging) != manifest:
            raise InstallError("Payload changed while copying; installation was cancelled.")
        (staging / SETUP).write_text(setup_text(destination, manifest), encoding="utf-8")
        (staging / RECEIPT).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        for name in RESERVED:
            os.chmod(staging / name, 0o644)
        rename_without_replacement(staging, destination)
    finally:
        if staging.exists():
            remove_staging(staging)
    result["status"] = "installed"
    return result


def main(arguments=None, *, payload=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", default=DEFAULT_DESTINATION, help="new install folder (default: %(default)s)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="validate the plan without writing files")
    mode.add_argument("--verify", action="store_true", help="check an existing installation without changing it")
    args = parser.parse_args(arguments)
    source = payload if payload is not None else Path(__file__).absolute().parent / "payload"
    try:
        result = stage_install(source, args.destination, dry_run=args.dry_run, verify=args.verify)
    except (InstallError, OSError) as error:
        print(f"Installation stopped: {error}", file=sys.stderr)
        return 1
    labels = {"installed": "Files staged", "dry-run": "Dry run passed; no files written", "unchanged": "Already installed; no files changed", "verified": "Installation verified"}
    print(f"{labels[result['status']]}: {result['destination']} ({result['files']} payload files)")
    if result["changed_config"]:
        print("Preserved edited configuration: " + ", ".join(result["changed_config"]))
    print("No services started. Complete manual setup using the repository README.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
