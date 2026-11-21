{
  lib,
  writeText,
  writers,
  stdenv,
  glibc,
  zlib,
  xz,
  libxcrypt-legacy,
  ocl-icd,
}:

{ runtime }:

let
  inherit (runtime)
    version
    gfx
    core
    libraries
    ;
  cc = lib.getLib stdenv.cc.cc;
  config = writeText "therock-${version}.json" (
    builtins.toJSON {
      inherit version gfx;
      runtime = "${runtime}";
      stubs = {
        rocm_sdk_core = "${core}";
        rocm_sdk_libraries = "${libraries}";
      };
      hostLibs = [
        "${cc}/lib/libstdc++.so.6"
        "${cc}/lib/libgcc_s.so.1"
        "${cc}/lib/libatomic.so.1"
        "${cc}/lib/libgomp.so.1"
        "${lib.getLib zlib}/lib/libz.so.1"
        "${lib.getLib xz}/lib/liblzma.so.5"
        "${lib.getLib libxcrypt-legacy}/lib/libcrypt.so.1"
        "${lib.getLib ocl-icd}/lib/libOpenCL.so.1"
      ];
      libcHeaders = "${lib.getDev glibc}/include";
    }
  );
in
writers.writePython3Bin "therock-site" { doCheck = false; } (
  lib.replaceStrings [ "@config@" ] [ "${config}" ] (builtins.readFile ./site.py)
)
