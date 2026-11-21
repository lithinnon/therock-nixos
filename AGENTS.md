# therock-nixos: working on this repo

Using therock-nixos from a project is the plugin skill
`plugin/skills/therock-nixos/SKILL.md`; this file is for changing the repo.

## Invariants

Each is why the design looks the way it does; a change that breaks one is a
regression even when it works on one machine.

- **One store path per wheel.** AMD's wheels unpack as-is, once; everything
  per GPU set is a symlink farm (`pkgs/farm.py`) or a placeholder
  (`python/site`), a few MB. torch, torchvision and triton are one store path
  for every set (`checks.pytorch-project` compares them).
- **AMD's shared libraries stay untouched.** They are patchelf'd upstream and
  break if patched again; only executables and what we build get patched.
  torch & co. link the shared core/libraries wheels (`linkAgainst` in
  `python/overrides.nix`).
- **Load paths, not real paths.** ROCm libraries find siblings and kernels
  relative to the path they were loaded from, which is why farms work. The
  kernel-pack loader and AOTriton resolve real paths instead, so their
  per-set part lives in the placeholder (`python/therock_torch.py`).
- **Canonical sets.** Every consumer takes a GPU set through `canonicalGfx`
  (sorted, deduplicated, `+`-joined), so the same GPUs give the same paths.
- **Plain projects.** Projects' own files name no GPU and nothing Nix-specific;
  the GPU set is chosen at run time (`lib/project.nix`). Generated project
  files are Nix's own (`flake.nix`, `.envrc`, `requirements.uv.lock`).
- **One ROCm.** The NixOS module's exclusive check keeps every other ROCm out
  of the system closure; `rock.relink` moves packages onto TheRock.

## Release flow

1. `nix run .#update -- VERSION <every published target>` writes
   `versions/VERSION.nix` (generated: rerun it, never hand-edit).
2. Point `python/stack/pyproject.toml` at the release's torch, then
   `nix run .#stack-lock` (downloads ~3 GB).
3. `nix flake check`: builds HIP for every target and tests the module,
   relinking, the torch swap (uv, pip) and the HIP template.
4. On a GPU: `nix run .#gpu-check`, and in a project `nix run .#dev` running
   torch matmul, conv, SDPA, Triton, `torch.compile` and torchvision.

The release is done when all four pass.

## The skill

`plugin/skills/therock-nixos/SKILL.md` names commands and `therock.lib`
functions; `checks.skill-names` fails when one stops existing. Change the
skill in the same commit as any rename it mentions.

## Commits

Commits are signed with the owner's hardware key, so each one needs their
touch: commit and push only when asked.
