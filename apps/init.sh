# therock init: give the Python project in the current directory (uv or pip),
# or a new one, a flake on therock-nixos. Only adds Nix's own files (flake.nix,
# flake.lock, .envrc, the pip lock, .gitignore lines); the project's own files
# stay as they are, for whoever uses it without Nix. Commits nothing.
#
#   nix run github:lithinnon/therock-nixos#init
#
# @template@ and @therock@ are substituted by flake.nix; THEROCK_URL overrides
# the therock input (a fork, a checkout).
set -euo pipefail
t=@template@
url=${THEROCK_URL:-@therock@}

[ -e flake.nix ] && { echo "therock init: flake.nix exists; see $t/flake.nix for what it should contain" >&2; exit 1; }
fresh=
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { git init -q; fresh=1; }

has_project() { [ -e pyproject.toml ] && grep -qE '^\[project\]' pyproject.toml; }
if has_project; then
  kind="uv project (pyproject.toml)"; files=(uv.lock)
elif [ -e requirements.txt ]; then
  kind="pip project (requirements.txt)"; files=(requirements.uv.lock)
elif [ -e pyproject.toml ]; then
  echo "therock init: pyproject.toml has no [project] and there's no requirements.txt" >&2; exit 1
else
  sed "s/^name = \"my-project\"/name = \"$(basename "$PWD" | tr -c 'A-Za-z0-9._\n-' -)\"/" "$t/pyproject.toml" > pyproject.toml
  kind="new uv project (pyproject.toml: torch, torchvision)"; files=(pyproject.toml uv.lock)
fi
echo "therock init: $kind"

sed "s|github:lithinnon/therock-nixos|$url|" "$t/flake.nix" > flake.nix
if [ -e .envrc ]; then
  echo "therock init: .envrc exists; see $t/.envrc for the therock part" >&2
else
  install -m644 "$t/.envrc" .envrc
fi
touch .gitignore
while read -r line; do grep -qxF "$line" .gitignore || echo "$line" >> .gitignore; done < "$t/.gitignore"

# flakes only see files git tracks
if [ -n "$fresh" ]; then
  git add --intent-to-add .
else
  own=(flake.nix .envrc .gitignore)
  for f in pyproject.toml requirements*.txt constraints*.txt; do [ -e "$f" ] && own+=("$f"); done
  git add --intent-to-add "${own[@]}"
fi
nix flake lock
git add --intent-to-add flake.lock
nix run .#lock
git add --intent-to-add "${files[@]}"

cat <<EOM
therock init: done. Nothing here names a GPU; each machine picks its own:
  nix develop           shell for this machine's GPU set (Python, uv, a C compiler)
  direnv allow          the same on cd
  nix run .#dev -- CMD  run CMD there
  nix build .#gfx1151   a venv for a given target (.#rdna3, .#all, .#builds.<set>)
Commit flake.nix, flake.lock, .envrc, .gitignore and ${files[*]}.
EOM
