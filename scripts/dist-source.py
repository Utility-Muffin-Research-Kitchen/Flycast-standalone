#!/usr/bin/env python3
"""Create or verify complete, deterministic Flycast corresponding source."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path("workdir/mlp1/flycast")
FLAGS = Path("workdir/build-inputs")
RECEIPT = "corresponding-source.json"


def git(repo, *args):
    return subprocess.check_output(
        ["git", "-c", "safe.directory=*", "-C", str(repo), *args])


def sha256(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def upstream(root):
    values = dict(line.split("=", 1) for line in
                  (root / "upstream.env").read_text().splitlines()
                  if line.startswith("FLYCAST_"))
    return {"commit": values["FLYCAST_UPSTREAM_SHA"],
            "tag": values["FLYCAST_UPSTREAM_TAG"],
            "epoch": int(values["FLYCAST_SOURCE_DATE_EPOCH"]),
            "package_version": values["FLYCAST_PACKAGE_VERSION"]}


def files(root):
    for path in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix()):
        # CMake regenerates this header from the locked identity on every build.
        if path.relative_to(root).as_posix() == "core/version.h":
            continue
        if path.is_symlink() or path.is_file():
            yield path


def tree_sha256(root):
    digest = hashlib.sha256()
    for path in files(root):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            content = "link:" + os.readlink(path)
        else:
            mode = "755" if path.stat().st_mode & 0o111 else "644"
            content = mode + ":" + sha256(path)
        digest.update(name.encode() + b"\0" + content.encode() + b"\0")
    return digest.hexdigest()


def lock(root):
    return json.loads((root / "locks/build-inputs.lock.json").read_text())


def verify_flags(root, inputs):
    for entry in inputs["flags"]["files"]:
        path = root / FLAGS / entry["path"]
        if not path.is_file() or path.is_symlink() or sha256(path) != entry["sha256"]:
            raise SystemExit(f"source archive: locked flag file differs: {entry['path']}")


def verify(root):
    receipt = json.loads((root / RECEIPT).read_text())
    inputs = lock(root)
    if (receipt["schema"] != 1 or receipt["upstream"] != upstream(root) or
            receipt["patches"] != inputs["patches"]["entries"] or
            receipt["submodules"] != inputs["submodules"]["entries"]):
        raise SystemExit("source archive: receipt does not match the declared build inputs")
    subprocess.run(["python3", str(root / "scripts/check-build-lock.py"), "patches",
                    str(root / "locks/build-inputs.lock.json"), str(root / "patches")], check=True)
    verify_flags(root, inputs)
    if tree_sha256(root / SOURCE) != receipt["source_sha256"]:
        raise SystemExit("source archive: source files or executable modes differ from the receipt")
    print("source archive: complete patched source, submodules and flags verified")


def export_git(repo, revision, root, prefix=""):
    # Submodules contain relative links to sibling sources. Validate links
    # against the whole distribution, not just that submodule's directory.
    with tarfile.open(fileobj=io.BytesIO(git(repo, "archive", "--format=tar",
                                          f"--prefix={prefix}", revision))) as archive:
        archive.extractall(root, filter="data")


def write_archive(root, output, epoch):
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    with temporary.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0,
                           compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.GNU_FORMAT) as archive:
                for path in files(root):
                    name = "flycast-source/" + path.relative_to(root).as_posix()
                    entry = tarfile.TarInfo(name)
                    entry.mtime = epoch
                    if path.is_symlink():
                        entry.type = tarfile.SYMTYPE
                        entry.mode = 0o777
                        entry.linkname = os.readlink(path)
                        archive.addfile(entry)
                    else:
                        entry.size = path.stat().st_size
                        entry.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                        with path.open("rb") as data:
                            archive.addfile(entry, data)
    temporary.replace(output)


def create(root, output):
    if git(root, "status", "--porcelain", "--untracked-files=normal").strip():
        raise SystemExit("source archive: commit the packaging changes first")
    inputs = lock(root)
    identity = upstream(root)
    source = root / SOURCE
    if git(source, "rev-parse", "HEAD").decode().strip() != identity["commit"]:
        raise SystemExit("source archive: cached upstream checkout is not at the locked commit")
    if int(git(source, "show", "-s", "--format=%ct", "HEAD")) != identity["epoch"]:
        raise SystemExit("source archive: upstream timestamp differs from the lock")
    verify_flags(root, inputs)
    with tempfile.TemporaryDirectory(prefix="flycast-source-") as tmp:
        staging = Path(tmp)
        # Export committed objects, not a developer's patched or dirty cache.
        export_git(root, "HEAD", staging)
        export_git(source, identity["commit"], staging, f"{SOURCE}/")
        for entry in inputs["submodules"]["entries"]:
            export_git(source / entry["path"], entry["sha"], staging,
                       f"{SOURCE}/{entry['path']}/")
        for entry in inputs["patches"]["entries"]:
            patch = staging / entry["path"]
            if sha256(patch) != entry["sha256"]:
                raise SystemExit(f"source archive: patch hash differs: {entry['path']}")
            subprocess.run(["git", "apply", str(patch)], cwd=staging / SOURCE,
                           env={**os.environ, "GIT_CEILING_DIRECTORIES": str(staging)}, check=True)
        for entry in inputs["flags"]["files"]:
            destination = staging / FLAGS / entry["path"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / FLAGS / entry["path"], destination)
        receipt = {
            "schema": 1,
            # A PR merge and its head can have the same source tree. Do not let
            # their different commit timestamps/parents change these bytes.
            "packaging_tree": git(root, "rev-parse", "HEAD^{tree}").decode().strip(),
            "upstream": identity,
            "patches": inputs["patches"]["entries"],
            "submodules": inputs["submodules"]["entries"],
            "source_sha256": tree_sha256(staging / SOURCE),
        }
        (staging / RECEIPT).write_text(json.dumps(receipt, indent=2) + "\n")
        verify(staging)
        write_archive(staging, output, identity["epoch"])
    print(f"source_archive={output}")
    print(f"source_sha256={sha256(output)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("create", "verify"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.action == "verify":
        verify(ROOT)
    else:
        create(ROOT, args.output or ROOT / "output/dist" /
               f"flycast-{upstream(ROOT)['package_version']}-source.tar.gz")
