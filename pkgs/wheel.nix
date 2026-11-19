# One TheRock wheel, unpacked as-is into $out (a site-packages-shaped tree).
#
# INVARIANT: never rewrite AMD's shared libraries. They are already patchelf'd
# upstream (PHDR moved to the end of the file); patching them again corrupts them.
# Only standalone executables get a Nix interpreter and host-library RPATH.
{
  lib,
  stdenv,
  fetchurl,
  unzip,
  patchelfUnstable,
  zlib,
  xz,
  libxcrypt-legacy,
  ocl-icd,
}:

{
  pname,
  version,
  hash,
  index,
  # Shell run after unpacking, with the wheel tree in $out.
  postUnpack ? "",
  passthru ? { },
}:

let
  file = "${lib.replaceStrings [ "-" ] [ "_" ] pname}-${version}-py3-none-linux_x86_64.whl";
  hostLibPath = lib.makeLibraryPath [
    stdenv.cc.cc.lib
    zlib
    xz
    libxcrypt-legacy
    ocl-icd
  ];
in
stdenv.mkDerivation {
  inherit pname version passthru;

  src = fetchurl {
    url = "${index}/${pname}/${file}";
    inherit hash;
  };

  nativeBuildInputs = [
    unzip
    patchelfUnstable
  ];

  dontUnpack = true;
  # Kernel packs, bitcode and code objects must stay byte-identical.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    unzip -q "$src" -d "$out"
    ${postUnpack}

    interp=$(cat $NIX_CC/nix-support/dynamic-linker)
    while IFS= read -r -d "" f; do
      isELF "$f" || continue
      patchelf --print-interpreter "$f" >/dev/null 2>&1 || continue # shared library: leave alone
      patchelf --set-interpreter "$interp" --add-rpath "${hostLibPath}" "$f" 2>/dev/null \
        || echo "warning: patchelf refused $f"
    done < <(find "$out" -type f -perm -0100 -print0)
    runHook postInstall
  '';

  meta = {
    description = "AMD TheRock ${pname} ${version} (unpacked wheel)";
    homepage = "https://github.com/ROCm/TheRock";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
