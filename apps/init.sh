# therock init: make the uv project in the current directory (or a new one) a
# pytorchProject. Writes only what's missing; commits nothing.
#
#   nix run github:lithinnon/therock-nixos#init
#
# @template@ is substituted by flake.nix.
set -euo pipefail
t=@template@

[ -e flake.nix ] && { echo "therock init: flake.nix exists; see $t/flake.nix for what it should contain" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init -q

if [ ! -e pyproject.toml ]; then
  sed "s/^name = \"my-project\"/name = \"$(basename "$PWD" | tr -c 'A-Za-z0-9._\n-' -)\"/" "$t/pyproject.toml" > pyproject.toml
  echo "therock init: wrote pyproject.toml (torch, torchvision)"
elif ! grep -qE '^requires-python *= *"[^"]*3\.14' pyproject.toml; then
  echo "therock init: note: therock-nixos' ROCm torch needs Python 3.14 (requires-python)" >&2
fi
install -m644 "$t/flake.nix" flake.nix
[ -e .envrc ] || install -m644 "$t/.envrc" .envrc
touch .gitignore
while read -r line; do grep -qxF "$line" .gitignore || echo "$line" >> .gitignore; done < "$t/.gitignore"

uv lock
git add --intent-to-add flake.nix pyproject.toml uv.lock .envrc .gitignore
nix flake lock
git add --intent-to-add flake.lock

cat <<EOM
therock init: done. Nothing here names a GPU; each machine picks its own:
  nix develop           shell for this machine's GPU set (Python, uv, a C compiler)
  direnv allow          the same on cd
  nix run .#dev -- CMD  run CMD there
  nix build .#gfx1151   a venv for a given target (.#rdna3, .#all, .#venvs.<set>)
Commit flake.nix, flake.lock, pyproject.toml, uv.lock, .envrc, .gitignore.
EOM
