# NixOS module: therock-nixos as the system's only ROCm.
#
#   therock.enable = true;
#   therock.gfx = [ "gfx1151" ];
#
# The system gets diagnostics only (rocminfo, amd-smi, rocm_agent_enumerator):
# no ROCM_PATH, no compiler, nothing for unlinked programs to find. Software
# that uses the GPU is linked to therock-nixos in its own derivation or flake:
#
#   uv2nix projects     therock.lib.uv2nix (templates.default)
#   HIP/C++ software    rock.hook in nativeBuildInputs (templates.hip)
#   development         therock.lib.mkShell / devShells.<gfx>
#   prebuilt packages   config.therock.rock.relink pkg (no recompiling)
#
# With `exclusive` (the default) the system build fails if any ROCm other than
# therock-nixos' is in it, naming what pulls it in.
{ therockLib, therockPkgs }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.therock;
  inherit (lib) mkOption types;
  rock = therockLib.mkTheRock {
    pkgs = cfg.pkgs;
    inherit (cfg) gfx version;
  };
  # The runtime prefix's bin/ as absolute links (its own entries are partly relative).
  tools = pkgs.runCommand "therock-tools-${cfg.version}" { } ''
    mkdir -p $out/bin
    for name in ${toString cfg.binaries}; do
      f=${rock.runtime}/bin/$name
      [ -x "$f" ] || { echo "therock.binaries: no $name in the runtime prefix" >&2; exit 1; }
      ln -s "$f" $out/bin/
    done
  '';
  # Fails when the system holds another ROCm; part of the system build.
  exclusiveCheck =
    let
      roots = [
        config.system.path
        config.system.build.etc
      ];
    in
    pkgs.runCommand "therock-exclusive-check"
      {
        exportReferencesGraph =
          lib.concatLists (
            lib.imap0 (i: r: [
              "graph-${toString i}"
              r
            ]) roots
          )
          ++ [
            "allowed-runtime"
            rock.runtime
            "allowed-sdk"
            rock.sdk
          ];
        nativeBuildInputs = [ pkgs.python3 ];
        passAsFile = [ "config" ];
        config = builtins.toJSON {
          graphs = lib.imap0 (i: _: "graph-${toString i}") roots;
          allowed = [
            "allowed-runtime"
            "allowed-sdk"
          ];
          roots = map toString roots;
        };
      }
      ''
        python3 ${../lib/rocm_scan.py} check "$configPath"
        touch $out
      '';
in
{
  options.therock = {
    enable = lib.mkEnableOption "AMD TheRock (ROCm) via therock-nixos as the system's only ROCm";

    gfx = mkOption {
      type = types.nonEmptyListOf (types.strMatching "gfx[0-9a-f]+");
      example = [ "gfx1151" ];
      description = ''
        GPU targets (`rocminfo | grep gfx`). Several targets share one prefix.
        A target must be hashed in versions/<version>.nix (`nix run .#update`).
      '';
    };

    version = mkOption {
      type = types.enum (lib.attrNames therockLib.versions);
      default = therockLib.defaultVersion;
      description = "TheRock release.";
    };

    pkgs = mkOption {
      type = types.raw;
      default = therockPkgs;
      defaultText = lib.literalMD "therock-nixos' pinned nixpkgs";
      description = ''
        nixpkgs used to build ROCm (interpreters, libc, libstdc++ for AMD's
        binaries). The default, therock-nixos' own pin, gives the same store
        paths as projects using the same therock-nixos revision, whatever
        nixpkgs the system uses.
      '';
    };

    binaries = mkOption {
      type = types.listOf types.str;
      default = [
        "rocminfo"
        "amd-smi"
        "rocm_agent_enumerator"
      ];
      description = "Diagnostics from the runtime prefix to put on PATH.";
    };

    exclusive = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Fail the system build if it contains a ROCm other than therock-nixos'
        (nixpkgs' rocmPackages, an upstream flake's), listing what pulls it in.
        Relink such packages with `config.therock.rock.relink`.
      '';
    };

    miopenFindMode = mkOption {
      type = types.nullOr (
        types.enum [
          "NORMAL"
          "FAST"
          "HYBRID"
          "DYNAMIC_HYBRID"
        ]
      );
      default = null;
      example = "FAST";
      description = ''
        Set MIOPEN_FIND_MODE system-wide. MIOpen's benchmarking breaks after
        a suspend (ROCm/MIOpen#3964); uv2nix venvs switch to FAST
        automatically when that happened, this applies it everywhere.
      '';
    };

    rock = mkOption {
      type = types.raw;
      readOnly = true;
      default = rock;
      description = ''
        Everything mkTheRock built for `gfx`: runtime, sdk, hook, relink,
        therock, aotriton, per-wheel paths. Use it to link system software,
        e.g. `config.therock.rock.relink pkgs.foo`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ tools ];
    environment.variables = lib.optionalAttrs (cfg.miopenFindMode != null) {
      MIOPEN_FIND_MODE = cfg.miopenFindMode;
    };
    hardware.graphics.enable = lib.mkDefault true;
    system.checks = lib.optional cfg.exclusive exclusiveCheck;
  };
}
