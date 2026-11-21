# therock-nixos

AMD [TheRock](https://github.com/ROCm/TheRock) (ROCm ≥ 10) for NixOS as **the
one ROCm**: one copy per version and set of GPUs, shared by every program,
project and venv that uses the GPU, instead of a 4–9 GB copy per project.

Programs get ROCm only by being linked to therock-nixos, in their derivation
or their flake. The system itself carries diagnostics (`rocminfo`, `amd-smi`)
and nothing an unlinked program could pick up: no `ROCM_PATH`, no compiler,
no nix-ld, no way for a plain `pip`/`uv` venv to find it. The NixOS module
fails the build if another ROCm (nixpkgs' `rocmPackages`, an upstream
flake's) gets into the system, and says what pulls it in.

Projects stay ordinary projects: their `pyproject.toml`, `requirements.txt`
or `CMakeLists.txt` name no GPU and nothing Nix-specific, so the same repo
works for anyone without Nix (who brings their own ROCm torch, as with
CUDA). therock-nixos only adds its own files: `flake.nix`, `flake.lock`,
`.envrc` and, for pip projects, `requirements.uv.lock`.

## How it works

TheRock ships ROCm as wheels split like NVIDIA's CUDA redistributables:
`rocm-sdk-core` (runtime, compiler), `rocm-sdk-libraries` (BLAS, MIOpen, …),
`rocm-sdk-device-<gfx>` (kernels for one GPU) and `rocm-sdk-devel` (headers,
CMake, dev links). Each becomes one store path, unpacked as-is. AMD's shared
libraries are never re-patched: they are already patchelf'd upstream and break
if touched again. Only executables get a Nix interpreter.

A per-set **symlink farm** (~1 MB) merges them into the flat prefix AMD's
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

**GPU sets.** A set of targets is canonical: sorted, deduplicated, named
`gfx1100+gfx1151` (a machine with mixed GPUs). The system, shells, venvs and
HIP builds given the same GPUs get the same store paths; adding a GPU to a
set costs only its kernel wheels. Everything is built with therock-nixos'
nixpkgs pin, so projects on the same therock-nixos revision share the
system's store paths.

## Projects

Every kind of project gets the same outputs. The GPU set is picked when a
command runs, never in the repo: `THEROCK_GFX=gfx1100,gfx1151`, else the NixOS
module's `/etc/therock/targets`, else every AMD GPU in `/sys`.

| | |
|---|---|
| `nix develop` | launcher: enters this machine's set (`.#shells.<set>`) |
| `cd` (direnv) | the same, via `.envrc` (inert without Nix) |
| `nix run .#dev -- CMD` | CMD in that shell (`nix develop -c` can't re-enter) |
| `nix run .#build` | the build for this machine's set (`./result`) |
| `nix build .#gfx1151` | a given target; also families (`.#rdna3`, `.#rdna35`, `.#rdna4`, `.#cdna`, …) and `.#all` |
| `.#shells.<set>`, `.#builds.<set>` | any set of up to three targets (`gfx1100+gfx1151`) |
| `nix run .#set` | the set this machine uses |

A shell warns when it has the system's GPUs but not the system's ROCm (the
project's therock-nixos revision differs: ROCm stored twice).

**Python** (`therock.lib.pytorchProject`). In the project (new or existing):

```sh
nix run github:lithinnon/therock-nixos#init   # adds flake.nix, .envrc, .gitignore lines, locks
nix develop      # Python with ROCm torch for this machine's GPUs, uv, a C compiler
```

```nix
{
  inputs.therock.url = "github:lithinnon/therock-nixos";
  outputs = { therock, ... }: therock.lib.pytorchProject { src = ./.; };
}
```

- **uv projects** (`pyproject.toml` with `[project]`): `uv.lock` is an
  ordinary PyPI lock; `uv lock`/`uv add` in the shell as usual (`uv run` uses
  the Nix venv), or `nix run .#lock`.
- **pip projects** (`requirements.txt`, no `[project]`): the requirements are
  read as pip does (comments, `-r`/`-c` includes; index options ignored) and
  locked for Nix into `requirements.uv.lock` by `nix run .#lock`; no
  `pyproject.toml` is added. `requirements = ./requirements/gpu.txt` picks
  another file. Editable installs and local paths aren't supported (make it a
  uv project).

When building, torch, torchvision and triton are swapped for AMD's ROCm builds
from therock-nixos' own hashed lock (`python/stack`), with the kernels of the
GPU set; the `nvidia-*` packages PyPI's torch pulls in drop out. A locked
torch other than therock's (2.15) gives a warning. Venvs are mostly symlinks:
torch, torchvision and triton are one store path for every set and project;
the set-specific part comes with AMD's `rocm-sdk-*` placeholders (metadata
plus symlinks into the runtime): where torch's kernel packs are
(`ROCM_KPACK_PATH`), a 32 MB copy of libaotriton beside the set's AOTriton
images (both loaders resolve real paths), and a startup hook (`therock.pth`)
providing libstdc++ & co., libc headers for MIOpen's JIT, and
`MIOPEN_FIND_MODE=FAST` after a suspend (GPU timers break,
[ROCm/MIOpen#3964](https://github.com/ROCm/MIOpen/issues/3964)).

`pytorchProject { src; requirements?; overlays?; deps?; packages?; shellHook?; }`
also returns `lib.venv`/`lib.shell` (functions of a GPU set) for custom
outputs.

**flash-attn** (Triton backend through aiter; both from git, since the PyPI
releases are stale and don't work with Triton 3.9). In a uv project:

```toml
dependencies = [
  "flash-attn @ git+https://github.com/Dao-AILab/flash-attention@68bd095cdd338c5171bccb9c200529f3620b85c9",
  "amd-aiter @ git+https://github.com/ROCm/aiter@f0966b0aed0b38198e2e1ca1cff8cca343bbcb7e",
]

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

The overlay builds both (Triton backend, no CK), including aiter's
`module_aiter_core` (otherwise JIT-compiled on first import, ~15 s, needing
the full SDK and ninja). On gfx1151 it runs at ~14 TFLOP/s (bf16, causal,
fwd), ~20× torch's MATH attention; torch's own SDPA (AOTriton) is as fast for
plain attention, flash-attn adds sliding windows, varlen and paged KV.

**HIP/C++** (`therock.lib.hipProject`; `nix flake init -t github:lithinnon/therock-nixos#hip`):

```nix
{
  inputs.therock.url = "github:lithinnon/therock-nixos";
  outputs = { therock, ... }: therock.lib.hipProject { src = ./.; };
}
```

The default package is a CMake + Ninja build of `src`; `package = { pkgs,
rock }: …` replaces it. `rock.hook` sets `ROCM_PATH`, `HIPCXX`, `GPU_TARGETS`
(also as a CMake toolchain file, since ROCm's CMake packages read it as a
variable and otherwise probe for a GPU), puts `hipcc` on `PATH` and the SDK on
`CMAKE_PREFIX_PATH`. After the build it points RPATHs from the SDK to the
runtime, so the result needs the 4.3 GB runtime, not the SDK
(`dontTherockRuntime = true` keeps them). CMake's HIP language,
`find_package(hip/rocblas/...)` and plain `hipcc` all work; `amdclang++`
needs `--rocm-path=$SDK` for library headers.

**Your own flake:** `therock.lib.mkProject { pkgs; flakeRef; ready; version;
shell; build?; apps?; }` gives these outputs for any `shell`/`build` function
of a GPU set; `therock.lib.mkTheRock { pkgs; gfx; version? }` is the ROCm for
a set (`runtime`, `sdk`, `hook`, `relink`, `aotriton`, per-wheel paths), and
`therock.lib.mkShell { gfx; … }` a shell with the SDK.

**Agents:** the Claude Code plugin in this repo has a skill for using
therock-nixos from projects (`/plugin marketplace add lithinnon/therock-nixos`,
then `/plugin install therock-nixos@therock-nixos`); `AGENTS.md` covers
working on the repo itself.

## NixOS

```nix
inputs.therock.url = "github:lithinnon/therock-nixos";  # don't make it follow your nixpkgs
# in a module, with therock.nixosModules.default imported:
therock = {
  enable = true;
  gfx = [ "gfx1151" ];
  # miopenFindMode = "FAST";  # system-wide; Python venvs do it after a suspend
  # exclusive = false;        # allow other ROCms in the system
};
environment.systemPackages = [ (config.therock.rock.relink pkgs.some-rocm-app) ];
```

Puts `rocminfo`, `amd-smi` and `rocm_agent_enumerator` on `PATH`
(`therock.binaries`), and writes the GPU set, release and runtime to
`/etc/therock/{targets,version,runtime}`, where projects' launchers read
them: projects on the machine use exactly the system's set and share its
store paths. ROCm is built with therock-nixos' own pin (`therock.pkgs`),
whatever nixpkgs the system uses. `config.therock.rock` is `mkTheRock` for
the system's set.

**Prebuilt packages on another ROCm** (`rock.relink pkg`) copies `pkg`'s outputs and rewrites every
reference to the other ROCm: RPATHs and library dirs (`LD_LIBRARY_PATH` in
wrappers) to the runtime, ROCm roots (`ROCM_PATH`-like variables, compilers)
to the SDK. TheRock has the same sonames (`libamdhip64.so.7`, …) with a newer
HIP, so this works for programs that load or link HIP; the build fails if a
reference can't be moved, or if `pkg` reaches the other ROCm through another
package (relink that one first). GPU code objects compiled by the other ROCm
still load; programs that check their toolchain version (hipfire) recompile
them with the SDK on first use instead.

## therock-nixos' own outputs

| | |
|---|---|
| `.#runtime-gfx1151`, `.#sdk-gfx1151` | runtime (4.3 GB closure: what programs link) and SDK (7.4 GB: `hipcc`, headers, CMake), per target, family and `all` |
| `nix develop github:lithinnon/therock-nixos` | the SDK for this machine's GPUs (the same launcher, `.#gfx1100`, `.#shells.<set>`) |
| `nix run .#gpu-check [gfx]` | verify on this GPU: rocminfo, amd-smi, HIP kernel, rocBLAS vs CPU |
| `nix run .#init` | give the Python project in the current directory a flake |
| `nix run .#update -- VERSION [gfx...]` | hash a release/targets into `versions/VERSION.nix` |
| `nix run .#stack-lock` | re-lock and hash the ROCm torch stack (`python/stack`) for every target |

Every target AMD publishes for 10.2.0 is hashed: gfx908/90a/942/950,
gfx1010–1012, gfx1030–1036, gfx1100–1103, gfx1150–1153, gfx1200/1201, gfx1250.
Building for one downloads only its kernel wheels (~0.5 GB, plus torch's) and
AOTriton images; core/libraries/devel are shared. The torch stack is for
Python 3.14 (the pinned nixpkgs').

## Fixes for upstream gaps

- **AOTriton kernel images.** torch loads them next to libaotriton; AMD ships
  them in per-family wheels (`amd-torch-device-gfx115x`, `-gfx110x`,
  `-gfx12-0`) for some targets only. The others (gfx942, gfx950, gfx90a,
  gfx1250) get AOTriton's release images; without either, fused SDPA fails
  with `device kernel image is invalid`.
- **No `/usr`.** `rocm.cfg` gets glibc/gcc paths, and libstdc++ sits in the
  bundled sysdeps dir.
- **Wheels can't hold symlinks.** Unversioned `.so` dev names are added to core,
  and devel's relative links are resolved by the farm.
- **CMake package configs** find their prefix from their real path, so the
  farm copies them (a few MB) instead of linking.

## Status

Verified on gfx1151 (Strix Halo) with TheRock 10.2.0 and torch 2.15.0:
`hipcc` and the HIP template (CMake, rocBLAS) build and run, `rocminfo` and
`amd-smi` work; in uv and pip projects from plain PyPI locks (gfx1151,
gfx1100+gfx1151, gfx942+gfx1151) torch matmul, MIOpen conv, SDPA (AOTriton),
Triton, `torch.compile`, torchvision 0.29.2, lightning and flash-attn work,
as do the launcher, `nix run .#dev` and direnv; hipfire (built upstream on
nixpkgs' ROCm 7.2) runs relinked onto TheRock. `nix flake check` builds HIP
programs for every target in the sandbox and tests relinking, the one-ROCm
check, the torch swap (uv and pip) and the HIP template.

Not included in the wheels compared to AMD's tarball: Composable Kernel C++
headers and instance libraries, hipTensor, rocALUTION, RDC, and the
rocprofiler-systems/compute profilers (those are in the `rocm-profiler` wheel).
