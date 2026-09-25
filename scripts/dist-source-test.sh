#!/usr/bin/env bash
# Compare an ordinary build with a complete source-archive rebuild, offline.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/upstream.env"
archive="$ROOT/output/dist/flycast-$FLYCAST_PACKAGE_VERSION-source.tar.gz"
original="$ROOT/output/mlp1/flycast"
[ -f "$original/manifest.json" ] || { echo 'run make package-mlp1 first' >&2; exit 1; }
check="$(mktemp -d "$ROOT/output/source-check.XXXXXX")"
trap 'rm -rf "$check"' EXIT

# Output name, process timezone and umask cannot affect the archive bytes.
(umask 000; TZ=Pacific/Fiji python3 "$ROOT/scripts/dist-source.py" create --output "$check/second.tar.gz")
cmp "$archive" "$check/second.tar.gz"
echo 'source archive is byte-identical with another output path, timezone and umask'
python3 - "$archive" "$check" <<'PY'
import importlib.util, json, pathlib, subprocess, sys, tarfile
with tarfile.open(sys.argv[1]) as archive:
    assert not any('.git' in pathlib.PurePosixPath(m.name).parts for m in archive)
    archive.extractall(sys.argv[2], filter='data')
root = pathlib.Path(sys.argv[2]) / 'flycast-source'
spec = importlib.util.spec_from_file_location('dist_source', root / 'scripts/dist-source.py')
dist = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dist)
dist.verify(root)

# A damaged source archive must fail before a compile or a download. Cover an
# upstream file, a recursively vendored dependency, a patch and a flag file.
inputs = dist.lock(root)
names = [root / dist.SOURCE / 'CMakeLists.txt',
         root / dist.SOURCE / 'core/deps/rcheevos/LICENSE',
         root / inputs['patches']['entries'][0]['path'],
         root / dist.FLAGS / inputs['flags']['files'][0]['path']]
for path in names:
    saved = path.read_bytes()
    try:
        path.write_bytes(saved + b'\nmodified source fixture\n')
        result = subprocess.run(['python3', str(root / 'scripts/dist-source.py'), 'verify'],
                                capture_output=True, text=True)
        assert result.returncode != 0, f'modified input accepted: {path}'
        assert 'source archive:' in result.stderr or 'build lock mismatch' in result.stderr
    finally:
        path.write_bytes(saved)
path = root / dist.SOURCE / 'CMakeLists.txt'
mode = path.stat().st_mode
try:
    path.chmod(0o755)
    try:
        dist.verify(root)
    except SystemExit as error:
        assert 'modes differ' in str(error)
    else:
        raise AssertionError('changed executable mode accepted')
finally:
    path.chmod(mode)
dist.verify(root)
print('archive checks: complete inputs; altered source, submodule, patch, flags and mode refused')
PY

mkdir "$check/bin"
for tool in git curl wget; do
    cat >"$check/bin/$tool" <<'EOF'
#!/bin/sh
echo "source rebuild attempted a host fetch or Git command: $0 $*" >&2
exit 97
EOF
    chmod +x "$check/bin/$tool"
done
# build-mlp1.sh disables the container network too. Only the extracted archive
# is mounted, and the pinned image is already available from the normal build.
PATH="$check/bin:$PATH" make -C "$check/flycast-source" package-mlp1 >"$check/rebuild.log" 2>&1 || {
    tail -60 "$check/rebuild.log" >&2
    exit 1
}
python3 - "$original" "$check/flycast-source/output/mlp1/flycast" <<'PY'
import hashlib, pathlib, sys
def inventory(root):
    root = pathlib.Path(root)
    return {p.relative_to(root).as_posix():
            (p.stat().st_mode & 0o777, hashlib.sha256(p.read_bytes()).hexdigest())
            for p in root.rglob('*') if p.is_file()}
a, b = map(inventory, sys.argv[1:])
different = sorted(name for name in a.keys() | b.keys() if a.get(name) != b.get(name))
if different:
    raise SystemExit('source rebuild payload differs: ' + ', '.join(different))
print('offline source rebuild: binary and every payload file/mode match')
print('binary_sha256=' + a['bin/flycast'][1])
PY
echo 'dist-source-test: passed'
