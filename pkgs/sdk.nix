# A flat ROCm prefix (ROCM_PATH) for one version and set of GPU targets.
#
# Only symlinks (~1 MB): the payload lives in the per-wheel store paths, so a
# second GPU-target set or the Python placeholders reuse the same bytes.
{
  lib,
  runCommand,
  runtimeShell,
  python3,
}:

{
  version,
  gfx,
  core,
  libraries,
  devices,
  # null: runtime only (what torch & co. need); else adds hipcc, headers, CMake.
  devel ? null,
}:

let
  targets = lib.concatStringsSep "+" gfx; # canonical (mkTheRock): gfx1100+gfx1151
  roots = [
    "${core}/_rocm_sdk_core"
    "${libraries}/_rocm_sdk_libraries"
  ]
  ++ map (d: "${d}/_rocm_sdk_libraries") devices;
in
runCommand "rocm-${if devel == null then "runtime" else "sdk"}-${version}-${targets}"
  {
    nativeBuildInputs = [ python3 ];
    passthru = {
      inherit
        version
        gfx
        core
        libraries
        devices
        devel
        ;
    };
    meta.description = "AMD TheRock ${version} for ${lib.concatStringsSep ", " gfx}";
  }
  (
    ''
      python3 ${./farm.py} "$out" ${lib.escapeShellArgs roots} \
        ${lib.optionalString (devel != null) "--devel ${devel}/_rocm_sdk_devel"}
    ''
    + lib.optionalString (devel != null) ''
      # clang's ROCm path comes from core's rocm.cfg (it resolves its physical
      # location), which has no library headers. hipcc honours ROCM_PATH/HIP_PATH,
      # so default them to this prefix; an explicit value still wins.
      for b in hipcc hipconfig; do
        rm "$out/bin/$b"
        cat > "$out/bin/$b" <<EOF
      #!${runtimeShell}
      export ROCM_PATH="\''${ROCM_PATH:-$out}" HIP_PATH="\''${HIP_PATH:-$out}"
      exec ${core}/_rocm_sdk_core/bin/$b "\$@"
      EOF
        chmod +x "$out/bin/$b"
      done
    ''
  )
