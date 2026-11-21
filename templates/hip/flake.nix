{
  # HIP/C++ (CMake) on the shared TheRock (therock-nixos). Nothing here names a
  # GPU: each machine picks its own when a command runs (`nix develop`, direnv).
  inputs.therock.url = "github:lithinnon/therock-nixos";
  outputs =
    { therock, ... }:
    therock.lib.hipProject {
      src = ./.;
      name = "hip-app";
      # package = { pkgs, rock }: pkgs.stdenv.mkDerivation { ...; nativeBuildInputs = [ rock.hook ]; };
    };
}
