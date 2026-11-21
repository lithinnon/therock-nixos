# The ROCm side of pytorchProject (internal): the overlay that puts uv2nix
# packages on the shared TheRock, for a lock in the "targets member" form of
# ./stack (one gfx* extra per GPU target).
#
#   overlay gfx       pyproject.nix overlay; ROCm from the shared TheRock store paths
#   venvSpec gfx      uv2nix dependency spec (the targets member + its gfx extras)
#   ready             gfx targets buildable from the lock + therock-nixos' manifest
#   shell gfx         { packages; env; shellHook; } to merge into mkShell
#   lockApp           `uv lock` + hashes for the targets in use (`nix run .#stack-lock`)
#
# Every venv (and the system) shares one ROCm per (version, GPU set): the
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
            echo "therock: this shell has no kernels for your $gfx (plain \`nix develop\` picks this machine's GPUs)" >&2 ;;
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
