#!/usr/bin/env python3
"""Replay the shared standalone-ra-account-v1 fixtures through the emulator's
own classifier.

The fixtures are the normative ones from public leaf-contracts, fetched at the
revision pinned in locks/contracts.lock.json. Every case is classified by the
compiled probe, which links the very file the device build compiles, so the
consumer and the contract's reference classifier cannot drift apart.
"""
import base64
import json
import subprocess
import sys


def frame(env: "dict[str, bytes]") -> bytes:
    """Length-prefixed framing: fixtures carry bytes (embedded NUL, invalid
    UTF-8) that an environment variable could not represent."""
    out = bytearray()
    for name, value in env.items():
        out += name.encode("ascii") + b"\n"
        out += str(len(value)).encode("ascii") + b"\n"
        out += value
    return bytes(out)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: run-contract-fixtures.py PROBE FIXTURES", file=sys.stderr)
        return 2
    probe, fixtures_path = sys.argv[1], sys.argv[2]
    with open(fixtures_path, "rb") as handle:
        data = json.loads(handle.read().decode("utf-8"))

    failures = 0
    for case in data["cases"]:
        env: "dict[str, bytes]" = {
            key: value.encode("utf-8") for key, value in case.get("env", {}).items()
        }
        for key, value in case.get("env_b64", {}).items():
            env[key] = base64.b64decode(value)

        result = subprocess.run(
            [probe], input=frame(env), stdout=subprocess.PIPE, check=True
        )
        lines = result.stdout.decode("utf-8").splitlines()
        kind, reasons = lines[0], lines[1:]

        expected_kind = case["kind"]
        if kind != expected_kind:
            print(
                f"FAIL {case['name']}: classified {kind!r} (reasons {reasons}), "
                f"expected {expected_kind!r}"
            )
            failures += 1
            continue
        if expected_kind == "invalid-handoff":
            if case["reason"] not in reasons:
                print(
                    f"FAIL {case['name']}: expected reason {case['reason']!r}, "
                    f"got {reasons}"
                )
                failures += 1
                continue
            print(f"ok   {case['name']} -> {case['reason']}")
        else:
            if reasons:
                print(f"FAIL {case['name']}: expected no reasons, got {reasons}")
                failures += 1
                continue
            print(f"ok   {case['name']}")

    total = len(data["cases"])
    if failures:
        print(f"{failures} of {total} standalone-ra-account-v1 fixtures failed")
        return 1
    print(f"All {total} standalone-ra-account-v1 fixtures classified as specified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
