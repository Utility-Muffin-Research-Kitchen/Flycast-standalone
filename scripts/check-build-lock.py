#!/usr/bin/env python3
"""Enforce the declared build inputs in locks/build-inputs.lock.json.

The lock is only worth something if the build refuses to run against anything
else. Each subcommand compares one class of input with the lock and exits
non-zero, naming the difference, on any mismatch:

  patches LOCK PATCH_DIR          the ordered patch series and each file's sha256
  submodules LOCK STATUS_FILE     `git submodule status --recursive` output
                                  ("-" reads standard input)
  toolchain LOCK PLATFORM [TRIPLE]
                                  the image's os/architecture and cross triple

Nothing here downloads or modifies anything, so fetch-upstream.sh and
build-mlp1.sh run it before they touch the source tree or start a container.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

STATUS_RE = re.compile(r"^(?P<flag>[ +\-U])(?P<sha>[0-9a-f]{40}) (?P<path>\S+)(?: \(.*\))?$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")


def fail(message: str) -> None:
    raise SystemExit(f"build lock mismatch: {message}")


def load_lock(path: str) -> dict:
    try:
        lock = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail(f"cannot read {path}: {exc}")
    if not isinstance(lock, dict):
        fail(f"{path} is not a JSON object")
    return lock


def entries(lock: dict, key: str) -> list[dict]:
    section = lock.get(key)
    rows = section.get("entries") if isinstance(section, dict) else None
    if not isinstance(rows, list) or not rows or not all(isinstance(r, dict) for r in rows):
        fail(f"the lock has no {key}.entries list")
    return rows


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_patches(lock_path: str, patch_dir: str) -> None:
    lock = load_lock(lock_path)
    expected = []
    for row in entries(lock, "patches"):
        path, digest = row.get("path"), row.get("sha256")
        if not isinstance(path, str) or not path.startswith("patches/") or "/" in path[8:]:
            fail(f"invalid locked patch path: {path!r}")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            fail(f"invalid locked sha256 for {path}")
        expected.append((path[len("patches/"):], digest))

    directory = Path(patch_dir)
    if not directory.is_dir():
        fail(f"missing patch directory: {patch_dir}")
    # Byte order, as fetch-upstream.sh applies them (LC_ALL=C sort).
    names = sorted(
        (p.name for p in directory.iterdir() if p.is_file() and p.name.endswith(".patch")),
        key=lambda name: name.encode("utf-8"),
    )
    expected_names = [name for name, _ in expected]
    if names != expected_names:
        fail(
            "patch series differs from the lock; "
            f"locked {expected_names}, found {names}"
        )
    for name, digest in expected:
        actual = sha256_file(directory / name)
        if actual != digest:
            fail(f"patches/{name} sha256 {actual}, locked {digest}")
    print(f"patch series matches the lock ({len(expected)} patch{'es' if len(expected) != 1 else ''})")


def check_submodules(lock_path: str, status_path: str) -> None:
    lock = load_lock(lock_path)
    expected = []
    for row in entries(lock, "submodules"):
        path, sha = row.get("path"), row.get("sha")
        if not isinstance(path, str) or not path or not isinstance(sha, str) or not SHA1_RE.fullmatch(sha):
            fail(f"invalid locked submodule row: {row!r}")
        expected.append((path, sha))

    text = sys.stdin.read() if status_path == "-" else Path(status_path).read_text(encoding="utf-8")
    actual = []
    for line in text.splitlines():
        if not line.strip():
            continue
        match = STATUS_RE.match(line)
        if match is None:
            fail(f"unparseable submodule status line: {line!r}")
        if match.group("flag") != " ":
            # "-" not initialized, "+" checked out at another commit than the
            # superproject records, "U" merge conflict: none is the locked tree.
            fail(f"submodule {match.group('path')} is not checked out at its recorded commit "
                 f"(status {match.group('flag')!r})")
        actual.append((match.group("path"), match.group("sha")))

    expected_map = dict(expected)
    actual_map = dict(actual)
    if len(expected_map) != len(expected) or len(actual_map) != len(actual):
        fail("duplicate submodule path")
    missing = sorted(set(expected_map) - set(actual_map))
    extra = sorted(set(actual_map) - set(expected_map))
    if missing or extra:
        fail(f"submodule set differs from the lock; missing {missing}, unlocked {extra}")
    for path, sha in expected:
        if actual_map[path] != sha:
            fail(f"submodule {path} at {actual_map[path]}, locked {sha}")
    print(f"submodules match the lock ({len(expected)} entries)")


def check_toolchain(lock_path: str, platform: str, triple: str | None) -> None:
    lock = load_lock(lock_path)
    toolchain = lock.get("toolchain")
    if not isinstance(toolchain, dict):
        fail("the lock has no toolchain section")
    locked_platform = toolchain.get("platform")
    locked_triple = toolchain.get("cross_triple")
    if not isinstance(locked_platform, str) or not locked_platform:
        fail("the lock has no toolchain.platform")
    if not isinstance(locked_triple, str) or not locked_triple:
        fail("the lock has no toolchain.cross_triple")
    if platform != locked_platform:
        fail(f"toolchain image platform {platform!r}, locked {locked_platform!r}")
    if triple is not None and triple != locked_triple:
        fail(f"toolchain cross triple {triple!r}, locked {locked_triple!r}")
    print(f"toolchain matches the lock ({locked_platform}, {locked_triple})")


def main(argv: list[str]) -> None:
    if len(argv) >= 2 and argv[1] == "patches" and len(argv) == 4:
        check_patches(argv[2], argv[3])
    elif len(argv) >= 2 and argv[1] == "submodules" and len(argv) == 4:
        check_submodules(argv[2], argv[3])
    elif len(argv) >= 2 and argv[1] == "toolchain" and len(argv) in (4, 5):
        check_toolchain(argv[2], argv[3], argv[4] if len(argv) == 5 else None)
    elif len(argv) >= 2 and argv[1] == "cross-triple" and len(argv) == 3:
        # Print the locked triple for the container, which checks its own.
        toolchain = load_lock(argv[2]).get("toolchain")
        if not isinstance(toolchain, dict) or not toolchain.get("cross_triple"):
            fail("the lock has no toolchain.cross_triple")
        print(toolchain["cross_triple"])
    else:
        raise SystemExit(
            "usage: check-build-lock.py patches LOCK PATCH_DIR | "
            "submodules LOCK STATUS_FILE | toolchain LOCK PLATFORM [TRIPLE] | "
            "cross-triple LOCK"
        )


if __name__ == "__main__":
    main(sys.argv)
