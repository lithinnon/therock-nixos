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
        # therock.lib.mkShell { pkgs; gfx; ... }: dev shell with the SDK
        mkShell = args: therockLib.mkShell ({ inherit pkgs; } // args);
        # therock.lib.uv2nix { pkgs; lockFile = ./uv.lock; }: see uv2nix/default.nix
        uv2nix = import ./uv2nix { inherit therockLib; };
      };

      templates = {
        default = self.templates.uv2nix;
        uv2nix = {
          path = ./templates/uv2nix;
          description = "uv2nix project with ROCm torch on the shared TheRock; `nix run .#lock`, then `nix develop`";
        };
        hip = {
          path = ./templates/hip;
          description = "HIP/C++ (CMake) project built against the shared TheRock";
        };
      };

      devShells.${system} = lib.mapAttrs (gfx: _: therockLib.mkShell { inherit pkgs gfx; }) perTarget;

      nixosModules.default = import ./modules/nixos.nix {
        inherit therockLib;
        therockPkgs = pkgs;
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

      checks.${system} =
        lib.mapAttrs' (
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
        ) perTarget
        // (
          let
            r = perTarget.gfx1151;
            mkSystem =
              extra:
              lib.nixosSystem {
                inherit system;
                modules = [
                  self.nixosModules.default
                  {
                    therock = {
                      enable = true;
                      gfx = [ "gfx1151" ];
                      miopenFindMode = "FAST";
                    };
                    boot.loader.grub.enable = false;
                    fileSystems."/" = {
                      device = "none";
                      fsType = "tmpfs";
                    };
                    system.stateVersion = "26.05";
                  }
                  extra
                ];
              };
            exclusiveCheckOf =
              sys: lib.findFirst (c: lib.hasInfix "therock-exclusive-check" c.name) null sys.config.system.checks;

            # Stand-ins for a nixpkgs ROCm and for software built on it.
            fakeRocm = pkgs.runCommand "clr-7.2.4" { } ''
              mkdir -p $out/lib $out/bin
              touch $out/lib/libamdhip64.so.7
              printf '#!/bin/sh\n' > $out/bin/hipcc && chmod +x $out/bin/hipcc
            '';
            fakeApp = pkgs.runCommandCC "fake-app-1.0" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
              mkdir -p $out/bin
              echo 'int main(void) { return 0; }' > m.c
              $CC m.c -o $out/bin/.app-unwrapped -Wl,-rpath,${fakeRocm}/lib
              makeWrapper $out/bin/.app-unwrapped $out/bin/app \
                --prefix LD_LIBRARY_PATH : ${fakeRocm}/lib --set-default APP_ROCM ${fakeRocm}
              ln -s ${fakeRocm}/lib/libamdhip64.so.7 $out/libhip
            '';
            fakeIndirect = pkgs.runCommand "indirect-1.0" { } ''
              mkdir $out; echo ${pkgs.writeText "libfoo-1.0" "${fakeRocm}"} > $out/ref
            '';
            relinked = r.relink fakeApp;
          in
          {
            # The module: diagnostics only; the system build checks for other ROCms.
            nixos-module =
              let
                sys = mkSystem { };
                path = sys.config.system.path;
              in
              pkgs.runCommand "therock-nixos-module" { } ''
                test -x ${path}/bin/rocminfo && test -x ${path}/bin/amd-smi
                test -x ${path}/bin/rocm_agent_enumerator
                for b in hipcc amdclang++ therock; do test ! -e ${path}/bin/$b; done
                ${lib.optionalString (sys.config.environment.variables ? ROCM_PATH) "false"}
                test "${sys.config.environment.variables.MIOPEN_FIND_MODE}" = FAST
                test -e ${exclusiveCheckOf sys} # passes: only TheRock
                touch $out
              '';

            nixos-module-exclusive =
              let
                failure = pkgs.testers.testBuildFailure (
                  exclusiveCheckOf (mkSystem {
                    environment.systemPackages = [ fakeApp ];
                  })
                );
              in
              pkgs.runCommand "therock-nixos-module-exclusive" { } ''
                grep -q 'clr-7.2.4  <- fake-app-1.0 <- system-path$' ${failure}/testBuildFailure.log
                touch $out
              '';

            relink =
              pkgs.runCommand "therock-relink"
                {
                  nativeBuildInputs = [ pkgs.patchelf ];
                  indirect = pkgs.testers.testBuildFailure (r.relink fakeIndirect);
                }
                ''
                  set -x
                  ! grep -rq ${builtins.substring 11 32 "${fakeRocm}"} ${relinked} # gone
                  patchelf --print-rpath ${relinked}/bin/.app-unwrapped | grep -q ${r.runtime}/lib
                  grep -q 'LD_LIBRARY_PATH=.${r.runtime}/lib' ${relinked}/bin/app
                  grep -q "APP_ROCM-'${r.sdk}'" ${relinked}/bin/app # has hipcc -> the SDK
                  grep -q 'exec "${relinked}/bin/.app-unwrapped"' ${relinked}/bin/app # self
                  test "$(readlink ${relinked}/libhip)" = ${r.runtime}/lib/libamdhip64.so.7
                  ${relinked}/bin/app
                  grep -q 'libfoo-1.0 depends on another ROCm' $indirect/testBuildFailure.log
                  touch $out
                '';

            # templates/hip builds against the SDK and links only the runtime.
            hip-template = pkgs.stdenv.mkDerivation {
              name = "therock-hip-template";
              src = ./templates/hip;
              nativeBuildInputs = [
                pkgs.cmake
                pkgs.ninja
                r.hook
              ];
              disallowedReferences = [
                r.sdk
                r.devel
              ];
            };
          }
        );

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
