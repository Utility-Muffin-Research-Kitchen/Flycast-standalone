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

The build uses the sibling `mlp1-toolchain` Docker image. Upstream source and
all generated artifacts stay in ignored `workdir/` and `output/` directories.

`make package-mlp1` writes `output/mlp1/flycast/`. Leaf will eventually stage
that directory under:

```text
.system/leaf/platforms/mlp1/emulators/flycast/
```

The current default configuration is the captured standalone parity profile:
native 480p GLES, MLP1 rotation, threaded rendering, per-strip sorting, AICA
DSP disabled, and adaptive GPU frame skipping. It deliberately keeps fixed
frame skipping disabled.

The MLP1 build carries one narrow upstream patch: when
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
through Flycast v2.6's native virtual-config options.
The package manifest inventories and hashes every payload file.

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
```

No BIOS or game content is included.
