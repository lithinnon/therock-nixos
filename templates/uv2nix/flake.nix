{
  inputs = {
    # ROCm store paths are shared by every project (and the system) using the
    # same therock-nixos and nixpkgs, so nixpkgs follows therock's pin.
    therock.url = "github:lithinnon/therock-nixos";
    nixpkgs.follows = "therock/nixpkgs";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      therock,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (nixpkgs) lib;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
      rocm = therock.lib.uv2nix {
        inherit pkgs;
        lockFile = ./uv.lock;
      };

      mkVenv =
        gpuTargets:
        let
          pythonSet =
            (pkgs.callPackage pyproject-nix.build.packages { python = pkgs.python3; }).overrideScope
              (
                lib.composeManyExtensions [
                  pyproject-build-systems.overlays.wheel
                  (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
                  (rocm.overlay gpuTargets)
                ]
              );
        in
        pythonSet.mkVirtualEnv "env" (rocm.venvSpec gpuTargets);

      mkShell =
        gpuTargets:
        let
          gpu = rocm.shell gpuTargets;
          venv = mkVenv gpuTargets;
        in
        pkgs.mkShell {
          packages = [
            venv
            pkgs.uv
          ]
          ++ gpu.packages;
          env = gpu.env // {
            # `uv run` uses the Nix-built venv; `uv add`/`uv lock` only edit
            # pyproject.toml/uv.lock (then `nix run .#lock` and re-enter).
            UV_NO_SYNC = "1";
            UV_PROJECT_ENVIRONMENT = "${venv}";
            UV_PYTHON = "${venv}/bin/python";
            UV_PYTHON_DOWNLOADS = "never";
          };
          shellHook = ''
            unset PYTHONPATH
            ${gpu.shellHook}
          '';
        };
    in
    {
      # default: every GPU target in uv.lock; .#gfxNNNN: just that one
      packages.${system} = rocm.perTarget mkVenv;
      devShells.${system} = rocm.perTarget mkShell;
      apps.${system}.lock = rocm.lockApp;
    };
}
