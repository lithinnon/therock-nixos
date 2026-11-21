# therock-nixos

AMD [TheRock](https://github.com/ROCm/TheRock) (ROCm ≥ 10) for NixOS as **the
one ROCm**: one copy per version and GPU target, shared by every program and
Python venv that uses the GPU, instead of a 4–9 GB copy per project.

Programs get ROCm only by being linked to therock-nixos, in their derivation
or their flake. The system itself carries diagnostics (`rocminfo`, `amd-smi`)
and nothing an unlinked program could pick up: no `ROCM_PATH`, no compiler,
no nix-ld. The NixOS module fails the build if another ROCm (nixpkgs'
`rocmPackages`, an upstream flake's) gets into the system, and says what
pulls it in.

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
   what programs link at runtime                       what they build against: hipcc, headers, CMake
```

## Use

| | How a program gets ROCm |
|---|---|
| Python (torch, flash-attn) | uv2nix project: `nix flake init -t github:lithinnon/therock-nixos` |
| HIP/C++ from source | `rock.hook` in `nativeBuildInputs`: `nix flake init -t github:lithinnon/therock-nixos#hip` |
| Prebuilt package on another ROCm | `rock.relink pkg`: moved onto TheRock without recompiling |
| Development | `therock.lib.mkShell { gfx; ... }`, or `nix develop github:lithinnon/therock-nixos#gfx1151` |
| The system | `therock.nixosModules.default`: diagnostics + the one-ROCm check |

`rock` is `therock.lib.mkTheRock { pkgs; gfx; version? }` (or, on NixOS,
`config.therock.rock`): `runtime`, `sdk`, `hook`, `relink`, `aotriton` and the
per-wheel store paths. Several targets share one prefix
(`gfx = [ "gfx1100" "gfx1151" ]`, a machine with mixed GPUs): the set is
canonical (sorted, deduplicated, named `gfx1100+gfx1151`), so the system, dev
shells and venvs given the same GPUs in any order get the same store paths.
Adding a GPU to a set costs only its kernel wheels; everything else is shared. Everything is built with therock-nixos'
nixpkgs pin, so projects (with `nixpkgs.follows = "therock/nixpkgs"`) and the
system get the same store paths: one ROCm on disk.

| Output | What |
|---|---|
| `.#runtime-gfx1151` | ROCm runtime + libraries + kernels (4.3 GB closure): what programs link |
| `.#sdk-gfx1151` | runtime + devel (7.4 GB): `hipcc`, headers, CMake packages |
| `devShells.gfx1151` | the SDK with `GPU_TARGETS` & co. set |
| `nix run .#gpu-check [gfx]` | verify on this GPU: rocminfo, amd-smi, HIP kernel, rocBLAS vs CPU |
| `nix run .#update -- VERSION [gfx...]` | hash a release/target into `versions/VERSION.nix` |

Hashed targets for 10.2.0: gfx1100, gfx1151. Published by AMD: gfx90a/908/942/950,
gfx101x, gfx103x, gfx110x, gfx115x, gfx120x, gfx1250. Adding one downloads only
its device wheel (~0.5 GB) and AOTriton images; core/libraries/devel are shared.

**NixOS:**

```nix
inputs.therock.url = "github:lithinnon/therock-nixos";  # don't make it follow your nixpkgs
# in a module, with therock.nixosModules.default imported:
therock = {
  enable = true;
  gfx = [ "gfx1151" ];
  # miopenFindMode = "FAST";  # system-wide; uv2nix venvs do it after a suspend
  # exclusive = false;        # allow other ROCms in the system
};
environment.systemPackages = [ (config.therock.rock.relink pkgs.some-rocm-app) ];
```

Puts `rocminfo`, `amd-smi` and `rocm_agent_enumerator` on `PATH`
(`therock.binaries`). ROCm is built with therock-nixos' own pin
(`therock.pkgs`), so the system shares store paths with projects on the same
therock-nixos revision whatever nixpkgs the system uses.

**Relinking** (`rock.relink pkg`) copies `pkg`'s outputs and rewrites every
reference to the other ROCm: RPATHs and library dirs (`LD_LIBRARY_PATH` in
wrappers) to the runtime, ROCm roots (`ROCM_PATH`-like variables, compilers)
to the SDK. TheRock has the same sonames (`libamdhip64.so.7`, …) with a newer
HIP, so this works for programs that load or link HIP; the build fails if a
reference can't be moved, or if `pkg` reaches the other ROCm through another
package (relink that one first). GPU code objects compiled by the other ROCm
still load; programs that check their toolchain version (hipfire) recompile
them with the SDK on first use instead.

**HIP/C++** (`templates/hip`): `rock.hook` sets `ROCM_PATH`, `HIPCXX`,
`GPU_TARGETS` (also as a CMake toolchain file, since ROCm's CMake packages
read it as a variable and otherwise probe for a GPU), puts `hipcc` on `PATH`
and the SDK on `CMAKE_PREFIX_PATH`. After the build it points RPATHs from the
SDK to the runtime, so the result needs the 4.3 GB runtime, not the SDK
(`dontTherockRuntime = true` keeps them). CMake's HIP language,
`find_package(hip/rocblas/...)` and plain `hipcc` all work. `hipcc` also works
without any environment; `amdclang++` needs `--rocm-path=$SDK` for library
headers.

**uv2nix projects:**

```sh
nix flake init -t github:lithinnon/therock-nixos
nix run .#lock      # uv lock + hashes for this machine's GPU
nix develop         # python, torch on the GPU, uv (`uv run` uses the Nix venv)
```

`therock.lib.uv2nix { pkgs; lockFile = ./uv.lock; }` gives an overlay
(`overlay gfx`), `venvSpec`, `perTarget`, `shell` and `lockApp`. AMD's
`rocm-sdk-*` wheels become placeholders: their metadata plus symlinks into the
runtime, and a startup hook (`therock.pth`) providing libstdc++ & co., libc
headers for MIOpen's JIT, and `MIOPEN_FIND_MODE=FAST` after a suspend (GPU
timers break, [ROCm/MIOpen#3964](https://github.com/ROCm/MIOpen/issues/3964)).
`nix run .#lock` never downloads or hashes them (~4 GB less). The shell has a
C compiler for Triton and `torch.compile`. Depend on `torch[device-gfxNNNN]`
and `torchvision[device-gfxNNNN]`: their GPU kernels (and AOTriton's) are in
those extras.

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

The overlay builds both, including aiter's `module_aiter_core` (otherwise
JIT-compiled on first import, ~15 s, needing the full SDK and ninja). On
gfx1151 it runs at ~15 TFLOP/s (bf16, causal, fwd), 18–24× torch's MATH
attention; torch's own SDPA (AOTriton) is as fast for plain attention,
flash-attn adds sliding windows, varlen and paged KV.

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
- **CMake package configs** find their prefix from their real path, so the
  farm copies them (a few MB) instead of linking.

## Status

Verified on gfx1151 (Strix Halo) with TheRock 10.2.0 and torch 2.15.0:
`hipcc` and the HIP template (CMake, rocBLAS) build and run, `rocminfo` and
`amd-smi` work, in uv2nix venvs torch matmul, MIOpen conv, SDPA (AOTriton),
Triton, `torch.compile`, torchvision 0.29.2 and flash-attn work, and hipfire
(built upstream on nixpkgs' ROCm 7.2) runs relinked onto TheRock.
`nix flake check` builds HIP programs in the sandbox and tests relinking and
the one-ROCm check.

Not included in the wheels compared to AMD's tarball: Composable Kernel C++
headers and instance libraries, hipTensor, rocALUTION, RDC, and the
rocprofiler-systems/compute profilers (those are in the `rocm-profiler` wheel).
