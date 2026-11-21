# therock.lib.hipProject: a HIP/C++ project on the shared TheRock, its GPU set
# picked when a command runs (lib/project.nix). Its flake.nix:
#
#   inputs.therock.url = "github:lithinnon/therock-nixos";
#   outputs = { therock, ... }: therock.lib.hipProject { src = ./.; };
#
# The default package is a CMake + Ninja build of `src`; `package` replaces
# it. Either way it builds against the SDK (rock.hook: ROCM_PATH, HIPCXX,
# GPU_TARGETS, CMake toolchain file) and links only the runtime.
{
  therockLib,
  mkProject,
  therockPkgs,
}:
{
  src,
  pkgs ? therockPkgs,
  version ? therockLib.defaultVersion,
  name ? "hip-app",
  # { pkgs, rock } -> derivation; rock.hook in its nativeBuildInputs
  package ? null,
  # added to every shell
  packages ? [ ],
}:
let
  inherit (pkgs) lib;
  rockOf = gfx: therockLib.mkTheRock { inherit pkgs gfx version; };
  defaultPackage =
    { pkgs, rock }:
    pkgs.stdenv.mkDerivation {
      pname = name;
      version = "0";
      inherit src;
      nativeBuildInputs = [
        pkgs.cmake
        pkgs.ninja
        rock.hook
      ];
    };
  build =
    gfx:
    (if package != null then package else defaultPackage) {
      inherit pkgs;
      rock = rockOf gfx;
    };
in
mkProject {
  inherit pkgs version build;
  ready = lib.attrNames therockLib.versions.${version}.devices;
  flakeRef = "path:${src}";
  shell =
    gfx:
    pkgs.mkShell {
      inputsFrom = [ (build gfx) ];
      inherit packages;
    };
}
