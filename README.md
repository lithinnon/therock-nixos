# therock-nixos

AMD [TheRock](https://github.com/ROCm/TheRock) (ROCm ≥ 10) for NixOS: **one
ROCm per version and GPU target**, shared by the system, `hipcc`, and every
Python venv, instead of a 4–9 GB copy per project.

## How it works

TheRock ships ROCm as wheels split like NVIDIA's CUDA redistributables:
`rocm-sdk-core` (runtime, compiler), `rocm-sdk-libraries` (BLAS, MIOpen, …),
`rocm-sdk-device-<gfx>` (kernels for one GPU) and `rocm-sdk-devel` (headers,
CMake, dev links). Each becomes one store path, unpacked as-is. AMD's shared
libraries are never re-patched: they are already patchelf'd upstream and break
if touched again. Only executables get a Nix interpreter.

A per-target **symlink farm** (~1 MB) merges them into the flat prefix AMD's
tools expect. ROCm libraries resolve siblings and kernel data relative to the
path they are loaded from, so the farm behaves like the merged tree while the
bytes stay shared.

```
store:  rocm-sdk-core │ rocm-sdk-libraries │ rocm-sdk-device-gfx1151 │ rocm-sdk-devel
                        └──────────────┬──────────────┘                     │
        rocm-runtime-10.2.0-gfx1151 (farm) ────────── + ─────────────► rocm-sdk-10.2.0-gfx1151 (farm)
                │                                                           │
     Python venvs (`therock link`)                                ROCM_PATH: hipcc, CMake, C++
```

## Use

| Output | What |
|---|---|
| `.#runtime-gfx1151` | ROCm runtime + libraries + kernels (4.6 GB closure): what torch needs |
| `.#sdk-gfx1151` | runtime + devel (7.9 GB): `ROCM_PATH` for `hipcc`, headers, CMake |
| `.#therock-gfx1151` | `therock` CLI |
| `lib.mkTheRock { pkgs; gfx; version? }` | all of the above, also for several targets in one prefix (`gfx = [ "gfx1100" "gfx1151" ]`) |
| `nix run .#gpu-check [gfx]` | verify on this GPU: rocminfo, amd-smi, HIP kernel, rocBLAS vs CPU |
| `nix run .#update -- VERSION [gfx...]` | hash a release/target into `versions/VERSION.nix` |

Hashed targets for 10.2.0: gfx1100, gfx1151. Published by AMD: gfx90a/908/942/950,
gfx101x, gfx103x, gfx110x, gfx115x, gfx120x, gfx1250. Adding one downloads only
its device wheel (~0.5 GB) and AOTriton images; core/libraries/devel are shared.

**NixOS:**

```nix
inputs.therock.url = "github:lithinnon/therock-nixos";
# in a module, with therock.nixosModules.default imported:
therock = {
  enable = true;
  gfx = [ "gfx1151" ];        # several targets share one prefix
  # devel = false;            # runtime only (no hipcc/headers): -3.3 GB
  # seamless = true;          # nix-ld + cc: AMD's wheels run unmodified in any uv venv
  # miopenFindMode = "FAST";  # system-wide; venvs from `therock link` do it after suspend
};
```

Sets `ROCM_PATH`/`HIP_PATH` and puts `hipcc`, `rocminfo`, `amd-smi` and
`therock` on `PATH`. `config.therock.rock` exposes the per-wheel store paths
and AOTriton images.

**uv2nix projects:**

```sh
nix flake init -t github:lithinnon/therock-nixos
nix run .#lock      # uv lock + hashes for this machine's GPU
nix develop         # python, torch on the GPU, uv (`uv run` uses the Nix venv)
```

`therock.lib.uv2nix { pkgs; lockFile = ./uv.lock; }` gives an overlay
(`overlay gfx`), `venvSpec`, `perTarget`, `shell` and `lockApp`, the same
interface as rocm-uv2nix. AMD's `rocm-sdk-*` wheels become the same
placeholders `therock link` installs: the venv links to the runtime store path
the system uses, and `nix run .#lock` never downloads or hashes them (~4 GB
less). Sharing needs the same nixpkgs, so the template follows therock's.

**flash-attn** (Triton backend through aiter; both from git, since the PyPI
releases are stale and don't work with Triton 3.9). Add to `pyproject.toml`:

```toml
dependencies = [
  "flash-attn @ git+https://github.com/Dao-AILab/flash-attention@68bd095cdd338c5171bccb9c200529f3620b85c9",
  "amd-aiter @ git+https://github.com/ROCm/aiter@f0966b0aed0b38198e2e1ca1cff8cca343bbcb7e",
]

[tool.uv]
no-build-isolation-package = ["flash-attn"]  # its setup.py imports torch

[tool.uv.extra-build-variables]
flash-attn = { FLASH_ATTENTION_TRITON_AMD_ENABLE = "TRUE", FLASH_ATTENTION_USE_SYSTEM_AITER = "TRUE" }
amd-aiter = { PREBUILD_KERNELS = "0", ENABLE_CK = "0" }

# Static metadata, so `uv lock` builds neither (both need torch and ROCm for it).
[[tool.uv.dependency-metadata]]
name = "flash-attn"
version = "2.8.4"
requires-dist = ["einops", "triton>=3.6.0", "amd-aiter", "setuptools", "wheel", "packaging", "psutil", "ninja"]

[[tool.uv.dependency-metadata]]
name = "amd-aiter"
version = "0.1.23.dev93+gf0966b0ae"
requires-dist = ["pybind11>=3.0.1", "ninja", "pandas", "einops", "psutil", "packaging", "flydsl==0.3.4.1", "pyyaml"]
```

In uv2nix projects the overlay builds both, including aiter's
`module_aiter_core` (otherwise JIT-compiled on first import, ~15 s, needing
the full SDK and ninja). In plain uv projects `uv sync` needs `ROCM_PATH` set
to the SDK (the NixOS module does this), and the first `import aiter` compiles
that module once. On gfx1151 it runs at ~15 TFLOP/s (bf16, causal, fwd), 18–24×
torch's MATH attention; torch's own SDPA (AOTriton) is as fast for plain
attention, flash-attn adds sliding windows, varlen and paged KV.

**C/C++:**

```sh
SDK=$(nix build .#sdk-gfx1151 --print-out-paths --no-link)
$SDK/bin/hipcc --offload-arch=gfx1151 app.hip -o app -lrocblas   # no env needed
cmake -DCMAKE_PREFIX_PATH=$SDK ...                                # find_package(rocblas) etc.
```

`hipcc` defaults `ROCM_PATH`/`HIP_PATH` to the prefix. Calling `amdclang++`
directly needs `--rocm-path=$SDK` for library headers. `hipconfig --path`
reports the core wheel's path.

**Plain uv projects** (standard `pyproject.toml` with AMD's index and
`torch[device-gfx1151]`; `uv.lock` stays portable to non-Nix machines):

```sh
uv venv
nix run .#therock-gfx1151 -- link   # placeholders for rocm-sdk-* -> shared runtime
uv sync                             # fetches torch/triton only, never AMD's ROCm wheels
```

`therock link` installs placeholder `rocm-sdk-core/-libraries/-device-<gfx>`
distributions (metadata + symlinks). uv and pip consider them installed, and
uninstalling them removes only the links. It also adds a startup hook
(`therock.pth`) providing libstdc++ & co., libc headers for MIOpen's JIT, and
`MIOPEN_FIND_MODE=FAST` after a suspend (GPU timers break,
[ROCm/MIOpen#3964](https://github.com/ROCm/MIOpen/issues/3964)). Works with
nixpkgs' Python and with uv-managed Python. Triton needs a C compiler on `PATH`.

## Fixes for upstream gaps

- **AOTriton kernel images.** torch loads them from `torch/lib/aotriton.images`,
  shipped in AMD's per-family wheels (`amd-torch-device-gfx115x`, …) that only
  `torch[device-gfxNNNN]` pulls in. Depending on `amd-torch-device-gfxNNNN`
  directly misses them and fused SDPA fails with `device kernel image is
  invalid`; then AOTriton's release images are linked in as a fallback.
- **No `/usr`.** `rocm.cfg` gets glibc/gcc paths, and libstdc++ sits in the
  bundled sysdeps dir.
- **Wheels can't hold symlinks.** Unversioned `.so` dev names are added to core,
  and devel's relative links are resolved by the farm.

## Status

Verified on gfx1151 (Strix Halo) with TheRock 10.2.0 and torch 2.15.0:
`hipcc` compiles and runs kernels, `rocminfo`/`amd-smi` work, and in plain uv
and uv2nix venvs torch matmul, MIOpen conv, SDPA (AOTriton), Triton and
torchvision 0.29.2 work.
`nix flake check` compiles a HIP program in the sandbox.



Not included in the wheels compared to AMD's tarball: Composable Kernel C++
headers and instance libraries, hipTensor, rocALUTION, RDC, and the
rocprofiler-systems/compute profilers (those are in the `rocm-profiler` wheel).
