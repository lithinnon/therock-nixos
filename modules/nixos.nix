# NixOS module: one system-wide TheRock ROCm.
#
#   therock.enable = true;
#   therock.gfx = [ "gfx1151" ];
#
# gives ROCM_PATH/HIP_PATH, hipcc/rocminfo/amd-smi on PATH, the `therock` CLI
# for uv/pip venvs, and (optionally) nix-ld so AMD's unmodified wheels run in
# plain uv projects the way CUDA wheels do on other distros.
therockLib:
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
    inherit pkgs;
    inherit (cfg) gfx version;
  };
  hostLibs = with pkgs; [
    stdenv.cc.cc.lib
    zlib
    xz
    libxcrypt-legacy
    ocl-icd
  ];
  # The prefix's bin/ as absolute links (its own entries are partly relative).
  tools = pkgs.runCommand "therock-tools-${cfg.version}" { } ''
    mkdir -p $out/bin
    for f in ${cfg.package}/bin/*; do
      if [ -x "$f" ] && [ ! -d "$f" ]; then ln -s "$f" $out/bin/; fi
    done
  '';
in
{
  options.therock = {
    enable = lib.mkEnableOption "AMD TheRock (ROCm) as one shared system SDK";

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

    devel = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Use the full SDK (hipcc, headers, CMake packages; +3.3 GB) as ROCM_PATH.
        If false, only the runtime (what torch and other prebuilt wheels need).
      '';
    };

    seamless = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run unmodified Python wheels like on other distros: enables nix-ld with
        the libraries AMD's manylinux wheels expect, and a C compiler for
        Triton. Projects then `uv sync` AMD's own wheels without `therock link`
        (each venv gets its own ROCm copy; `therock link` shares the system one).
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
        a suspend (ROCm/MIOpen#3964); `therock link` venvs switch to FAST
        automatically when that happened, this applies it everywhere.
      '';
    };

    package = mkOption {
      type = types.package;
      readOnly = true;
      default = if cfg.devel then rock.sdk else rock.runtime;
      defaultText = lib.literalMD "the `sdk` or `runtime` prefix for `gfx`";
      description = "The ROCm prefix (ROCM_PATH).";
    };

    rock = mkOption {
      type = types.raw;
      readOnly = true;
      default = rock;
      description = "Everything mkTheRock built: runtime, sdk, therock, aotriton, per-wheel paths.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [
          tools
          rock.therock
        ];
        environment.variables = {
          ROCM_PATH = "${cfg.package}";
          HIP_PATH = "${cfg.package}";
        }
        // lib.optionalAttrs (cfg.miopenFindMode != null) {
          MIOPEN_FIND_MODE = cfg.miopenFindMode;
        };
        hardware.graphics.enable = lib.mkDefault true;
      }
      (lib.mkIf cfg.seamless {
        programs.nix-ld.enable = true;
        programs.nix-ld.libraries = hostLibs;
        environment.systemPackages = [ pkgs.stdenv.cc ];
      })
    ]
  );
}
