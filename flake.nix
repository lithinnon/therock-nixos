{
  description = "AMD TheRock (ROCm) for NixOS: one shared ROCm per (version, GPU target)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # for lib.pytorchProject (projects need no inputs but therock)
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
    { self, nixpkgs, ... }@inputs:
    let
      inherit (nixpkgs) lib;
      system = "x86_64-linux"; # TheRock publishes x86_64 Linux builds only
      pkgs = nixpkgs.legacyPackages.${system};
      therockLib = import ./lib { inherit lib; };

      # Targets with every hash in their manifest, i.e. buildable.
      hashed = lib.attrNames therockLib.versions.${therockLib.defaultVersion}.devices;
      rocks = lib.genAttrs hashed (gfx: therockLib.mkTheRock { inherit pkgs gfx; });

      mkProject = import ./lib/project.nix { inherit lib therockLib; };
      # therock-nixos' own SDK shells, chosen like a project's
      sdkShells = mkProject {
        inherit pkgs;
        ready = hashed;
        version = therockLib.defaultVersion;
        flakeRef = "path:${self}";
        shell = gfx: therockLib.mkShell { inherit pkgs gfx; };
      };
    in
    {
      lib = {
        inherit (therockLib)
          mkTheRock
          versions
          defaultVersion
          canonicalGfx
          gfxSetName
          families
          ;
        # mkShell { gfx; ... }: dev shell with the SDK for a GPU set
        mkShell = args: therockLib.mkShell ({ inherit pkgs; } // args);
        # mkProject { pkgs; flakeRef; ready; version; shell; build?; apps?; }:
        # the run-time GPU selection of pytorchProject/hipProject (lib/project.nix)
        inherit mkProject;
        # pytorchProject { src = ./.; }: a uv or pip project (python/project.nix)
        pytorchProject = import ./python/project.nix {
          inherit therockLib mkProject inputs;
          rocmPython = import ./python { inherit therockLib; };
          therockPkgs = pkgs;
        };
        # hipProject { src = ./.; }: a HIP/C++ project (lib/hip.nix)
        hipProject = import ./lib/hip.nix {
          inherit therockLib mkProject;
          therockPkgs = pkgs;
        };
      };

      templates = {
        default = self.templates.pytorch;
        pytorch = {
          path = ./templates/pytorch;
          description = "Python project with ROCm torch on the shared TheRock (in an existing one: `nix run .#init`)";
        };
        hip = {
          path = ./templates/hip;
          description = "HIP/C++ (CMake) project on the shared TheRock";
        };
      };

      # nix develop: the SDK for this machine's GPUs (.#gfx1151, .#rdna3, .#all,
      # .#shells.<set> as in projects)
      inherit (sdkShells) devShells legacyPackages;

      nixosModules.default = import ./modules/nixos.nix {
        inherit therockLib;
        therockPkgs = pkgs;
      };

      # runtime-<set>, sdk-<set> per target, family and `all`
      packages.${system} = lib.concatMapAttrs (n: r: {
        "runtime-${n}" = r.runtime;
        "sdk-${n}" = r.sdk;
      }) (therockLib.perSet hashed (gfx: therockLib.mkTheRock { inherit pkgs gfx; }));

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
        ) rocks
        // (
          let
            r = rocks.gfx1151;
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
                test "${sys.config.environment.etc."therock/runtime".text}" = "${sys.config.therock.rock.runtime}
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

            # pytorchProject from a plain PyPI lock: ROCm torch swapped in, no
            # CUDA packages, one torch store path for every GPU set.
            pytorch-project =
              let
                p = self.lib.pytorchProject { src = ./tests/pytorch; };
                one = p.packages.${system}.gfx1151;
                two = p.legacyPackages.${system}.builds."gfx1100+gfx1151";
              in
              pkgs.runCommand "therock-pytorch-project"
                {
                  exportReferencesGraph = [
                    "one"
                    one
                    "two"
                    two
                  ];
                }
                ''
                  paths() { grep '^/nix/store/' "$1" | sort -u; }
                  if paths one | grep -E -- '-(nvidia-|cuda-)'; then
                    echo "CUDA packages in the venv" >&2; exit 1
                  fi
                  t1=$(paths one | grep -E -- '-torch-[0-9]'); t2=$(paths two | grep -E -- '-torch-[0-9]')
                  if [ -z "$t1" ] || [ "$t1" != "$t2" ]; then
                    echo "torch differs between GPU sets: $t1 / $t2" >&2; exit 1
                  fi
                  HOME=$TMPDIR ${one}/bin/python -c "import torch, torchvision; assert torch.version.hip; print(torch.__version__, torchvision.__version__)"
                  touch $out
                '';

            # Every command and therock.lib function the plugin skill names exists.
            skill-names =
              let
                text = builtins.readFile ./plugin/skills/therock-nixos/SKILL.md;
                found = re: lib.unique (lib.concatLists (lib.filter builtins.isList (builtins.split re text)));
                projectApps = lib.concatMap (p: lib.attrNames p.apps.${system}) [
                  (self.lib.pytorchProject { src = ./tests/pytorch; })
                  (self.lib.hipProject { src = ./templates/hip; })
                  self
                ];
                missing =
                  lib.filter (n: !(self.lib ? ${n})) (found "therock\\.lib\\.([A-Za-z]+)")
                  ++ lib.filter (n: !(lib.elem n projectApps)) (found "nix run \\.#([a-z-]+)")
                  ++ lib.filter (n: !(self.apps.${system} ? ${n} || self.templates ? ${n})) (
                    found "github:lithinnon/therock-nixos#([a-z-]+)"
                  );
              in
              assert lib.assertMsg (
                missing == [ ]
              ) "plugin/skills/therock-nixos/SKILL.md names what no longer exists: ${toString missing}";
              pkgs.runCommand "therock-skill-names" { } "touch $out";

            # A pip project: requirements.txt + Nix's requirements.uv.lock.
            pip-project =
              let
                venv = (self.lib.pytorchProject { src = ./tests/pip; }).packages.${system}.gfx1151;
                parsed = import ./python/requirements.nix { inherit lib; } ./tests/pip/requirements.txt;
              in
              assert
                parsed == {
                  dependencies = [
                    "torch"
                    "torchvision"
                    "numpy>=2"
                    "packaging; python_version >= '3.10'"
                  ];
                  constraints = [ "numpy<3" ];
                };
              pkgs.runCommand "therock-pip-project" { } ''
                HOME=$TMPDIR ${venv}/bin/python -c "import torch, numpy, packaging; assert torch.version.hip; print(torch.__version__)"
                touch $out
              '';

            # templates/hip (hipProject) builds against the SDK, links only the runtime.
            hip-template =
              (self.lib.hipProject { src = ./templates/hip; }).packages.${system}.gfx1151.overrideAttrs
                {
                  disallowedReferences = [
                    r.sdk
                    r.devel
                  ];
                };
          }
        );

      apps.${system} = sdkShells.apps.${system} // {
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
                  [ (lib.concatMapAttrsStringSep " " (gfx: r: "[${gfx}]=${r.sdk}") rocks) ]
                  (builtins.readFile ./apps/gpu-check.sh);
            }
          );
        };

        init = {
          type = "app";
          meta.description = "Make the Python project here (uv or pip; or a new one) use ROCm torch via therock-nixos";
          program = lib.getExe (
            pkgs.writeShellApplication {
              name = "therock-init";
              runtimeInputs = [
                pkgs.uv
                pkgs.git
                pkgs.nix
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.gnused
              ];
              runtimeEnv = {
                UV_PYTHON = pkgs.python3.interpreter;
                UV_PYTHON_DOWNLOADS = "never";
              };
              text =
                lib.replaceStrings
                  [ "@template@" "@therock@" ]
                  [ "${./templates/pytorch}" "github:lithinnon/therock-nixos" ]
                  (builtins.readFile ./apps/init.sh);
            }
          );
        };

        # Re-lock and hash the ROCm torch stack pytorchProject swaps in, for
        # every GPU target (run in a checkout; downloads ~3 GB).
        stack-lock = {
          type = "app";
          meta.description = "Lock + hash python/stack (the ROCm torch stack) for every GPU target";
          program = "${pkgs.writeShellScript "therock-stack-lock" ''
            cd "$(${pkgs.git}/bin/git rev-parse --show-toplevel)/python/stack" || exit 1
            exec ${
              (import ./python { inherit therockLib; } {
                inherit pkgs;
                lockFile = ./python/stack/uv.lock;
              }).lockApp.program
            } \
              "$@" $(${pkgs.gnugrep}/bin/grep -oE '^gfx[0-9a-f]+' pyproject.toml)
          ''}";
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
