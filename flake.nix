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
                      gfx = lib.mkDefault [
                        "gfx1151"
                        "gfx1100"
                        "gfx1151"
                      ]; # canonicalized
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
                test "${sys.config.environment.etc."therock/targets".text}" = "gfx1100 gfx1151
                "
                test "${sys.config.environment.etc."therock/version".text}" = "10.2.0
                "
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

            # A GPU set has one canonical form: order and repeats don't change
            # store paths, so the system, shells and venvs share one prefix.
            canonical-gfx =
              let
                mk = gfx: therockLib.mkTheRock { inherit pkgs gfx; };
                fails = gfx: !(builtins.tryEval (mk gfx).runtime.outPath).success;
                ab = mk [
                  "gfx1100"
                  "gfx1151"
                ];
                ba = mk [
                  "gfx1151"
                  "gfx1100"
                  "gfx1151"
                ];
              in
              assert ab.runtime.outPath == ba.runtime.outPath;
              assert ab.sdk.outPath == ba.sdk.outPath;
              assert ab.hook.outPath == ba.hook.outPath;
              assert
                ba.gfx == [
                  "gfx1100"
                  "gfx1151"
                ];
              assert lib.hasSuffix "-10.2.0-gfx1100+gfx1151" ab.runtime.name;
              assert (mk "gfx1151").runtime.outPath == (mk [ "gfx1151" ]).runtime.outPath;
              assert
                therockLib.gfxSetName [
                  "gfx1151"
                  "gfx1100"
                ] == "gfx1100+gfx1151";
              assert fails [ ];
              assert fails [ "rdna3" ];
              assert fails "GFX1151";
              pkgs.runCommand "therock-canonical-gfx" { } "touch $out";

            # Prefixes merge GPU wheels by path: no two of them (nor core or
            # libraries) may ship the same file, or one GPU's would be lost.
            # Only the empty Python package markers (__init__.py) repeat.
            device-collisions =
              let
                all = therockLib.mkTheRock {
                  inherit pkgs;
                  gfx = hashed;
                };
              in
              pkgs.runCommand "therock-device-collisions" { nativeBuildInputs = [ pkgs.python3 ]; } ''
                python3 - ${all.core}/_rocm_sdk_core ${all.libraries}/_rocm_sdk_libraries \
                  ${
                    lib.concatMapStringsSep " " (d: "${d}/_rocm_sdk_libraries") (lib.attrValues all.devices)
                  } <<'EOF'
                import os, sys
                seen, bad = {}, []
                for root in sys.argv[1:]:
                    for d, dirs, files in os.walk(root):
                        for n in files + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
                            rel = os.path.relpath(os.path.join(d, n), root)
                            if rel != "__init__.py" and rel in seen:
                                bad.append(f"{rel}: {seen[rel]} and {root}")
                            seen.setdefault(rel, root)
                print(f"{len(seen)} paths, {len(sys.argv) - 1} wheels")
                sys.exit("colliding paths:\n" + "\n".join(bad[:20]) if bad else 0)
                EOF
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
