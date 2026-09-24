# Flycast Standalone for Leaf / Miniloong Pocket 1

Reproducible standalone Flycast builds for Dreamcast, Atomiswave, Naomi,
Naomi GD-ROM, and Naomi 2 on Leaf for the Miniloong Pocket 1. The first target is performance
and compatibility parity with the validated MinUI reference while using the
latest stable upstream Flycast release.

Primary commands:

```sh
make build-mlp1
make verify-mlp1
make package-mlp1
```

The distributable lane builds inside the digest-pinned published
`mlp1-toolchain` image and the locked flag files recorded in
`locks/build-inputs.lock.json`, so a clean clone needs neither a local
`mlp1-toolchain` checkout nor a locally tagged image. `scripts/fetch-build-inputs.sh`
fetches and hash-verifies the flags; upstream source and all generated artifacts
stay in the ignored `workdir/` and `output/` directories.

The lock also declares the toolchain platform and cross triple, every
upstream submodule commit, and the ordered patch series with each patch's
SHA-256. `scripts/check-build-lock.py` enforces them: `fetch-upstream.sh`
refuses a patch series that differs from the lock before it touches the source
and refuses submodules at other commits after checkout, and `build-mlp1.sh`
refuses a toolchain image of another platform or triple. A patch change
therefore always lands with its lock entry.

The package version, `2.7.0`, is declared once as `FLYCAST_PACKAGE_VERSION` in
`upstream.env`. It is exactly three numeric components, follows the upstream
tag's major and minor version, and is emitted as `package_version` in
`build-manifest.json`; `verify-mlp1-package.sh` rejects any other form.

`make package-mlp1` writes `output/mlp1/flycast/`. Leaf will eventually stage
that directory under:

```text
.system/leaf/platforms/mlp1/emulators/flycast/
```

The current default configuration is the captured standalone parity profile:
native 480p GLES, MLP1 rotation, threaded rendering, per-strip sorting, AICA
DSP disabled, and adaptive GPU frame skipping. It deliberately keeps fixed
frame skipping disabled.

The MLP1 rotation patch applies when
`FLYCAST_UI_ROTATE_90=1`, Flycast lays out its ImGui UI in landscape and rotates
those UI vertices to the portrait-mounted KMS framebuffer. Gameplay continues
to use Flycast's existing `rend.Rotate90` renderer path, so opening the native
menu does not add a full-frame rotation copy to normal emulation.

Flycast's compile-time debug logger is disabled. Its high-frequency CPU and
GD-ROM trace stream can otherwise write more than a megabyte per second to the
SD card and cause audio underruns that do not occur in a release build.

The temporary device probe accepts comma-separated Flycast virtual config
values from `probe-overrides.txt` in the probe root. This keeps tuning arms
isolated from both the packaged defaults and durable user configuration.

The production wrapper keeps configuration under `USERDATA_PATH`, but derives
Flycast data/VMUs and save states from Jawaka's source-specific `SAVES_PATH`
and `STATES_PATH`. It searches the shared RetroArch-compatible `BIOS/dc`
directory, then passes storage, mapping, renderer, and orientation invariants
through Flycast v2.7's native virtual-config options.
The package manifest inventories and hashes every payload file.

Each controller slot keeps one shared VMU (`vmu_save_A1.bin` and so on), as it
did with v2.6. Flycast v2.7 defaults to a separate VMU per game, which would
hide existing saves behind blank per-game cards, so the shipped config and the
version 7 migration set `PerGameVmu = no` unless the player already chose.

The canonical user-supplied files are `BIOS/dc/dc_boot.bin` (optional but
recommended for Dreamcast), `BIOS/dc/awbios.zip`, `BIOS/dc/naomi.zip`, and
`BIOS/dc/naomi2.zip`. Some Naomi games also require their named BIOS archive.
Current Flycast creates its own writable Dreamcast NVRAM; `dc_flash.bin` is not
required.

The MLP1 mapping uses **L2/R2** for Dreamcast's analog triggers. Arcade buttons
1-6 are **A**, **B**, **L1**, **X**, **Y**, and **R1**; **Select** inserts a
coin. Metal Slug 6 therefore uses **L1** for Grenade. **Menu** opens Flycast's
native menu.

Dreamcast defaults to VGA output; Flycast falls back to composite for software
that does not support VGA.

Useful narrow checks:

```sh
make smoke-launch-wrapper
make verify-package-mlp1
make build-lock-test
make package-version-test
```

No BIOS or game content is included.

You can create complete corresponding source from a clean, committed clone:

```sh
make package-mlp1
make test-dist-source
```

The second command writes `output/dist/flycast-2.7.0-source.tar.gz` and checks
that another export has identical bytes. It includes the packaging scripts,
patched Flycast source, all locked recursive submodules and their licences,
and both locked build flag files. You need Python 3.12 or newer to create or
verify the archive. CI uploads it alongside the payload.

To rebuild it, extract the archive and run `make package-mlp1` in
`flycast-source/`. Cache the digest-pinned Docker image first; the build then
needs no Git metadata, sibling checkout or network access. The source receipt
checks the bundled inputs before compilation. A small CMake patch preserves
the locked upstream version and revision when Git metadata is absent.

`make test-dist-source` also rejects modified source, dependency, patch and
flag files, then rebuilds the extracted archive with host Git/download commands
blocked and the container network disabled. It compares the binary and every
packaged file's bytes and permissions against the ordinary build.
