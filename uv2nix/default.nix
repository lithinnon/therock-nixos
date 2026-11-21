# therock-nixos for uv2nix projects.
#
#   therock.lib.uv2nix { pkgs; lockFile = ./uv.lock; } ->
#     overlay gfx       pyproject.nix overlay; ROCm from the shared TheRock store paths
#     venvSpec gfx      uv2nix dependency spec (workspace members + target extras)
#     ready             gfx targets buildable from uv.lock + therock-nixos' manifest
#     perTarget f       { default = f ready; gfxNNNN = f [ "gfxNNNN" ]; ... }
#     shell gfx         { packages; env; shellHook; } to merge into mkShell
#     lockApp           flake app: `uv lock` + hashes for the targets in use
#
# Unlike AMD's wheels unpacked per project, every venv (and the system, and
# `therock link` venvs) shares one ROCm per (version, GPU targets): the
# rocm-sdk-* packages become metadata + symlinks into the runtime prefix.
{ therockLib }:
{
  pkgs,
  lockFile,
  python ? pkgs.python3,
}:
let
  inherit (pkgs) lib;
  targets = import ./targets.nix {
    inherit lib lockFile;
    inherit (therockLib) versions;
  };

  lockTool = pkgs.writers.writePython3Bin "therock-lock" { doCheck = false; } (
    builtins.readFile ./lock.py
  );

  detectGpus = pkgs.writeShellScript "detect-gpus" ''
    for f in /sys/class/kfd/kfd/topology/nodes/*/properties; do
      v=$(${pkgs.gawk}/bin/awk '$1 == "gfx_target_version" { print $2 }' "$f" 2>/dev/null)
      [ "''${v:-0}" -gt 0 ] && printf 'gfx%d%d%x\n' $((v / 10000)) $((v / 100 % 100)) $((v % 100))
    done | sort -u
  '';
in
{
  inherit (targets) ready;
  venvSpec = gfx: targets.venvSpec (therockLib.canonicalGfx gfx);

  overlay =
    gfx':
    let
      gfx = therockLib.canonicalGfx gfx';
    in
    import ./overrides.nix {
      inherit pkgs lib gfx;
      inherit (therockLib) mkTheRock;
      inherit (targets) devicePackagesFor;
    };

  perTarget =
    f:
    lib.genAttrs targets.ready (t: f [ t ])
    // {
      default =
        if targets.ready == [ ] then
          throw "therock: no GPU target locked yet: run `nix run .#lock`"
        else
          f targets.ready;
    };

  shell =
    gfx':
    let
      gfx = therockLib.canonicalGfx gfx';
    in
    {
      packages = [
        pkgs.stdenv.cc # triton / torch.compile build a C launcher at runtime
      ];
      env = { };
      # Silent unless this machine has a GPU the shell has no kernels for.
      shellHook = ''
        for gfx in $(${detectGpus}); do
          case " ${toString gfx} " in *" $gfx "*) ;; *)
            echo "therock: no kernels for your $gfx here; run \`nix run .#lock\`, then \`nix develop .#$gfx\`" >&2 ;;
          esac
        done
      '';
    };

  lockApp = {
    type = "app";
    program = "${pkgs.writeShellScript "lock" ''
      export PATH=${
        lib.makeBinPath [
          pkgs.uv
          pkgs.nix
          pkgs.git
        ]
      }:$PATH
      export UV_PYTHON=${python.interpreter} UV_PYTHON_DOWNLOADS=never
      export THEROCK_MANIFESTS=${
        lib.escapeShellArg (
          builtins.toJSON (lib.mapAttrs (_: m: lib.attrNames m.devices) therockLib.versions)
        )
      }
      exec ${lockTool}/bin/therock-lock "$@"
    ''}";
    meta.description = "uv lock + hashes for the GPU targets in use";
  };
}
