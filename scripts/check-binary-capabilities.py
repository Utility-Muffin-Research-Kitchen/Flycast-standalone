#!/usr/bin/env python3
"""Check that a Flycast binary and its capability records agree.

Jawaka hands a payload the Leaf account snapshot only when it carries the
ra-account-v1 record, and the route intent only when it also carries
ra-route-v1. A record is therefore a promise about the binary next to it: a
payload must never carry one for code it does not contain, and the MLP1 build
must never ship that code without its record.

  check-binary-capabilities.py BINARY RECORD_DIR [RECORD_DIR...]

Each RECORD_DIR (the repository's config/mlp1, an assembled package) must hold
every record below, containing exactly its capability id, and BINARY must
contain every marker string of every record. The markers are the values the
consumer code itself uses: the handoff variables it reads, the marker file it
writes, the fixed readiness endpoint and session host it talks to.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Always required: achievements are compiled in, not merely available upstream.
BASE_MARKERS = [b"retroachievements.org"]

RECORDS = {
    "ra-account-v1": (
        "standalone-ra-account-v1",
        [b"UMRK_RA_ACCOUNT_VERSION", b"UMRK_RA_ACCOUNT_PASSWORD", b"umrk-ra-account"],
    ),
    "ra-route-v1": (
        "umrk-flycast-ra-route-v1",
        [b"UMRK_FLYCAST_RA_ROUTE", b"/leaf/health", b"http://127.0.0.1:8080"],
    ),
}


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("usage: check-binary-capabilities.py BINARY RECORD_DIR [RECORD_DIR...]", file=sys.stderr)
        return 2
    binary_path = Path(argv[1])
    try:
        binary = binary_path.read_bytes()
    except OSError as exc:
        print(f"capability check: cannot read {binary_path}: {exc}", file=sys.stderr)
        return 1

    problems: list[str] = []
    for marker in BASE_MARKERS:
        if marker not in binary:
            problems.append(f"binary lacks {marker.decode()!r}")

    for record, (capability, markers) in RECORDS.items():
        for marker in markers:
            if marker not in binary:
                problems.append(f"binary lacks {marker.decode()!r}, which {record} promises")
        for directory in argv[2:]:
            path = Path(directory) / record
            if not path.is_file():
                problems.append(f"{path} is missing")
                continue
            content = path.read_bytes().decode("utf-8", "replace").strip()
            if content != capability:
                problems.append(f"{path} names {content!r}, not {capability!r}")

    if problems:
        for problem in problems:
            print(f"capability check: {problem}", file=sys.stderr)
        return 1
    print(f"capability check: {binary_path.name} carries "
          + ", ".join(RECORDS) + f" (records in {len(argv) - 2} location(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
