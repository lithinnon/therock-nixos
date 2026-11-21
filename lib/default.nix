# mkTheRock { pkgs, gfx, version? } -> one TheRock release for a set of GPU targets:
#
#   core libraries devel   one store path per arch-neutral wheel (shared by all targets)
#   devices.<gfx>          per-GPU kernel wheels
#   runtime                flat ROCm prefix without the compiler (what torch needs)
#   sdk                    runtime + devel: ROCM_PATH for hipcc, headers, CMake
#   aotriton               AOTriton kernel images for these targets
#   therock                CLI: `therock link` points Python venvs at `runtime`
#   hook                   setup hook: build HIP software against sdk, linking runtime
#   relink pkg             `pkg` (built on another ROCm) moved onto this one
{ lib }:

let
  # versions/<version>.nix, written by `nix run .#update`
  versions = lib.mapAttrs' (
    file: _: lib.nameValuePair (lib.removeSuffix ".nix" file) (import (../versions + "/${file}"))
  ) (lib.filterAttrs (f: t: t == "regular" && lib.hasSuffix ".nix" f) (builtins.readDir ../versions));
  defaultVersion = "10.2.0";

  # gfx target -> AOTriton image family among those hashed: the exact name
  # (gfx942, gfx1250), else gfxNNN + x (gfx1151 -> gfx115x). Same rule as apps/update.py.
  aotritonFamily =
    images: gfx:
    let
      x = "${lib.substring 0 (lib.stringLength gfx - 1) gfx}x";
    in
    if images ? ${gfx} then
      gfx
    else if images ? ${x} then
      x
    else
      null;
in
{
  inherit versions defaultVersion aotritonFamily;

  mkTheRock =
    {
      pkgs,
      gfx,
      version ? defaultVersion,
    }:
    let
      m =
        versions.${version}
          or (throw "therock-nixos: no manifest for TheRock ${version} (have: ${toString (builtins.attrNames versions)})");
      targets = lib.toList gfx;
      wheel = pkgs.callPackage ../pkgs/wheel.nix { };
      mkWheel =
        pname: hash: extra:
        wheel (
          {
            inherit pname hash version;
            inherit (m) index;
          }
          // extra
        );

      core = mkWheel "rocm-sdk-core" m.wheels.rocm-sdk-core {
        postUnpack =
          let
            gcc = pkgs.stdenv.cc.cc;
            glibc = pkgs.stdenv.cc.libc;
          in
          ''
            # rocm.cfg sets --rocm-path=<CFGDIR>/../../.. (this wheel's root), where
            # clang looks for device bitcode; the wheel keeps it under lib/llvm.
            ln -s lib/llvm/amdgcn $out/_rocm_sdk_core/amdgcn

            # Wheels can't hold symlinks, so the unversioned dev names (libamdhip64.so,
            # which clang's --hip-link uses) only exist in devel. Add them here.
            for f in $out/_rocm_sdk_core/lib/lib*.so.*; do
              base=''${f%%.so.*}.so
              [ -e "$base" ] || ln -s "$(basename "$f")" "$base"
            done

            # The libraries look for libstdc++/libgcc_s (manylinux: from the distro)
            # in their bundled sysdeps dir first; this works whatever path they load from.
            ln -s ${lib.getLib gcc}/lib/libstdc++.so.6 ${lib.getLib gcc}/lib/libgcc_s.so.1 \
              $out/_rocm_sdk_core/lib/rocm_sysdeps/lib/

            # amd-smi: stdlib-only python CLI + the `amdsmi` bindings in share/amd_smi
            # and its modules in libexec/amdsmi_cli, both found from the script's
            # real location (it is reached through layers of symlinks).
            sed -i '1c #!${pkgs.python3.interpreter}\nimport os as _o, sys as _s; _d = _o.path.dirname(_o.path.realpath(__file__)); _s.path[:0] = [_o.path.join(_d, "..", "share", "amd_smi"), _o.path.join(_d, "..", "libexec", "amdsmi_cli")]' \
              $out/_rocm_sdk_core/bin/amd-smi

            # No /usr on NixOS: tell amdclang/hipcc where libc, CRT and libstdc++ are.
            cat >> $out/_rocm_sdk_core/lib/llvm/bin/rocm.cfg <<EOF

            --gcc-toolchain=${gcc}
            -idirafter ${lib.getDev glibc}/include
            -B${glibc}/lib
            -L${glibc}/lib
            -L${lib.getLib gcc}/lib
            -Wl,-rpath,${glibc}/lib:${lib.getLib gcc}/lib
            -Wl,--dynamic-linker=$(cat $NIX_CC/nix-support/dynamic-linker)
            EOF
          '';
      };
      libraries = mkWheel "rocm-sdk-libraries" m.wheels.rocm-sdk-libraries { };
      devel = mkWheel "rocm-sdk-devel" m.wheels.rocm-sdk-devel {
        # Shipped as a tarball inside the wheel (wheels can't hold symlinks).
        postUnpack = ''
          tar xf $out/rocm_sdk_devel/_devel.tar -C $out
          rm $out/rocm_sdk_devel/_devel.tar
        '';
      };
      devices = lib.genAttrs targets (
        t:
        mkWheel "rocm-sdk-device-${t}" (m.devices.${t}
          or (throw "therock-nixos: TheRock ${version} has no hash for ${t} yet (run the update app)")
        ) { }
      );

      mkPrefix =
        withDevel:
        pkgs.callPackage ../pkgs/sdk.nix { } {
          inherit version core libraries;
          gfx = targets;
          devices = map (t: devices.${t}) targets;
          devel = if withDevel then devel else null;
        };

      aotriton = map (
        family:
        pkgs.callPackage ../pkgs/aotriton-images.nix { } {
          inherit family;
          inherit (m.aotriton) version;
          hash = m.aotriton.images.${family};
        }
      ) (lib.unique (lib.filter (f: f != null) (map (aotritonFamily m.aotriton.images) targets)));

      runtime = mkPrefix false;
      sdk = mkPrefix true;

      rock = {
        inherit
          core
          libraries
          devel
          devices
          runtime
          sdk
          aotriton
          ;
        therock = pkgs.callPackage ../pkgs/therock-cli { } { inherit runtime aotriton; };

        # Build HIP software against the SDK; it links the runtime.
        hook = pkgs.makeSetupHook {
          name = "therock-hook";
          propagatedBuildInputs = [ pkgs.patchelf ];
          substitutions = {
            inherit sdk runtime;
            targets = lib.concatStringsSep ";" targets;
            toolchain = pkgs.writeText "therock-toolchain.cmake" ''
              set(GPU_TARGETS "${lib.concatStringsSep ";" targets}" CACHE STRING "AMD GPU targets (therock-nixos)")
              set(CMAKE_HIP_ARCHITECTURES "${lib.concatStringsSep ";" targets}" CACHE STRING "")
            '';
          };
        } ./hook.sh;

        # Move a package built against another ROCm onto this one.
        relink = import ./relink.nix { inherit lib pkgs rock; };
      };
    in
    rock;

  # mkShell { gfx; pkgs?; version?; ...mkShell args }: a dev shell with the
  # SDK (hipcc, headers, CMake packages) and the target variables set.
  mkShell =
    {
      pkgs,
      gfx,
      version ? defaultVersion,
      packages ? [ ],
      ...
    }@args:
    let
      rock = (import ./. { inherit lib; }).mkTheRock { inherit pkgs gfx version; };
    in
    pkgs.mkShell (
      removeAttrs args [
        "pkgs"
        "gfx"
        "version"
      ]
      // {
        packages = [ rock.hook ] ++ packages;
        passthru = (args.passthru or { }) // {
          inherit rock;
        };
      }
    );
}
