# therock.lib.pytorchProject: a plain Python project (PyPI torch, nothing
# Nix- or GPU-specific in it) on the shared TheRock. Its flake.nix:
#
#   inputs.therock.url = "github:lithinnon/therock-nixos";
#   outputs = { therock, ... }: therock.lib.pytorchProject { src = ./.; };
#
# Two kinds of project, both left as they are:
#
#   uv    pyproject.toml with a [project] table, and its uv.lock (`uv lock`)
#   pip   requirements.txt (no [project] in pyproject.toml); Nix keeps its own
#         lock next to it, requirements.uv.lock (`nix run .#lock`)
#
# At build time torch, torchvision and triton are swapped for AMD's ROCm
# builds from therock-nixos' own hashed lock (./stack), with the device
# kernels of a GPU set; the CUDA packages PyPI's torch pulls in drop out. The
# GPU set is picked when a command runs (see lib/project.nix). Besides
# mkProject's outputs:
#
#   nix run .#lock [-- ARGS]     uv lock (uv), or re-lock requirements.txt (pip)
{
  therockLib,
  mkProject,
  rocmPython,
  inputs,
  therockPkgs,
}:
{
  src,
  pkgs ? therockPkgs,
  python ? pkgs.python3,
  # pip projects: the requirements file (default: requirements.txt)
  requirements ? null,
  # extra pyproject.nix overlays, applied after the ROCm swap
  overlays ? [ ],
  # workspace members (and extras) in the venv; default: every member
  deps ? null,
  sourcePreference ? "wheel",
  # added to every shell (e.g. git hooks)
  packages ? [ ],
  shellHook ? "",
}:
let
  inherit (pkgs) lib;

  pyprojectFile = src + "/pyproject.toml";
  isUv =
    requirements == null
    && builtins.pathExists pyprojectFile
    && (lib.importTOML pyprojectFile) ? project;
  requirementsFile = if requirements != null then requirements else src + "/requirements.txt";
  lockFile = src + (if isUv then "/uv.lock" else "/requirements.uv.lock");
  hasLock = builtins.pathExists lockFile;
  noLock = throw "therock: no ${baseNameOf lockFile} yet: run `nix run .#lock`";

  # pip projects: a virtual uv project made of the requirements, at eval time
  # (no file in the repo); `nix run .#lock` locks the same one.
  reqs =
    if builtins.pathExists requirementsFile then
      import ./requirements.nix { inherit lib; } requirementsFile
    else
      throw "therock: ${toString src} has neither a pyproject.toml with [project] nor ${baseNameOf requirementsFile}";
  pipPyproject = {
    project = {
      name = "requirements";
      version = "0";
      requires-python = "==${lib.versions.majorMinor python.version}.*";
      inherit (reqs) dependencies;
    };
    tool.uv = {
      environments = [ "sys_platform == 'linux' and platform_machine == 'x86_64'" ];
    }
    // lib.optionalAttrs (reqs.constraints != [ ]) { constraint-dependencies = reqs.constraints; };
  };
  pipPyprojectFile = (pkgs.formats.toml { }).generate "pyproject.toml" pipPyproject;

  workspace = inputs.uv2nix.lib.workspace.loadWorkspace (
    {
      workspaceRoot = src;
      uvLock = if hasLock then lib.importTOML lockFile else noLock;
    }
    // lib.optionalAttrs (!isUv) { pyproject = pipPyproject; }
  );
  stack = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./stack; };
  rocm = rocmPython {
    inherit pkgs python;
    lockFile = ./stack/uv.lock;
  };

  name =
    if isUv then
      (lib.importTOML pyprojectFile).project.name
    else
      lib.removeSuffix ".txt" (baseNameOf (toString requirementsFile));
  lockedVersion =
    file: n: (lib.findFirst (p: p.name == n) { } (lib.importTOML file).package).version or null;
  base = v: lib.head (lib.splitString "+" v);
  projectTorch = if hasLock then lockedVersion lockFile "torch" else null;
  stackTorch = lockedVersion ./stack/uv.lock "torch";
  rocmVersion = lockedVersion ./stack/uv.lock "rocm-sdk-core";

  # AMD's builds, and what only they need (rocm-sdk-*, device kernels, ...).
  swapped =
    n:
    builtins.match "torch|torchvision|triton|rocm|rocm-bootstrap|rocm-sdk-.*|amd-torch(vision)?-device-.*" n
    != null;
  stackOverlay = stack.mkPyprojectOverlay { inherit sourcePreference; };
  swap = final: prev: lib.filterAttrs (n: _: swapped n || !(prev ? ${n})) (stackOverlay final prev);

  pythonSet =
    gfx:
    (pkgs.callPackage inputs.pyproject-nix.build.packages { inherit python; }).overrideScope (
      lib.composeManyExtensions (
        [
          inputs.pyproject-build-systems.overlays.wheel
          (workspace.mkPyprojectOverlay { inherit sourcePreference; })
          swap
          (rocm.overlay gfx)
        ]
        ++ overlays
      )
    );

  venv =
    gfx:
    lib.warnIf (projectTorch != null && base projectTorch != base stackTorch)
      "therock: ${baseNameOf lockFile} has torch ${projectTorch}, therock-nixos' ROCm build is ${stackTorch}; packages built against torch may not match (pin torch==${base stackTorch})"
      (
        (pythonSet gfx).mkVirtualEnv "${name}-env-${therockLib.gfxSetName gfx}" (
          (if deps != null then deps else workspace.deps.default) // rocm.venvSpec gfx
        )
      );

  shell =
    gfx:
    let
      env = venv gfx;
      gpu = rocm.shell gfx;
    in
    pkgs.mkShell {
      packages = [
        env
        pkgs.uv
      ]
      ++ gpu.packages
      ++ packages;
      env =
        gpu.env
        // {
          THEROCK_SET = therockLib.gfxSetName gfx;
        }
        // lib.optionalAttrs isUv {
          # `uv run` uses the Nix venv; `uv add`/`uv lock` only edit
          # pyproject.toml/uv.lock (re-enter the shell afterwards).
          UV_NO_SYNC = "1";
          UV_PROJECT_ENVIRONMENT = "${env}";
          UV_PYTHON = "${env}/bin/python";
          UV_PYTHON_DOWNLOADS = "never";
        };
      shellHook = ''
        unset PYTHONPATH
        ${gpu.shellHook}
        ${shellHook}
      '';
    };

  lockApp = {
    type = "app";
    meta.description =
      if isUv then "uv lock (a plain PyPI lock)" else "Lock ${baseNameOf requirementsFile} for Nix";
    program = "${pkgs.writeShellScript "therock-lock" ''
      export PATH=${
        lib.makeBinPath [
          pkgs.uv
          pkgs.git
          pkgs.coreutils
          pkgs.gawk
        ]
      }:$PATH UV_PYTHON=${python.interpreter} UV_PYTHON_DOWNLOADS=never
      lock=${baseNameOf lockFile}
      ${
        if isUv then
          ''uv lock "$@" || exit''
        else
          ''
            # the same virtual project the flake builds, locked in a scratch dir
            tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
            cp ${pipPyprojectFile} "$tmp/pyproject.toml"
            [ -f "$lock" ] && cp "$lock" "$tmp/uv.lock"
            (cd "$tmp" && uv lock "$@") || exit
            cp "$tmp/uv.lock" "$lock"
          ''
      }
      git add --intent-to-add "$lock" 2>/dev/null
      torch=$(awk '/^name = "torch"$/ { getline; gsub(/"/, "", $3); print $3 }' "$lock")
      case "$torch" in ""|${base stackTorch}*) ;; *)
        echo "therock: torch $torch locked; the ROCm build is ${stackTorch} (pin torch==${base stackTorch})" >&2 ;;
      esac
    ''}";
  };
in
mkProject {
  inherit pkgs shell;
  inherit (rocm) ready;
  version = rocmVersion;
  flakeRef = "path:${src}";
  build = venv;
  apps.lock = lockApp;
}
// {
  lib = { inherit venv shell pythonSet; };
}
