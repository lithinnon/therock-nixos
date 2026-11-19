# AOTriton kernel images for torch's fused SDPA (flash / efficient attention).
#
# AMD's torch wheels ship libaotriton_v2.so but not the torch/lib/aotriton.images
# it loads kernels from, so SDPA fails with "device kernel image is invalid".
# Linked into torch/lib by `therock link` and the uv2nix overlay.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

{
  version,
  family,
  hash,
}:

stdenvNoCC.mkDerivation {
  pname = "aotriton-images-${family}";
  inherit version;
  src = fetchurl {
    url = "https://github.com/ROCm/aotriton/releases/download/${version}/aotriton-${version}-images-amd-${family}.tar.gz";
    inherit hash;
  };
  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;
  installPhase = ''
    mkdir -p $out
    mv aotriton/lib/aotriton.images $out/
  '';
  meta = {
    description = "AOTriton ${version} kernel images for ${family}";
    homepage = "https://github.com/ROCm/aotriton";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
