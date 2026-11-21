# mkProject: flake outputs for a project whose GPU set is picked when a
# command runs, never in its repo. Shared by pytorchProject, hipProject and
# therock-nixos' own SDK shells, so they all choose (and share) alike:
#
#   nix develop               launcher: picks this machine's set, re-enters it
#   nix run .#dev -- CMD      the same, running CMD
#   nix run .#build           this machine's build (./result)
#   nix run .#set             prints the set the launcher picks
#   .#gfx1151 .#rdna3 .#all   static outputs (nix build / nix develop)
#   .#shells.<set>            any canonical set (up to three targets)
#   .#builds.<set>
#
# The set: THEROCK_GFX ("gfx1100,gfx1151") > /etc/therock/targets (the NixOS
# module's) > every AMD GPU in /sys; sorted, deduplicated, "+"-joined.
{ lib, therockLib }:
{
  pkgs,
  # where the launcher re-enters: the project's flake ("path:${src}")
  flakeRef,
  # buildable targets
  ready,
  version,
  # gfx list -> derivation (packages); null: shells only
  build ? null,
  # gfx list -> dev shell
  shell,
  apps ? { },
}:
let
  system = pkgs.stdenv.hostPlatform.system;
  setName = therockLib.gfxSetName;

  # Every canonical set of up to three ready targets, by name.
  combos =
    k: xs:
    if k == 0 then
      [ [ ] ]
    else if xs == [ ] then
      [ ]
    else
      map (c: [ (lib.head xs) ] ++ c) (combos (k - 1) (lib.tail xs)) ++ combos k (lib.tail xs);
  sets = lib.concatMap (k: combos k (lib.sort lib.lessThan ready)) [
    1
    2
    3
  ];
  bySet = f: lib.listToAttrs (map (s: lib.nameValuePair (setName s) (f s)) sets);

  # Every shell says when it doesn't share the system's ROCm: same GPUs, but
  # another therock-nixos revision (ROCm on disk twice).
  checkedShell =
    gfx:
    let
      runtime = (therockLib.mkTheRock { inherit pkgs gfx version; }).runtime;
    in
    (shell gfx).overrideAttrs (old: {
      shellHook = ''
        if [ "$(cat /etc/therock/targets 2>/dev/null)" = "${toString (therockLib.canonicalGfx gfx)}" ] &&
          [ -r /etc/therock/runtime ] && [ "$(cat /etc/therock/runtime)" != "${runtime}" ]; then
          echo "therock: this project's therock-nixos differs from the system's: ROCm is stored twice (update its therock input, or the system's)" >&2
        fi
      ''
      + (old.shellHook or "");
    });

  select = pkgs.writeShellScript "therock-set" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gawk
      ]
    }
    if [ -n "''${THEROCK_GFX-}" ]; then
      list=$(echo "$THEROCK_GFX" | tr ',+' '  ')
    elif [ -s /etc/therock/targets ]; then
      list=$(cat /etc/therock/targets)
    else
      list=$(for f in /sys/class/kfd/kfd/topology/nodes/*/properties; do
        v=$(awk '$1 == "gfx_target_version" { print $2 }' "$f" 2>/dev/null)
        [ "''${v:-0}" -gt 0 ] && printf 'gfx%d%d%x\n' $((v / 10000)) $((v / 100 % 100)) $((v % 100))
      done)
    fi
    set=$(printf '%s\n' $list | sort -u | paste -sd+)
    if [ -z "$set" ]; then
      echo "therock: no AMD GPU found; set THEROCK_GFX or pick one: ${toString ready}" >&2
      exit 1
    fi
    for t in $(echo "$set" | tr + ' '); do
      case " ${toString ready} " in *" $t "*) ;; *)
        echo "therock: TheRock ${version} has no $t in therock-nixos (ready: ${toString ready})" >&2
        exit 1 ;;
      esac
    done
    echo "$set"
  '';

  launcher = pkgs.mkShell {
    shellHook = ''
      if set=$(${select}); then
        if [[ $- == *i* ]]; then
          echo "therock: $set" >&2
          exec ${pkgs.nix}/bin/nix develop "${flakeRef}#shells.$set"
        fi
        echo "therock: non-interactive: use \`nix run .#dev -- CMD\` or \`nix develop .#shells.$set -c CMD\`" >&2
      fi
      exit 1
    '';
  };

  app = description: text: {
    type = "app";
    meta.description = description;
    program = "${pkgs.writeShellScript "therock-app" text}";
  };
in
{
  packages.${system} = lib.optionalAttrs (build != null) (therockLib.perSet ready build);
  devShells.${system} = therockLib.perSet ready checkedShell // {
    default = launcher;
  };
  legacyPackages.${system} = {
    shells = bySet checkedShell;
  }
  // lib.optionalAttrs (build != null) { builds = bySet build; };
  apps.${system} = {
    set = app "Print the GPU set this machine uses" "exec ${select}";
    dev = app "Run a command in this machine's ROCm shell" ''
      set=$(${select}) || exit 1
      [ $# -gt 0 ] || set -- "''${SHELL:-bash}"
      exec ${pkgs.nix}/bin/nix develop "${flakeRef}#shells.$set" -c "$@"
    '';
  }
  // lib.optionalAttrs (build != null) {
    build = app "Build for this machine's GPUs (./result)" ''
      set=$(${select}) || exit 1
      exec ${pkgs.nix}/bin/nix build "${flakeRef}#builds.$set" "$@"
    '';
  }
  // apps;
}
