# pyproject.nix overrides: AMD TheRock wheels from the shared therock-nixos store paths.
#
#  * rocm-sdk-core / -libraries / -device-<gfx> are not fetched. They become
#    the same placeholder distributions `therock link` puts in plain venvs:
#    AMD's small stub packages + dist-info, with the payload directories
#    (_rocm_sdk_core/lib, ...) symlinked into the runtime prefix for `gfx`.
#    rocm_sdk finds libraries relative to those stubs, and ROCm libraries
#    resolve their siblings and kernels relative to the path they were loaded
#    from, so this behaves like the unpacked wheels while every project shares
#    one copy.
#  * The rocm-sdk-core placeholder carries a startup hook (therock.pth) that
#    provides what the manylinux binaries expect from /usr: libstdc++ & co.,
#    libc headers for MIOpen's JIT, and MIOPEN_FIND_MODE=FAST after a suspend.
#  * torch & co. are ordinary wheels: autoPatchelf'd against the runtime. Their
#    per-GPU kernel packs (amd-torch-device-*) are merged into their directory,
#    where torch looks for them. AOTriton's kernel images come from AMD's
#    family wheels (amd-torch-device-gfx115x, ...) that torch[device-gfxNNNN]
#    pulls in; only targets without one get AOTriton's release images.
{
  pkgs,
  lib,
  mkTheRock,
  gfx,
  devicePackages,
}:
final: prev:
let
  sp = final.python.sitePackages;
  version = prev.rocm-sdk-core.version;
  rock = mkTheRock {
    inherit pkgs gfx version;
  };
  inherit (rock) runtime;

  # torch isn't in this site, so no AOTriton images (and no download of them).
  linker = pkgs.callPackage ../pkgs/therock-cli { } { inherit runtime; };

  # What `therock link` installs, built once per (version, gfx, python).
  site = pkgs.runCommand "therock-site-${version}-${lib.concatStringsSep "-" gfx}" { } ''
    mkdir -p $out/${sp}
    ${linker}/bin/therock link $out > /dev/null
  '';

  # A locked package replaced by some of `site`'s entries; keeps uv2nix's
  # name/version/dependencies, never evaluates its (unhashed) src.
  placeholder =
    name: entries:
    prev.${name}.overrideAttrs (old: {
      src = null;
      phases = [ "installPhase" ];
      nativeBuildInputs = [ ];
      buildInputs = [ ];
      installPhase = ''
        mkdir -p $out/${sp}
        cd ${site}/${sp}
        cp -a ${entries} $out/${sp}/
      '';
    });
  dist = n: "${n}-${version}.dist-info";

  # AMD ships AOTriton images in per-family wheels (amd-torch-device-gfx115x,
  # -gfx12-0, ...): any torch device package that isn't a target itself.
  hasFamilyWheel = lib.any (p: !(lib.elem p (map (t: "amd-torch-device-${t}") gfx))) (
    matching "amd-torch-device-"
  );
  fallbackImages = lib.optionals (!hasFamilyWheel) rock.aotriton;

  # host package -> per-GPU packages whose payload it carries
  matching = prefix: lib.filter (lib.hasPrefix prefix) devicePackages;
  carriedBy = {
    torch = matching "amd-torch-device-";
    torchvision = matching "amd-torchvision-device-";
  };
  carry = host: old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.unzip ];
    postInstall =
      (old.postInstall or "")
      + lib.concatMapStrings (
        p: "unzip -qo ${final.${p}.src} -x '*.dist-info/*' -d $out/${sp}\n"
      ) carriedBy.${host};
  };
  metadataOnly = old: {
    postInstall = (old.postInstall or "") + ''
      find "$out/${sp}" -mindepth 1 -maxdepth 1 ! -name '*.dist-info' -exec rm -rf {} +
    '';
  };

  linkAgainst = dirs: old: {
    dontStrip = true;
    preFixup = (old.preFixup or "") + lib.concatMapStrings (d: "addAutoPatchelfSearchPath ${d}\n") dirs;
  };
in
{
  rocm-sdk-core = placeholder "rocm-sdk-core" "rocm_sdk_core _rocm_sdk_core ${dist "rocm_sdk_core"} _therock_host.py therock.pth";
  rocm-sdk-libraries = placeholder "rocm-sdk-libraries" "rocm_sdk_libraries _rocm_sdk_libraries ${dist "rocm_sdk_libraries"}";

  # `rocm_sdk` module; sdist-only. uv doesn't lock build systems, hence setuptools.
  rocm = prev.rocm.overrideAttrs (old: {
    nativeBuildInputs =
      (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { setuptools = [ ]; };
  });

  torch = prev.torch.overrideAttrs (
    old:
    let
      carried = carry "torch" old;
    in
    linkAgainst [ "${runtime}/lib" ] old
    // carried
    // {
      buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.xz ]; # aotriton
      postInstall = carried.postInstall + ''
        images=$out/${sp}/torch/lib/aotriton.images
        mkdir -p $images
        ${lib.concatMapStrings (a: ''
          for d in ${a}/aotriton.images/*; do [ -e "$images/''${d##*/}" ] || ln -s "$d" $images/; done
        '') fallbackImages}
      '';
    }
  );

  triton = prev.triton.overrideAttrs (
    old:
    linkAgainst [ "${runtime}/lib" "${runtime}/lib/rocm_sysdeps/lib" ] old
    // {
      buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.zlib ]; # libproton: comgr, sysdeps
      # Its launcher stub includes HIP (-> glibc features.h) before Python.h, so
      # gcc warns "_POSIX_C_SOURCE redefined" on first use. Python.h goes first.
      postInstall = (old.postInstall or "") + ''
        f=$out/${sp}/triton/backends/amd/driver.c
        if [ -f "$f" ]; then
          sed -i -e '/^#define PY_SSIZE_T_CLEAN$/d' -e '/^#include <Python.h>$/d' \
            -e '1i #define PY_SSIZE_T_CLEAN\n#include <Python.h>' "$f"
        fi
      '';
    }
  );
}
// lib.optionalAttrs (prev ? torchvision) {
  torchvision = prev.torchvision.overrideAttrs (
    old:
    linkAgainst [ "${runtime}/lib" "${final.torch}/${sp}/torch/lib" ] old // carry "torchvision" old
  );
}
// lib.genAttrs (lib.filter (lib.hasPrefix "rocm-sdk-device-") devicePackages) (
  name: placeholder name (dist (lib.replaceStrings [ "-" ] [ "_" ] name))
)
// lib.genAttrs (lib.concatLists (lib.attrValues carriedBy)) (
  name: prev.${name}.overrideAttrs metadataOnly
)
