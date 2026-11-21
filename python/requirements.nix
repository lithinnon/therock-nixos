# A pip requirements file -> { dependencies; constraints; } (PEP 508 strings),
# for pytorchProject's pip projects. Follows pip's format: comments, line
# continuations, -r/-c includes (relative to the including file). Index and
# other pip options are ignored: torch & co. come from therock-nixos anyway.
# Editable installs and local paths aren't lockable here and fail clearly.
{ lib }:
let
  # "-r x", "-rx", "--requirement=x", "--requirement x" -> [ option argument ]
  splitOption =
    line:
    let
      m = builtins.match "(-r|-c|--requirement|--constraint)[ =]*(.+)" line;
    in
    if m == null then null else m;

  stripComment =
    line:
    let
      m = builtins.match "(|.*[^[:space:]])[[:space:]]+#.*|#.*" line;
    in
    lib.trim (
      if lib.hasPrefix "#" (lib.trim line) then
        ""
      else if m != null && lib.head m != null then
        lib.head m
      else
        line
    );

  parse =
    kind: file:
    let
      dir = dirOf file;
      text = lib.replaceStrings [ "\\\n" ] [ "" ] (builtins.readFile file);
      lines = lib.filter (l: l != "") (map stripComment (lib.splitString "\n" text));
      one =
        line:
        let
          opt = splitOption line;
        in
        if opt != null then
          parse (
            if
              lib.elem (lib.head opt) [
                "-c"
                "--constraint"
              ]
            then
              "constraints"
            else
              kind
          ) (dir + "/${lib.elemAt opt 1}")
        else if lib.hasPrefix "-e" line || lib.hasPrefix "--editable" line then
          throw "therock: ${baseNameOf file}: editable installs (${line}) aren't supported; use a pyproject.toml project"
        else if lib.hasPrefix "-" line then
          { } # --index-url, --extra-index-url, -f, --pre, ...
        else if builtins.match "(\\.|/|file:).*" line != null then
          throw "therock: ${baseNameOf file}: local paths (${line}) aren't supported; use a pyproject.toml project"
        else
          # drop per-requirement options (--hash=..., --config-settings ...)
          { ${kind} = [ (lib.trim (lib.head (lib.splitString " --" line))) ]; };
    in
    lib.foldl' (a: b: a // lib.mapAttrs (k: v: (a.${k} or [ ]) ++ v) b) { } (map one lines);
in
file:
let
  r = parse "dependencies" file;
in
{
  dependencies = r.dependencies or [ ];
  constraints = r.constraints or [ ];
}
