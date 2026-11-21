{
  description = "HIP/C++ project on therock-nixos' shared TheRock ROCm";

  inputs = {
    therock.url = "github:lithinnon/therock-nixos";
    # Same nixpkgs as therock-nixos: the same ROCm store paths as the system.
    nixpkgs.follows = "therock/nixpkgs";
  };

  outputs =
    { nixpkgs, therock, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # Your GPUs (`rocminfo | grep gfx`); several targets share one ROCm.
      rock = therock.lib.mkTheRock {
        inherit pkgs;
        gfx = [ "gfx1151" ];
      };
    in
    {
      # Built against the SDK; links the runtime prefix (no 3 GB SDK at runtime).
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "hip-app";
        version = "0.1.0";
        src = ./.;
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.ninja
          rock.hook
        ];
      };

      # hipcc, CMake's HIP language, find_package(rocblas) ...; GPU_TARGETS set.
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          rock.hook
          pkgs.cmake
          pkgs.ninja
        ];
      };
    };
}
