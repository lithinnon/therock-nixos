# therock.lib.pytorchProject: a plain uv project (PyPI torch, gfx-agnostic) on
# the shared TheRock. The project's flake.nix:
#
#   inputs.therock.url = "github:lithinnon/therock-nixos";
#   outputs = { therock, ... }: therock.lib.pytorchProject { src = ./.; };
#
# The uv.lock is an ordinary PyPI lock (`uv lock`). At build time torch,
# torchvision and triton are swapped for AMD's ROCm builds from therock-nixos'
# own hashed lock (./stack), with the device kernels of a GPU set; the CUDA
# packages PyPI's torch pulls in drop out of the venv.
#
# The GPU set is chosen when a command runs, never in the repo:
#
#   nix develop                  launcher: picks this machine's set, re-enters it
#   nix run .#dev -- CMD         the same, running CMD
#   nix develop .#gfx1100        a target, family (.#rdna3) or .#all;
#                                .#shells.<set> any canonical set
#   nix build .#gfx1151          the venv (same names); .#venvs.<set>
#   nix run .#set                prints the set the launcher picks
#   nix run .#lock [-- ARGS]     uv lock (PyPI; nothing to hash)
#
# The set: THEROCK_GFX (e.g. "gfx1100,gfx1151") > /etc/therock/targets (the
# NixOS module's) > every AMD GPU in /sys; sorted, deduplicated, "+"-joined.
{
  therockLib,
  uv2nixLib,
  inputs,
  therockPkgs,
}:
{
  src,
  pkgs ? therockPkgs,
  python ? pkgs.python3,
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
  system = "x86_64-linux";

  workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = src; };
  stack = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./stack; };
  rocm = uv2nixLib {
    inherit pkgs python;
    lockFile = ./stack/uv.lock;
  };

  name = (lib.importTOML (src + "/pyproject.toml")).project.name or "project";
  hasLock = builtins.pathExists (src + "/uv.lock");
  lockedVersion =
    file: n: (lib.findFirst (p: p.name == n) { } (lib.importTOML file).package).version or null;
  base = v: lib.head (lib.splitString "+" v);
  projectTorch = if hasLock then lockedVersion (src + "/uv.lock") "torch" else null;
  stackTorch = lockedVersion ./stack/uv.lock "torch";

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
      "therock: uv.lock has torch ${projectTorch}, therock-nixos' ROCm build is ${stackTorch}; packages built against torch may not match (pin torch==${base stackTorch})"
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
      env = gpu.env // {
        # `uv run` uses the Nix venv; `uv add`/`uv lock` only edit
        # pyproject.toml/uv.lock (re-enter the shell afterwards).
        UV_NO_SYNC = "1";
        UV_PROJECT_ENVIRONMENT = "${env}";
        UV_PYTHON = "${env}/bin/python";
        UV_PYTHON_DOWNLOADS = "never";
        THEROCK_SET = therockLib.gfxSetName gfx;
      };
      shellHook = ''
        unset PYTHONPATH
        ${gpu.shellHook}
        ${shellHook}
      '';
    };

  ready = rocm.ready;
  # Every canonical set of up to three ready targets, by name ("gfx1100+gfx1151").
  combos =
    k: xs:
    if k == 0 then
      [ [ ] ]
    else if xs == [ ] then
      [ ]
    else
      map (c: [ (lib.head xs) ] ++ c) (combos (k - 1) (lib.tail xs)) ++ combos k (lib.tail xs);
  sets = lib.concatMap (k: combos k (lib.sort lib.lessThan ready)) [
    1
    2
    3
  ];
  bySet = f: lib.listToAttrs (map (s: lib.nameValuePair (therockLib.gfxSetName s) (f s)) sets);

  # The set this machine uses (see the header); prints "gfxA+gfxB".
  select = pkgs.writeShellScript "therock-set" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gawk
      ]
    }
    if [ -n "''${THEROCK_GFX-}" ]; then
      list=$(echo "$THEROCK_GFX" | tr ',+' '  ')
    elif [ -s /etc/therock/targets ]; then
      list=$(cat /etc/therock/targets)
    else
      list=$(for f in /sys/class/kfd/kfd/topology/nodes/*/properties; do
        v=$(awk '$1 == "gfx_target_version" { print $2 }' "$f" 2>/dev/null)
        [ "''${v:-0}" -gt 0 ] && printf 'gfx%d%d%x\n' $((v / 10000)) $((v / 100 % 100)) $((v % 100))
      done)
    fi
    set=$(printf '%s\n' $list | sort -u | paste -sd+)
    if [ -z "$set" ]; then
      echo "therock: no AMD GPU found; set THEROCK_GFX or pick one: ${toString ready}" >&2
      exit 1
    fi
    for t in $(echo "$set" | tr + ' '); do
      case " ${toString ready} " in *" $t "*) ;; *)
        echo "therock: $t has no ROCm torch in therock-nixos yet (ready: ${toString ready})" >&2
        exit 1 ;;
      esac
    done
    echo "$set"
  '';

  flakeRef = "path:${src}";
  launcher = pkgs.mkShell {
    shellHook = ''
      if set=$(${select}); then
        if [[ $- == *i* ]]; then
          echo "therock: $set" >&2
          exec nix develop "${flakeRef}#shells.$set"
        fi
        echo "therock: non-interactive: use \`nix run .#dev -- CMD\` or \`nix develop .#shells.$set -c CMD\`" >&2
      fi
      exit 1
    '';
  };

  app = description: text: {
    type = "app";
    meta.description = description;
    program = "${pkgs.writeShellScript "therock-app" text}";
  };
in
{
  # one per target, family (.#rdna3, ...) and .#all
  packages.${system} = therockLib.perSet ready venv;
  devShells.${system} = therockLib.perSet ready shell // {
    default = launcher;
  };
  # Any canonical set, for the launcher and `nix build .#venvs.<set>`.
  legacyPackages.${system} = {
    shells = bySet shell;
    venvs = bySet venv;
  };
  apps.${system} = {
    set = app "Print the GPU set this machine uses" "exec ${select}";
    dev = app "Run a command in this machine's ROCm shell" ''
      set=$(${select}) || exit 1
      [ $# -gt 0 ] || set -- "''${SHELL:-bash}"
      exec ${pkgs.nix}/bin/nix develop "${flakeRef}#shells.$set" -c "$@"
    '';
    build = app "Build this machine's venv (./result)" ''
      set=$(${select}) || exit 1
      exec ${pkgs.nix}/bin/nix build "${flakeRef}#venvs.$set" "$@"
    '';
    lock = app "uv lock (plain PyPI lock; torch is swapped at build time)" ''
      export PATH=${
        lib.makeBinPath [
          pkgs.uv
          pkgs.git
        ]
      }:$PATH UV_PYTHON=${python.interpreter} UV_PYTHON_DOWNLOADS=never
      uv lock "$@" || exit
      git add --intent-to-add uv.lock 2>/dev/null
      torch=$(awk '/^name = "torch"$/ { getline; gsub(/"/, "", $3); print $3 }' uv.lock)
      case "$torch" in ""|${base stackTorch}*) ;; *)
        echo "therock: torch $torch locked; the ROCm build is ${stackTorch} (pin torch==${base stackTorch})" >&2 ;;
      esac
    '';
  };
  lib = { inherit venv shell pythonSet; };
}
