# GPU targets as recorded in uv.lock:
#   ready              targets whose closure is hashed in uv.lock and whose ROCm
#                      is in therock-nixos' manifest (buildable)
#   devicePackagesFor  per-GPU kernel packages a target set pulls in
#   venvSpec           uv2nix dependency spec for a target set
{
  lib,
  lockFile,
  versions,
}:
let
  # No uv.lock yet (fresh project) = no targets; `nix run .#lock` creates it.
  lock = if builtins.pathExists lockFile then lib.importTOML lockFile else { package = [ ]; };
  byName = lib.listToAttrs (map (p: lib.nameValuePair p.name p) lock.package);

  members = lib.filter (p: p.source ? virtual || p.source ? editable) lock.package;
  gfxExtras =
    p: lib.filter (lib.hasPrefix "gfx") (builtins.attrNames (p.optional-dependencies or { }));
  targetsPkg = lib.findFirst (p: gfxExtras p != [ ]) null members;

  # workspace member -> extras, with the GPU targets on the targets package
  venvSpec =
    targets:
    lib.listToAttrs (
      map (
        m: lib.nameValuePair m.name (if m.name == targetsPkg.name or null then targets else [ ])
      ) members
    );

  node = name: extras: {
    key = "${name}[${lib.concatStringsSep "," (lib.sort lib.lessThan extras)}]";
    inherit name extras;
  };
  closure =
    targets:
    lib.unique (
      map (n: n.name) (
        builtins.genericClosure {
          startSet = lib.mapAttrsToList node (venvSpec targets);
          operator =
            n:
            let
              p = byName.${n.name};
            in
            map (d: node d.name (d.extra or [ ])) (
              (p.dependencies or [ ]) ++ lib.concatMap (e: p.optional-dependencies.${e} or [ ]) n.extras
            );
        }
      )
    );

  # rocm-sdk-* come from therock-nixos' manifest, not from uv.lock.
  isShared = name: builtins.match "rocm-sdk-(core|libraries|devel|device-gfx[0-9a-f]+)" name != null;
  rocmVersion = byName.rocm-sdk-core.version or null;
  inManifest = t: rocmVersion != null && (versions.${rocmVersion}.devices or { }) ? ${t};

  isHashed =
    name:
    isShared name
    || lib.all (f: f ? hash) (
      lib.optional (byName.${name} ? sdist) byName.${name}.sdist ++ byName.${name}.wheels or [ ]
    );
  isDevice = name: builtins.match "(rocm-sdk|amd-torch|amd-torchvision)-device-.*" name != null;
in
{
  inherit venvSpec;
  ready = lib.optionals (targetsPkg != null) (
    lib.filter (t: inManifest t && lib.all isHashed (closure [ t ])) (gfxExtras targetsPkg)
  );
  devicePackagesFor = targets: lib.filter isDevice (closure targets);
}
