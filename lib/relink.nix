# rock.relink pkg: `pkg`, already built against another ROCm (nixpkgs'
# rocmPackages, an upstream flake's), moved onto this TheRock without
# recompiling it.
#
# Its outputs are copied with every reference to the other ROCm rewritten:
# RPATHs and LD_LIBRARY_PATH-style lib dirs -> the runtime prefix, ROCm roots
# (ROCM_PATH, compilers) -> the SDK. Same library sonames (libamdhip64.so.7,
# ...), TheRock's newer HIP. The build fails if anything of the other ROCm is
# left, or if `pkg` reaches it through another package (relink that first).
{
  lib,
  pkgs,
  rock,
}:
pkg:
let
  outputs = pkg.outputs or [ "out" ];
  # Same name as the original, so self-references keep their length and can
  # be rewritten inside binaries.
  name = builtins.unsafeDiscardStringContext (lib.substring 33 (-1) (baseNameOf pkg.outPath));
  graphs = map (o: "graph-${o}") outputs;
  config = {
    graphs = graphs;
    allowed = [
      "allowed-runtime"
      "allowed-sdk"
    ];
    outputs = lib.genAttrs outputs (o: "${pkg.${o}}");
    runtime = "${rock.runtime}";
    sdk = "${rock.sdk}";
  };
in
pkgs.runCommand name
  {
    inherit outputs;
    exportReferencesGraph =
      lib.concatMap (o: [
        "graph-${o}"
        pkg.${o}
      ]) outputs
      ++ [
        "allowed-runtime"
        rock.runtime
        "allowed-sdk"
        rock.sdk
      ];
    nativeBuildInputs = [
      pkgs.patchelf
      pkgs.python3
    ];
    passAsFile = [ "config" ];
    config = builtins.toJSON config;
    passthru =
      (pkg.passthru or { })
      // {
        unrelinked = pkg;
      }
      // lib.optionalAttrs (pkg ? version) { inherit (pkg) version; };
    meta = pkg.meta or { };
  }
  ''
    python3 ${./rocm_scan.py} relink "$configPath"
  ''
