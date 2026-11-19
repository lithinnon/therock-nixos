{
  description = "AMD TheRock (ROCm) for NixOS: one shared ROCm per (version, GPU target)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux"; # TheRock publishes x86_64 Linux builds only
      pkgs = nixpkgs.legacyPackages.${system};
      therockLib = import ./lib { inherit lib; };

      # Targets with every hash in their manifest, i.e. buildable.
      hashed = lib.attrNames therockLib.versions.${therockLib.defaultVersion}.devices;
      perTarget = lib.genAttrs hashed (gfx: therockLib.mkTheRock { inherit pkgs gfx; });
    in
    {
      lib = {
        inherit (therockLib) mkTheRock versions defaultVersion;
      };

      packages.${system} =
        lib.concatMapAttrs (gfx: r: {
          "runtime-${gfx}" = r.runtime;
          "sdk-${gfx}" = r.sdk;
          "therock-${gfx}" = r.therock;
        }) perTarget
        // {
          default = perTarget.gfx1151.therock;
        };

      checks.${system} = lib.mapAttrs' (
        gfx: r:
        lib.nameValuePair "hipcc-${gfx}" (
          pkgs.runCommand "therock-hipcc-${gfx}" { } ''
            # Compile + link a HIP program for ${gfx} (needs no GPU).
            cat > vadd.hip <<'EOF'
            #include <hip/hip_runtime.h>
            __global__ void vadd(const float* a, const float* b, float* c, int n) {
              int i = blockIdx.x * blockDim.x + threadIdx.x; if (i < n) c[i] = a[i] + b[i];
            }
            int main() { float* p; hipMalloc(&p, 4); vadd<<<1, 1>>>(p, p, p, 1); return hipDeviceSynchronize(); }
            EOF
            unset ROCM_PATH HIP_PATH # the hipcc wrapper must find the prefix itself
            ${r.sdk}/bin/hipcc --offload-arch=${gfx} -O2 vadd.hip -o $out
          ''
        )
      ) perTarget;

      apps.${system} = {
        gpu-check = {
          type = "app";
          meta.description = "Verify the SDK on this machine's GPU: HIP kernel, rocBLAS, rocminfo, amd-smi";
          program = lib.getExe (
            pkgs.writeShellApplication {
              name = "gpu-check";
              runtimeInputs = [
                pkgs.gawk
                pkgs.gnugrep
                pkgs.gnused
                pkgs.coreutils
              ];
              text =
                lib.replaceStrings
                  [ "@targets@" ]
                  [ (lib.concatMapAttrsStringSep " " (gfx: r: "[${gfx}]=${r.sdk}") perTarget) ]
                  (builtins.readFile ./apps/gpu-check.sh);
            }
          );
        };

        update = {
          type = "app";
          meta.description = "Hash a TheRock release into versions/<version>.nix";
          program = "${pkgs.writeShellScript "therock-update" ''
            export PATH=${
              lib.makeBinPath [
                pkgs.nix
                pkgs.git
              ]
            }:$PATH
            exec ${
              pkgs.writers.writePython3Bin "update" { doCheck = false; } (builtins.readFile ./apps/update.py)
            }/bin/update "$@"
          ''}";
        };
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
