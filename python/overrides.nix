# pyproject.nix overrides: AMD TheRock wheels from the shared therock-nixos store paths.
#
#  * rocm-sdk-core / -libraries / -device-<gfx> are not fetched. They become
#    placeholder distributions (./site):
#    AMD's small stub packages + dist-info, with the payload directories
#    (_rocm_sdk_core/lib, ...) symlinked into the runtime prefix for `gfx`.
#    rocm_sdk finds libraries relative to those stubs, and ROCm libraries
#    resolve their siblings and kernels relative to the path they were loaded
#    from, so this behaves like the unpacked wheels while every project shares
#    one copy.
#  * The rocm-sdk-core placeholder carries a startup hook (therock.pth) that
#    provides what the manylinux binaries expect from /usr: libstdc++ & co.,
#    libc headers for MIOpen's JIT, and MIOPEN_FIND_MODE=FAST after a suspend.
#  * torch & co. are ordinary wheels, linked against the shared core and
#    libraries wheels, so one store path serves every GPU set. Their per-GPU
#    kernel packs (amd-torch-device-*) are separate packages the venv merges
#    in; the set-specific bits (where those packs are, AOTriton's images) come
#    from the placeholder's _therock_torch module (see therock_torch.py).
#    AOTriton's images come from AMD's family wheels (amd-torch-device-gfx115x,
#    ...) that torch[device-gfxNNNN] pulls in, else AOTriton's release images.
{
  pkgs,
  lib,
  mkTheRock,
  gfx,
  devicePackagesFor,
}:
final: prev:
let
  sp = final.python.sitePackages;
  version = prev.rocm-sdk-core.version;
  rock = mkTheRock {
    inherit pkgs gfx version;
  };
  inherit (rock) runtime;

  # Python for building aiter's core module: torch (aiter imports it) on this ROCm.
  aiterBuildEnv = final.mkVirtualEnv "aiter-build-env" (
    lib.genAttrs (lib.filter (n: prev ? ${n}) [
      "torch"
      "pybind11"
      "ninja"
      "packaging"
      "psutil"
      "einops"
      "pyyaml"
      "pandas"
      "flydsl"
    ]) (_: [ ])
  );

  linker = pkgs.callPackage ./site { } { inherit runtime; };

  # The placeholders' files, built once per (version, gfx, python).
  site = pkgs.runCommand "therock-site-${version}-${lib.concatStringsSep "+" gfx}" { } ''
    mkdir -p $out/${sp}
    ${linker}/bin/therock-site $out > /dev/null
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
        # what pyproject.nix's output hook does: visible to dependents' builds
        mkdir -p $out/nix-support
        echo 'addToSearchPath NIX_PYPROJECT_PYTHONPATH "'$out/${sp}'"' > $out/nix-support/setup-hook
      '';
    });
  dist = n: "${n}-${version}.dist-info";

  devicePackages = devicePackagesFor gfx;
  # AOTriton finds its images next to the real libaotriton file, so each set
  # gets a copy (32 MB) beside links to its targets' image families: from
  # AMD's family wheel when the target has one in the lock
  # (amd-torch-device-gfx115x, -gfx12-0, ...), else AOTriton's release images
  # (none for some targets, e.g. RDNA1/2: SDPA then uses other kernels).
  isTarget = n: builtins.match "amd-torch-device-gfx[0-9a-f]+" n != null;
  imagesFor =
    t:
    let
      families = lib.filter (n: lib.hasPrefix "amd-torch-device-" n && !isTarget n) (devicePackagesFor [
        t
      ]);
    in
    if families != [ ] then
      map (p: "${final.${p}}/${sp}/torch/lib/aotriton.images") families
    else
      map (i: "${i}/aotriton.images")
        (mkTheRock {
          inherit pkgs version;
          gfx = [ t ];
        }).aotriton;
  torchSet = lib.optionalString (prev ? torch) ''
    cp ${./therock_torch.py} $out/${sp}/_therock_torch.py
    a=$out/${sp}/_therock_aotriton
    mkdir -p $a/aotriton.images
    for f in ${final.torch}/${sp}/torch/lib/libaotriton_v2.so.*; do
      [ -L "$f" ] || cp "$f" $a/
    done
    ${lib.concatMapStrings (d: "ln -s ${d}/* $a/aotriton.images/\n") (
      lib.unique (lib.concatMap imagesFor gfx)
    )}
  '';

  # ROCm's libraries in the per-wheel store paths every GPU set shares, so
  # torch & co. link the same paths whatever the set (their kernels are
  # found through the set's runtime, which rocm_sdk preloads from the venv).
  rocmLibs = [
    "${rock.core}/_rocm_sdk_core/lib"
    "${rock.core}/_rocm_sdk_core/lib/rocm_sysdeps/lib"
    "${rock.libraries}/_rocm_sdk_libraries/lib"
  ];

  # Build variables, minus those the project sets itself (uv's
  # extra-build-variables become derivation attributes, which `env` can't repeat).
  buildEnv = old: vars: (old.env or { }) // lib.filterAttrs (n: _: !(old ? ${n})) vars;

  linkAgainst = dirs: old: {
    dontStrip = true;
    preFixup = (old.preFixup or "") + lib.concatMapStrings (d: "addAutoPatchelfSearchPath ${d}\n") dirs;
  };
in
{
  rocm-sdk-core =
    (placeholder "rocm-sdk-core" "rocm_sdk_core _rocm_sdk_core ${dist "rocm_sdk_core"} _therock_host.py therock.pth")
    .overrideAttrs
      (old: {
        installPhase = old.installPhase + torchSet;
      });
  rocm-sdk-libraries = placeholder "rocm-sdk-libraries" "rocm_sdk_libraries _rocm_sdk_libraries ${dist "rocm_sdk_libraries"}";

  # `rocm_sdk` module; sdist-only. uv doesn't lock build systems, hence setuptools.
  rocm = prev.rocm.overrideAttrs (old: {
    nativeBuildInputs =
      (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { setuptools = [ ]; };
  });

  # One torch for every GPU set (its per-GPU kernels are separate packages);
  # _rocm_init, which runs before torch loads its libraries, picks up the
  # venv's set from _therock_torch.
  torch = prev.torch.overrideAttrs (
    old:
    linkAgainst rocmLibs old
    // {
      buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.xz ]; # libaotriton
      postInstall = (old.postInstall or "") + ''
        cat >> $out/${sp}/torch/_rocm_init.py <<'EOF'


        # therock-nixos: this venv's GPU set (kernel packs, AOTriton images).
        _amd_initialize = initialize


        def initialize():
            _amd_initialize()
            try:
                import _therock_torch  # noqa: F401
            except ImportError:
                pass
        EOF
      '';
    }
  );

  triton = prev.triton.overrideAttrs (
    old:
    linkAgainst rocmLibs old
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
// lib.optionalAttrs (prev ? amd-aiter) {
  # aiter (git): JIT-compiles module_aiter_core (~15 s, needs the full SDK and
  # ninja) on first import, into a copy of itself under ~/.aiter when its own
  # dir is read-only. Built here instead; it has no GPU code, so it is never
  # considered stale for the running GPU.
  amd-aiter = prev.amd-aiter.overrideAttrs (old: {
    nativeBuildInputs =
      (old.nativeBuildInputs or [ ])
      ++ final.resolveBuildSystem {
        setuptools = [ ];
        setuptools-scm = [ ];
        wheel = [ ];
        packaging = [ ];
        psutil = [ ];
        ninja = [ ];
      };
    buildInputs = (old.buildInputs or [ ]) ++ [
      pkgs.patchelf
      pkgs.removeReferencesTo
    ];
    env = buildEnv old {
      SETUPTOOLS_SCM_PRETEND_VERSION = old.version;
      PREBUILD_KERNELS = "0";
      ENABLE_CK = "0";
      ROCM_PATH = "${rock.sdk}";
    };
    postInstall = (old.postInstall or "") + ''
      export HOME=$TMPDIR GPU_ARCHS="${lib.concatStringsSep ";" gfx}" ROCM_PATH=${rock.sdk}
      export PATH=${aiterBuildEnv}/bin:$PATH PYTHONPATH=$out/${sp}
      # `import aiter` asks rocminfo for the GPU; aiter.jit.core honours
      # GPU_ARCHS, so load just that, from $out (not the source tree in cwd).
      (cd $TMPDIR && ${aiterBuildEnv}/bin/python -c '
      import importlib.util, inspect, sys
      jit = sys.argv[1] + "/aiter/jit"
      spec = importlib.util.spec_from_file_location("aiter.jit.core", jit + "/core.py")
      core = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(core)
      args = core.get_args_of_build("module_aiter_core") | {"md_name": "module_aiter_core"}
      params = inspect.signature(core.build_module).parameters
      core.build_module(**{k: v for k, v in args.items() if k in params})
      ' $out/${sp})
      rm -rf $out/${sp}/aiter/jit/build
      # Built against the SDK, run against the runtime (keeps devel's 3.3 GB out
      # of venvs); the build env's path is only in pybind11's __FILE__ strings.
      core=$out/${sp}/aiter/jit/module_aiter_core.so
      patchelf --set-rpath ${runtime}/lib:${lib.getLib pkgs.stdenv.cc.cc}/lib $core
      remove-references-to -t ${aiterBuildEnv} $core
      # Its read-only dir is copied to ~/.aiter/jit for later JIT builds; make
      # that copy writable (copytree keeps the store's modes).
      substituteInPlace $out/${sp}/aiter/jit/core.py --replace-fail \
        'shutil.copytree(this_dir, home_jit_dir)' \
        'shutil.copytree(this_dir, home_jit_dir, copy_function=shutil.copyfile); [os.chmod(r, 0o755) for r, _, _ in os.walk(home_jit_dir)]'
      test -f $out/${sp}/aiter/jit/module_aiter_core.so
    '';
  });
}
// lib.optionalAttrs (prev ? flydsl) {
  # aiter's MLIR DSL; its JIT runtime links HIP.
  flydsl = prev.flydsl.overrideAttrs (linkAgainst rocmLibs);
}
// lib.optionalAttrs (prev ? flash-attn) {
  # flash-attn (git) with its Triton backend, on the aiter above.
  flash-attn = prev.flash-attn.overrideAttrs (old: {
    nativeBuildInputs =
      (old.nativeBuildInputs or [ ])
      ++ final.resolveBuildSystem {
        setuptools = [ ];
        wheel = [ ];
        packaging = [ ];
        psutil = [ ];
        ninja = [ ];
        torch = [ ]; # setup.py imports it (with its dependencies)
        rocm = [ "libraries" ];
        amd-aiter = [ ];
      };
    env = buildEnv old {
      FLASH_ATTENTION_TRITON_AMD_ENABLE = "TRUE";
      FLASH_ATTENTION_USE_SYSTEM_AITER = "TRUE";
      FLASH_ATTENTION_SKIP_CUDA_BUILD = "TRUE";
    };
  });
}
// lib.optionalAttrs (prev ? torchvision) {
  torchvision = prev.torchvision.overrideAttrs (
    old: linkAgainst (rocmLibs ++ [ "${final.torch}/${sp}/torch/lib" ]) old
  );
}
// lib.genAttrs (lib.filter (lib.hasPrefix "rocm-sdk-device-") devicePackages) (
  name: placeholder name (dist (lib.replaceStrings [ "-" ] [ "_" ] name))
)
