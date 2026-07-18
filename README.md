# Flycast Standalone for Leaf / Miniloong Pocket 1

Reproducible standalone Flycast builds for Leaf on the Miniloong Pocket 1.
The first target is performance and compatibility parity with the validated
MinUI reference while using the latest stable upstream Flycast release.

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

No BIOS or game content is included.
