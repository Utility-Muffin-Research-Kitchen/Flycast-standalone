#!/usr/bin/env python3
"""Host fault injection for Flycast's Leaf account import.

Drives tests/ra_account_fault_probe (the real bridge, contract and
configuration store over tests/fault_shim.c) through launch sequences in a
scratch configuration directory, and checks what each fault must never do:

  - accept a revision whose token did not durably land (stale accepted
    revision),
  - damage the previous emu.cfg,
  - bring back the previously imported account (its stored token) in a
    session Leaf did not vouch for,
  - leak a password or token into output, the log, or the marker.

Every write the import makes is failed (read-only, storage exhausted, I/O
error) and interrupted (the process dies mid-write or before the rename) at
each of its three boundaries: the pending marker, the configuration save, and
the accepted marker. Corrupt and unreadable markers, an unreadable emu.cfg,
a failing log writer and the login callbacks' failure paths are covered too.
All accounts are synthetic.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

PROBE = sys.argv[1] if len(sys.argv) > 1 else ""

ACCOUNT_A = ("leaf-test-a", "Synthetic-Pass-A1", "synthetic-token-a")
ACCOUNT_B = ("leaf-test-b", "Synthetic-Pass-B2", "synthetic-token-b")
SECRETS = [
    ACCOUNT_A[1], ACCOUNT_A[2], ACCOUNT_B[1], ACCOUNT_B[2],
    "synthetic-token-a2", "synthetic-token-sign",
]
MARKER = ".umrk-ra-account"
MARKER_TMP = ".umrk-ra-account.tmp"
CFG = "emu.cfg"
CFG_TMP = "emu.cfg.umrk-tmp"

# A user configuration the import must never lose: global settings, a
# per-game section and the achievement options it does not own.
BASE_CFG = (
    "[config]\n"
    "PerGameVmu = no\n"
    "rend.Resolution = 480\n"
    "\n"
    "[achievements]\n"
    "HardcoreMode = no\n"
    "\n"
    "[T1210N]\n"
    "rend.WideScreen = yes\n"
)

failures: list[str] = []
checks = 0
launches = 0


def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def read(path: str) -> bytes | None:
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except (FileNotFoundError, PermissionError):
        return None


def cfg_keys(directory: str) -> dict[str, str]:
    """The [achievements] keys of emu.cfg (values compared, never printed)."""
    keys: dict[str, str] = {}
    section = ""
    data = read(os.path.join(directory, CFG)) or b""
    for raw in data.decode("utf-8", "replace").splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
        elif section == "achievements" and "=" in line:
            key, value = line.split("=", 1)
            keys[key.strip()] = value.strip()
    return keys


def marker_fields(directory: str) -> dict[str, str] | None:
    data = read(os.path.join(directory, MARKER))
    if data is None:
        return None
    fields: dict[str, str] = {}
    for line in data.decode("utf-8", "replace").splitlines()[1:]:
        key, _, value = line.partition(" ")
        fields[key] = value
    return fields


def account_env(state: str, account=None, revision=None) -> dict[str, str]:
    env = {"UMRK_RA_ACCOUNT_VERSION": "1", "UMRK_RA_ACCOUNT_STATE": state}
    if account is not None:
        env["UMRK_RA_ACCOUNT_USERNAME"] = account[0]
        env["UMRK_RA_ACCOUNT_PASSWORD"] = account[1]
    if revision is not None:
        env["UMRK_RA_ACCOUNT_REVISION"] = str(revision)
    return env


def configured(account, revision) -> dict[str, str]:
    return account_env("configured", account, revision)


class Launch:
    def __init__(self, returncode: int, output: str):
        self.returncode = returncode
        self.output = output
        self.fields: dict[str, str] = {}
        self.notifications: list[str] = []
        for line in output.splitlines():
            key, _, value = line.partition("=")
            if key == "notify":
                self.notifications.append(value)
            else:
                self.fields[key] = value

    def get(self, key: str, default: str = "") -> str:
        return self.fields.get(key, default)

    @property
    def crashed(self) -> bool:
        return self.returncode == 86


def launch(name: str, directory: str, env: dict[str, str] | None = None,
           faults: str = "", args: list[str] | None = None,
           expect_crash: bool = False) -> Launch:
    global launches
    launches += 1
    child_env = {k: v for k, v in os.environ.items()
                 if not k.startswith("UMRK_RA_ACCOUNT_") and not k.startswith("JAWAKA_CHEEVOS_")
                 and k != "UMRK_TEST_FAULTS"}
    child_env.update(env or {})
    if faults:
        child_env["UMRK_TEST_FAULTS"] = faults
    result = subprocess.run(
        [PROBE, "--config-dir", directory] + (args or []),
        env=child_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
    )
    output = result.stdout.decode("utf-8", "replace")
    run = Launch(result.returncode, output)
    if expect_crash:
        check(run.crashed, f"{name}: expected the process to die at the fault, rc={result.returncode}")
    else:
        check(result.returncode == 0, f"{name}: probe exited {result.returncode}")
    # No secret in anything this launch printed or wrote outside emu.cfg.
    log = (read(os.path.join(directory, "flycast.log")) or b"").decode("utf-8", "replace")
    marker = (read(os.path.join(directory, MARKER)) or b"").decode("utf-8", "replace")
    for secret in SECRETS:
        check(secret not in output, f"{name}: a synthetic secret appeared in the probe output")
        check(secret not in log, f"{name}: a synthetic secret appeared in the log")
        check(secret not in marker, f"{name}: a synthetic secret appeared in the marker")
    if not run.crashed:
        check(run.get("env_scrubbed") == "yes", f"{name}: the handoff stayed in the environment")
    return run


def no_leftovers(name: str, directory: str) -> None:
    for temp in (MARKER_TMP, CFG_TMP):
        check(not os.path.exists(os.path.join(directory, temp)),
              f"{name}: a failed write left {temp} behind")


class Card:
    """A scratch config directory; `fork()` copies the current state."""

    root = tempfile.mkdtemp(prefix="flycast-ra-faults-")
    count = 0

    def __init__(self, source: str | None = None):
        Card.count += 1
        self.path = os.path.join(Card.root, f"card-{Card.count}")
        if source is None:
            os.makedirs(self.path)
            with open(os.path.join(self.path, CFG), "w", encoding="utf-8") as handle:
                handle.write(BASE_CFG)
        else:
            shutil.copytree(source, self.path)
        log = os.path.join(self.path, "flycast.log")
        if os.path.exists(log):
            os.remove(log)

    def fork(self) -> "Card":
        return Card(self.path)

    def snapshot(self) -> tuple[bytes | None, bytes | None]:
        return read(os.path.join(self.path, CFG)), read(os.path.join(self.path, MARKER))


def expect_suppressed(name: str, card: Card) -> None:
    """A launch without a handoff while managed state exists: no session with
    the stored (possibly older) account."""
    run = launch(name, card.path)
    check(run.get("login") == "none", f"{name}: authenticated without a handoff ({run.get('login')})")


def expect_fresh_import(name: str, card: Card, account, revision, token) -> None:
    """The next launch with Leaf's current account imports it by password and
    then accepts it: never a reused token."""
    run = launch(name, card.path, configured(account, revision), args=["--server-token", token])
    check(run.get("login") == f"password user={account[0]}",
          f"{name}: expected a password import of {account[0]}, got {run.get('login')!r}")
    check(run.get("status") == "accepted", f"{name}: status {run.get('status')!r}")
    fields = marker_fields(card.path) or {}
    check(fields.get("state") == "accepted" and fields.get("revision") == str(revision)
          and fields.get("account") == account[0],
          f"{name}: marker after re-import is {fields}")
    keys = cfg_keys(card.path)
    check(keys.get("UserName") == account[0] and keys.get("Token") == token,
          f"{name}: emu.cfg does not hold the re-imported account")
    check(read(os.path.join(card.path, CFG)).count(b"PerGameVmu = no") == 1,
          f"{name}: the user's settings did not survive the re-import")


def build_accepted_a() -> Card:
    card = Card()
    run = launch("setup: first import of A", card.path, configured(ACCOUNT_A, 1),
                 args=["--server-token", ACCOUNT_A[2]])
    check(run.get("status") == "accepted", f"setup: status {run.get('status')!r}")
    keys = cfg_keys(card.path)
    check(keys.get("UserName") == ACCOUNT_A[0] and keys.get("Token") == ACCOUNT_A[2],
          "setup: A's token was not saved")
    check(keys.get("HardcoreMode") == "no", "setup: the import dropped an unrelated achievements key")
    return card


WRITE_FAULTS = [
    ("fopen_w", "eacces"), ("fopen_w", "erofs"), ("fwrite", "enospc"),
    ("fflush", "enospc"), ("fsync", "eio"), ("fclose", "enospc"), ("rename", "eio"),
]
CRASH_FAULTS = [("fwrite", "partial"), ("fsync", "crash"), ("rename", "crash")]


def scenario_baseline(accepted_a: Card) -> None:
    card = accepted_a.fork()
    run = launch("baseline: token reuse", card.path, configured(ACCOUNT_A, 1))
    check(run.get("config_established") == "yes", "baseline: a readable emu.cfg is not established")
    check(run.get("login", "").startswith(f"token user={ACCOUNT_A[0]}"),
          f"baseline: expected token reuse, got {run.get('login')!r}")
    check(run.get("status") == "accepted", "baseline: token reuse status")
    control = accepted_a.fork()
    expect_fresh_import("baseline: import B", control, ACCOUNT_B, 2, ACCOUNT_B[2])
    # No emu.cfg at all is a fresh default configuration, not an unknown one.
    fresh = Card()
    os.remove(os.path.join(fresh.path, CFG))
    run = launch("baseline: fresh configuration", fresh.path, configured(ACCOUNT_A, 1),
                 args=["--server-token", ACCOUNT_A[2]])
    check(run.get("config_established") == "yes", "baseline: a missing emu.cfg is not a fresh configuration")
    check(run.get("status") == "accepted", f"baseline: fresh configuration status {run.get('status')!r}")

    # P3 owns direct credential verification before using a custom session
    # host. The bridge must prepare the import instead of refusing it early.
    custom = accepted_a.fork()
    path = os.path.join(custom.path, CFG)
    with open(path, encoding="utf-8") as handle:
        text = handle.read().replace("[achievements]\n", "[achievements]\nHostUrl = http://custom.invalid\n")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    expect_fresh_import("baseline: changed account with custom host", custom, ACCOUNT_B, 2, ACCOUNT_B[2])
    check(cfg_keys(custom.path).get("HostUrl") == "http://custom.invalid",
          "baseline: direct verification changed the saved custom host")


def scenario_pending_marker(accepted_a: Card) -> None:
    for op, mode in WRITE_FAULTS:
        name = f"pending marker {op} {mode}"
        card = accepted_a.fork()
        before = card.snapshot()
        run = launch(name, card.path, configured(ACCOUNT_B, 2), f"{op}:{MARKER_TMP}:{mode}:1")
        check(run.get("status") == "pending-marker-failed", f"{name}: status {run.get('status')!r}")
        check(run.get("login") == "none", f"{name}: authenticated anyway ({run.get('login')})")
        check(card.snapshot() == before, f"{name}: emu.cfg or the marker changed")
        check(bool(run.notifications), f"{name}: the failure was not reported")
        no_leftovers(name, card.path)
        expect_suppressed(f"{name}, then no handoff", card.fork())
        expect_fresh_import(f"{name}, then retry", card, ACCOUNT_B, 2, ACCOUNT_B[2])


def scenario_pending_save(accepted_a: Card) -> None:
    for op, mode in WRITE_FAULTS:
        name = f"pending config save {op} {mode}"
        card = accepted_a.fork()
        cfg_before, _ = card.snapshot()
        run = launch(name, card.path, configured(ACCOUNT_B, 2), f"{op}:{CFG_TMP}:{mode}:1")
        check(run.get("status") == "pending-save-failed", f"{name}: status {run.get('status')!r}")
        check(run.get("login") == "none", f"{name}: authenticated anyway ({run.get('login')})")
        check(read(os.path.join(card.path, CFG)) == cfg_before, f"{name}: the previous emu.cfg changed")
        fields = marker_fields(card.path) or {}
        check(fields.get("state") == "pending" and fields.get("revision") == "2",
              f"{name}: marker {fields} (the old acceptance must be withdrawn)")
        no_leftovers(name, card.path)
        # emu.cfg still holds A's token on disk: it must stay unusable.
        expect_suppressed(f"{name}, then no handoff", card.fork())
        run = launch(f"{name}, then Leaf back at A", card.fork().path, configured(ACCOUNT_A, 1))
        check(run.get("login") == f"password user={ACCOUNT_A[0]}",
              f"{name}: A's stored token came back ({run.get('login')!r})")
        expect_fresh_import(f"{name}, then retry", card, ACCOUNT_B, 2, ACCOUNT_B[2])


def scenario_token_save(accepted_a: Card) -> None:
    for op, mode in WRITE_FAULTS:
        name = f"token save {op} {mode}"
        card = accepted_a.fork()
        run = launch(name, card.path, configured(ACCOUNT_B, 2), f"{op}:{CFG_TMP}:{mode}:2",
                     args=["--server-token", ACCOUNT_B[2]])
        check(run.get("status") == "token-save-failed", f"{name}: status {run.get('status')!r}")
        check(run.get("authenticated") == "no", f"{name}: the session authenticated")
        fields = marker_fields(card.path) or {}
        check(fields.get("state") == "pending", f"{name}: revision accepted without a saved token ({fields})")
        keys = cfg_keys(card.path)
        check(keys.get("Token", "") == "" and keys.get("UserName") == ACCOUNT_B[0],
              f"{name}: emu.cfg is not the pending-import version")
        check(ACCOUNT_A[2].encode() not in read(os.path.join(card.path, CFG)),
              f"{name}: A's token is still in emu.cfg")
        check(read(os.path.join(card.path, CFG)).count(b"PerGameVmu = no") == 1,
              f"{name}: the user's settings were damaged")
        no_leftovers(name, card.path)
        expect_suppressed(f"{name}, then no handoff", card.fork())
        expect_fresh_import(f"{name}, then retry", card, ACCOUNT_B, 2, ACCOUNT_B[2])


def scenario_accept_marker(accepted_a: Card) -> None:
    for op, mode in WRITE_FAULTS:
        name = f"accepted marker {op} {mode}"
        card = accepted_a.fork()
        run = launch(name, card.path, configured(ACCOUNT_B, 2), f"{op}:{MARKER_TMP}:{mode}:2",
                     args=["--server-token", ACCOUNT_B[2]])
        check(run.get("status") == "accept-marker-failed", f"{name}: status {run.get('status')!r}")
        fields = marker_fields(card.path) or {}
        check(fields.get("state") == "pending", f"{name}: marker {fields}")
        check(bool(run.notifications), f"{name}: the failure was not reported")
        no_leftovers(name, card.path)
        expect_suppressed(f"{name}, then no handoff", card.fork())
        # The token landed but the revision was never accepted: the next
        # launch must import again, not trust the unrecorded state.
        expect_fresh_import(f"{name}, then retry", card, ACCOUNT_B, 2, "synthetic-token-b")


def scenario_interrupted(accepted_a: Card) -> None:
    boundaries = [
        ("pending marker", MARKER_TMP, 1),
        ("pending config save", CFG_TMP, 1),
        ("token save", CFG_TMP, 2),
        ("accepted marker", MARKER_TMP, 2),
    ]
    for label, target, nth in boundaries:
        for op, mode in CRASH_FAULTS:
            name = f"interrupted {label} ({op} {mode})"
            card = accepted_a.fork()
            cfg_before, marker_before = card.snapshot()
            launch(name, card.path, configured(ACCOUNT_B, 2), f"{op}:{target}:{mode}:{nth}",
                   args=["--server-token", ACCOUNT_B[2]], expect_crash=True)
            fields = marker_fields(card.path) or {}
            if label == "pending marker":
                check(card.snapshot() == (cfg_before, marker_before),
                      f"{name}: emu.cfg or the marker changed")
            else:
                check(fields.get("state") == "pending" and fields.get("revision") == "2",
                      f"{name}: marker {fields}")
            if label == "pending config save":
                check(read(os.path.join(card.path, CFG)) == cfg_before,
                      f"{name}: the previous emu.cfg was damaged")
            cfg = read(os.path.join(card.path, CFG)) or b""
            check(cfg.count(b"PerGameVmu = no") == 1 and b"rend.WideScreen = yes" in cfg,
                  f"{name}: the user's settings were damaged")
            expect_suppressed(f"{name}, then no handoff", card.fork())
            run = launch(f"{name}, then Leaf back at A", card.fork().path, configured(ACCOUNT_A, 1))
            if label == "pending marker":
                # Nothing changed: A is still the accepted account and Leaf
                # vouches for it again, so reusing its token is correct.
                check(run.get("login", "").startswith(f"token user={ACCOUNT_A[0]}"),
                      f"{name}: expected A's token reuse, got {run.get('login')!r}")
            else:
                check(run.get("login") == f"password user={ACCOUNT_A[0]}",
                      f"{name}: A's stored token came back ({run.get('login')!r})")
            expect_fresh_import(f"{name}, then retry", card, ACCOUNT_B, 2, ACCOUNT_B[2])


CORRUPT_MARKERS = {
    "truncated": b"umrk-ra-account 1\nstate acc",
    "binary": b"\x00\xff\xfe\x01garbage",
    "empty": b"",
    "unknown key": b"umrk-ra-account 1\nstate accepted\nrevision 1\naccount leaf-test-a\ntoken x\n",
    "duplicate state": b"umrk-ra-account 1\nstate accepted\nstate accepted\nrevision 1\naccount leaf-test-a\n",
    "future header": b"umrk-ra-account 2\nstate accepted\nrevision 1\naccount leaf-test-a\n",
    "accepted revision 0": b"umrk-ra-account 1\nstate accepted\nrevision 0\naccount leaf-test-a\n",
    "no account line": b"umrk-ra-account 1\nstate accepted\nrevision 1\n",
    "oversized": b"umrk-ra-account 1\nstate accepted\nrevision 1\naccount leaf-test-a\n" + b"#" * 5000,
}


def scenario_corrupt_marker(accepted_a: Card) -> None:
    for label, content in CORRUPT_MARKERS.items():
        name = f"corrupt marker ({label})"
        card = accepted_a.fork()
        with open(os.path.join(card.path, MARKER), "wb") as handle:
            handle.write(content)
        cfg_before = read(os.path.join(card.path, CFG))
        run = launch(f"{name}, no handoff", card.fork().path)
        check(run.get("login") == "none", f"{name}: A's token came back without a handoff ({run.get('login')!r})")
        run = launch(f"{name}, same account", card.path, configured(ACCOUNT_A, 1),
                     args=["--server-token", "synthetic-token-a2"])
        check(run.get("login") == f"password user={ACCOUNT_A[0]}",
              f"{name}: trusted a corrupt marker ({run.get('login')!r})")
        check(run.get("status") == "accepted", f"{name}: status {run.get('status')!r}")
        check(cfg_before is not None, f"{name}: setup")

    # A marker that exists but cannot be read is managed state that cannot
    # be trusted, exactly like a corrupt one: never "no marker".
    for mode in ("eacces", "eio"):
        name = f"unreadable marker ({mode})"
        card = accepted_a.fork()
        run = launch(f"{name}, no handoff", card.path, faults=f"fopen_r:{MARKER}:{mode}")
        check(run.get("login") == "none",
              f"{name}: an unreadable marker let A's stored token back in ({run.get('login')!r})")
        run = launch(f"{name}, same account", card.path, configured(ACCOUNT_A, 1),
                     faults=f"fopen_r:{MARKER}:{mode}", args=["--server-token", "synthetic-token-a2"])
        check(run.get("login") == f"password user={ACCOUNT_A[0]}",
              f"{name}: reused a token without a readable marker ({run.get('login')!r})")


def scenario_unreadable_config(accepted_a: Card) -> None:
    """emu.cfg exists but cannot be read: the configuration is unknown, and
    the import must not replace the user's whole file with three keys."""
    for mode in ("eio", "eacces"):
        name = f"unreadable emu.cfg ({mode})"
        card = accepted_a.fork()
        cfg_before, _ = card.snapshot()
        run = launch(name, card.path, configured(ACCOUNT_B, 2), f"fopen_r:{CFG}:{mode}",
                     args=["--server-token", ACCOUNT_B[2]])
        check(run.get("config_established") == "no",
              f"{name}: the store reported an unread configuration as established")
        check(read(os.path.join(card.path, CFG)) == cfg_before,
              f"{name}: the import overwrote a configuration it could not read")
        check(run.get("login") == "none", f"{name}: authenticated on an unknown configuration ({run.get('login')!r})")
        check(bool(run.notifications), f"{name}: the failure was not reported")
        no_leftovers(name, card.path)
        fields = marker_fields(card.path) or {}
        check(fields.get("state") != "accepted" or fields.get("revision") != "2",
              f"{name}: accepted a revision it could not save")
        expect_fresh_import(f"{name}, then readable again", card, ACCOUNT_B, 2, ACCOUNT_B[2])


def scenario_failing_log(accepted_a: Card) -> None:
    control = accepted_a.fork()
    launch("log control", control.path, configured(ACCOUNT_B, 2), args=["--server-token", ACCOUNT_B[2]])
    for faults in (f"fopen_w:flycast.log:eacces", f"fwrite:flycast.log:eio", f"fflush:flycast.log:enospc"):
        name = f"failing log ({faults})"
        card = accepted_a.fork()
        run = launch(name, card.path, configured(ACCOUNT_B, 2), faults,
                     args=["--server-token", ACCOUNT_B[2]])
        check(run.get("status") == "accepted", f"{name}: status {run.get('status')!r}")
        check(cfg_keys(card.path) == cfg_keys(control.path), f"{name}: emu.cfg differs from the control")
        check(marker_fields(card.path) == marker_fields(control.path), f"{name}: marker differs from the control")
        # A failure is still shown to the player when nothing can be logged.
        card = accepted_a.fork()
        run = launch(f"{name} + config save failure", card.path, configured(ACCOUNT_B, 2),
                     f"{faults};fwrite:{CFG_TMP}:enospc:1")
        check(run.get("status") == "pending-save-failed", f"{name}: status {run.get('status')!r}")
        check(any("could not prepare" in n for n in run.notifications),
              f"{name}: the failure was not shown with the log down")


def scenario_login_callbacks(accepted_a: Card) -> None:
    for answer in ("reject", "no-token"):
        name = f"import login {answer}"
        card = accepted_a.fork()
        run = launch(name, card.path, configured(ACCOUNT_B, 2), args=["--login", answer])
        check(run.get("status") == "login-failed", f"{name}: status {run.get('status')!r}")
        check(run.get("authenticated") == "no", f"{name}: authenticated")
        check(run.get("pending_one_shot") == "yes", f"{name}: the pending login was offered twice")
        check(any("could not sign in" in n for n in run.notifications), f"{name}: not reported")
        fields = marker_fields(card.path) or {}
        check(fields.get("state") == "pending", f"{name}: marker {fields}")
        check(cfg_keys(card.path).get("Token", "") == "", f"{name}: a token was stored")
        check(ACCOUNT_A[2].encode() not in read(os.path.join(card.path, CFG)),
              f"{name}: A's token is still stored")
        expect_suppressed(f"{name}, then no handoff", card.fork())
        expect_fresh_import(f"{name}, then retry", card, ACCOUNT_B, 2, ACCOUNT_B[2])

    name = "stored token rejected, one password retry"
    card = accepted_a.fork()
    run = launch(name, card.path, configured(ACCOUNT_A, 1),
                 args=["--token-login", "reject", "--retry-login", "ok", "--server-token", "synthetic-token-a2"])
    check(run.get("retry") == f"password user={ACCOUNT_A[0]}", f"{name}: retry {run.get('retry')!r}")
    check(run.get("retry_one_shot") == "yes", f"{name}: more than one retry was offered")
    check(run.get("authenticated") == "yes" and run.get("status") == "accepted", f"{name}: {run.fields}")
    check(cfg_keys(card.path).get("Token") == "synthetic-token-a2", f"{name}: the new token was not saved")

    name = "stored token and retry both rejected"
    card = accepted_a.fork()
    run = launch(name, card.path, configured(ACCOUNT_A, 1),
                 args=["--token-login", "reject", "--retry-login", "reject"])
    check(run.get("status") == "login-failed" and run.get("authenticated") == "no", f"{name}: {run.fields}")

    name = "stored token rejected, retry verified but not saved"
    card = accepted_a.fork()
    run = launch(name, card.path, configured(ACCOUNT_A, 1), f"fwrite:{CFG_TMP}:enospc:1",
                 args=["--token-login", "reject", "--retry-login", "ok", "--server-token", "synthetic-token-a2"])
    check(run.get("status") == "token-save-failed" and run.get("authenticated") == "no", f"{name}: {run.fields}")
    check(cfg_keys(card.path).get("Token") == ACCOUNT_A[2], f"{name}: the previous emu.cfg changed")


def scenario_sign_out(accepted_a: Card) -> None:
    signed_out = account_env("signed-out", revision=2)
    for op, mode in WRITE_FAULTS:
        name = f"sign-out save {op} {mode}"
        card = accepted_a.fork()
        before = card.snapshot()
        run = launch(name, card.path, signed_out, f"{op}:{CFG_TMP}:{mode}:1")
        check(run.get("status") == "sign-out-save-failed", f"{name}: status {run.get('status')!r}")
        check(run.get("login") == "none", f"{name}: authenticated after a sign-out")
        check(card.snapshot() == before, f"{name}: emu.cfg or the marker changed")
        no_leftovers(name, card.path)
        expect_suppressed(f"{name}, then no handoff", card.fork())
        run = launch(f"{name}, then retry", card.path, signed_out)
        check(run.get("status") == "signed-out", f"{name}: retry status {run.get('status')!r}")
        keys = cfg_keys(card.path)
        check(keys.get("Token", "") == "" and keys.get("UserName", "") == "" and keys.get("Enabled") == "no",
              f"{name}: the retry did not clear the account")
        fields = marker_fields(card.path) or {}
        check(fields.get("state") == "signed-out" and fields.get("revision") == "2", f"{name}: marker {fields}")

    for op, mode in WRITE_FAULTS:
        name = f"sign-out marker {op} {mode}"
        card = accepted_a.fork()
        _, marker_before = card.snapshot()
        run = launch(name, card.path, signed_out, f"{op}:{MARKER_TMP}:{mode}:1")
        check(run.get("status") == "sign-out-marker-failed", f"{name}: status {run.get('status')!r}")
        check(run.get("login") == "none", f"{name}: authenticated after a sign-out")
        check(read(os.path.join(card.path, MARKER)) == marker_before, f"{name}: the marker changed")
        check(cfg_keys(card.path).get("Token", "") == "", f"{name}: the account was not cleared")
        no_leftovers(name, card.path)
        expect_suppressed(f"{name}, then no handoff", card.fork())

    for op, mode in CRASH_FAULTS:
        name = f"interrupted sign-out save ({op} {mode})"
        card = accepted_a.fork()
        before = card.snapshot()
        launch(name, card.path, signed_out, f"{op}:{CFG_TMP}:{mode}:1", expect_crash=True)
        check(card.snapshot() == before, f"{name}: emu.cfg or the marker changed")
        run = launch(f"{name}, then retry", card.path, signed_out)
        check(run.get("status") == "signed-out", f"{name}: retry status {run.get('status')!r}")


def scenario_read_only_directory(accepted_a: Card) -> None:
    """A real read-only directory, where the platform allows one."""
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        print("skip real read-only directory: running as root")
        return
    card = accepted_a.fork()
    before = card.snapshot()
    os.chmod(card.path, 0o555)
    try:
        run = launch("read-only config directory", card.path, configured(ACCOUNT_B, 2))
    finally:
        os.chmod(card.path, 0o755)
    check(run.get("status") == "pending-marker-failed", f"read-only directory: status {run.get('status')!r}")
    check(run.get("login") == "none", "read-only directory: authenticated anyway")
    check(card.snapshot() == before, "read-only directory: emu.cfg or the marker changed")

    card = accepted_a.fork()
    os.chmod(os.path.join(card.path, MARKER), 0o000)
    try:
        run = launch("unreadable marker (chmod 000), no handoff", card.path)
    finally:
        os.chmod(os.path.join(card.path, MARKER), 0o644)
    check(run.get("login") == "none",
          f"unreadable marker (chmod 000): A's stored token came back ({run.get('login')!r})")


def main() -> int:
    if not PROBE or not os.access(PROBE, os.X_OK):
        print("usage: run-ra-account-faults.py PROBE", file=sys.stderr)
        return 2
    try:
        accepted_a = build_accepted_a()
        for scenario in (
            scenario_baseline, scenario_pending_marker, scenario_pending_save,
            scenario_token_save, scenario_accept_marker, scenario_interrupted,
            scenario_corrupt_marker, scenario_unreadable_config, scenario_failing_log,
            scenario_login_callbacks, scenario_sign_out, scenario_read_only_directory,
        ):
            before = len(failures)
            scenario(accepted_a)
            status = "ok  " if len(failures) == before else "FAIL"
            print(f"{status} {scenario.__name__[len('scenario_'):].replace('_', ' ')}")
    finally:
        shutil.rmtree(Card.root, ignore_errors=True)
    for failure in failures:
        print(f"  {failure}")
    if failures:
        print(f"{len(failures)} of {checks} fault-injection checks failed")
        return 1
    print(f"All {checks} fault-injection checks passed over {launches} launches.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
