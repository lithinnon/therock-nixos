---
name: therock-nixos
description: therock-nixos, the one ROCm on NixOS (AMD GPUs through flakes). Use when a project needs torch, ROCm or HIP on an AMD GPU; when its flake uses therock.lib; or when a GPU error (hipError*, invalid kernel image, wrong torch build) shows up in such a project.
---

# therock-nixos

On a therock-nixos machine, ROCm reaches a program only through a flake
**linked** to therock-nixos. The system carries diagnostics alone (`rocminfo`,
`amd-smi`). Every project, venv and the system share one ROCm in the Nix store.

## Plain projects

A project's own files stay **plain**: what a CUDA project would commit,
working as-is for someone without Nix.

- Python lists `torch`/`torchvision` from PyPI, unpinned to any backend; the
  flake swaps in AMD's ROCm builds at build time and drops the `nvidia-*`
  packages.
- The GPU set is chosen per machine when a command runs; the repo names no GPU.
- Nix adds only its own files: `flake.nix`, `flake.lock`, `.envrc`, and for
  pip projects `requirements.uv.lock`.

Hard guardrail, since each of these bypasses the one ROCm: keep AMD's wheel
index, gfx extras (`torch[device-gfx1151]`), `rocm-sdk-*` packages and
nixpkgs' `rocmPackages` out of projects, and run GPU code through the flake
rather than a plain `pip`/`uv` venv.

## Set up

- Python, uv or pip, new or existing: `nix run github:lithinnon/therock-nixos#init`
  in the project root, then commit the files it lists.
- HIP/C++ (CMake): `nix flake init -t github:lithinnon/therock-nixos#hip`, or a
  flake whose outputs are `therock.lib.hipProject { src = ./.; }`.
- Done when `nix run .#dev -- python -c "import torch; assert torch.cuda.is_available()"`
  passes (HIP: `nix run .#build` and run `./result/bin/*`).

## Run

| | |
|---|---|
| `nix run .#dev -- CMD` | CMD in the shell for this machine's GPUs. The agent's way in: `nix develop -c` exits by design (the default shell is an interactive launcher) |
| `nix run .#build` | this machine's venv or binary at `./result` |
| `nix build .#gfx1151` | a given target; `.#rdna3`-style families, `.#all`, `.#builds.gfx1100+gfx1151` |
| `nix run .#set` | the GPU set this machine uses (`THEROCK_GFX=gfx1100,gfx1151` overrides) |

Flakes see only files git tracks: `git add --intent-to-add` new files before
running anything.

## Change dependencies

- uv project: `nix run .#dev -- uv add PKG` (edits `pyproject.toml` and
  `uv.lock`); the next `nix run .#dev` builds the new venv.
- pip project: edit `requirements.txt`, then `nix run .#lock` writes
  `requirements.uv.lock`.
- torch is therock-nixos' build (2.15 for TheRock 10.2). A lock with another
  torch warns; pin `torch==2.15.*` in the project.
- flash-attn and aiter: the git pins and `[[tool.uv.dependency-metadata]]`
  from the README; the overlay builds them.

## System software (NixOS)

The module (`therock.enable`, `therock.gfx`) fails the system build when
another ROCm gets in, naming the package that pulls it in. Move that package
onto TheRock with `config.therock.rock.relink pkg` (no rebuild).

## Messages

| Message | Meaning, fix |
|---|---|
| `has no gfxNNNN in therock-nixos` | that GPU isn't hashed: therock-nixos needs `nix run .#update` and `nix run .#stack-lock` |
| `ROCm is stored twice` | the project's therock input differs from the system's: `nix flake update therock` |
| `uv.lock has torch X` | pin torch to therock's version |
| `no requirements.uv.lock yet` | `nix run .#lock` |
| `non-interactive: use nix run .#dev` | as it says |
| `does not exist in the Git tree` | `git add --intent-to-add` the file |
| `invalid kernel file`, `device kernel image is invalid` in a therock venv | a therock-nixos bug: report with `nix run .#set`, the venv path and the failing op |

## Details

The README of the locked revision: `nix flake archive --json` gives
`inputs.therock.path`; read `README.md` there.
