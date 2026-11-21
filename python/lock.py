"""`uv lock`, then add the hashes nix needs for the GPU targets in use.

AMD's index publishes no hashes and uv only records hashes an index provides.
Targets hashed: those already hashed in uv.lock, the GPUs in this machine, and
any gfx* named on the command line. Other arguments go to `uv lock`.

AMD's ROCm wheels (rocm-sdk-*) are never hashed or downloaded: the overlay
replaces them with the shared TheRock store paths of therock-nixos.

Usage (in python/stack): nix run .#stack-lock [-- --upgrade-package torch]
"""

import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Provided by therock-nixos, never fetched.
SHARED = re.compile(r"rocm-sdk-(core|libraries|devel|device-gfx[0-9a-f]+)")
# {version: [hashed gfx targets]} of therock-nixos' manifests
MANIFESTS = json.loads(os.environ.get("THEROCK_MANIFESTS", "{}"))

# A file entry (`sdist = { url = … }` or a line in `wheels = [ … ]`) without hash.
ENTRY = re.compile(r'(^\s+|sdist = )\{ url = "([^"]+)"(?![^}\n]*\bhash = )([^}\n]*)\}', re.M)


class Lock:
    def __init__(self, text: str):
        data = tomllib.loads(text)
        self.packages = {p["name"]: p for p in data["package"]}
        self.members = [p for p in data["package"] if {"virtual", "editable"} & p["source"].keys()]
        self.targets_pkg = next(
            (m for m in self.members if any(e.startswith("gfx") for e in m.get("optional-dependencies", {}))),
            None,
        )
        self.supported = sorted(e for e in (self.targets_pkg or {}).get("optional-dependencies", {}) if e.startswith("gfx"))

    def closure(self, targets: list[str]) -> set[str]:
        todo = [(m["name"], tuple(targets) if m is self.targets_pkg else ()) for m in self.members]
        seen, names = set(), set()
        while todo:
            name, extras = todo.pop()
            if (name, extras) in seen:
                continue
            seen.add((name, extras))
            names.add(name)
            pkg = self.packages[name]
            deps = list(pkg.get("dependencies", []))
            for e in extras:
                deps += pkg.get("optional-dependencies", {}).get(e, [])
            todo += [(d["name"], tuple(sorted(d.get("extra", [])))) for d in deps]
        return names

    def unhashed(self, targets: list[str]) -> set[str]:
        urls = set()
        for name in self.closure(targets):
            if SHARED.fullmatch(name):
                continue
            pkg = self.packages[name]
            files = ([pkg["sdist"]] if "sdist" in pkg else []) + pkg.get("wheels", [])
            urls |= {f["url"] for f in files if "hash" not in f}
        return urls

    def ready(self) -> list[str]:
        return [t for t in self.supported if not self.unhashed([t])]


def detect_gpus() -> list[str]:
    found = set()
    for props in Path("/sys/class/kfd/kfd/topology/nodes").glob("*/properties"):
        m = re.search(r"^gfx_target_version (\d+)$", props.read_text(), re.M)
        if m and int(m.group(1)):
            v = int(m.group(1))
            found.add(f"gfx{v // 10000}{(v // 100) % 100}{v % 100:x}")
    return sorted(found)


def run(*cmd: str) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def prefetch(url: str) -> tuple[str, str]:
    # Same store name uv2nix uses (unquoted basename), so the build reuses it.
    name = urllib.parse.unquote(url.rsplit("/", 1)[1])
    b32 = run("nix-prefetch-url", "--name", name, url)
    return url, run("nix", "hash", "convert", "--hash-algo", "sha256", "--to", "base16", b32)


def main() -> None:
    args = sys.argv[1:]
    if args[:1] in (["-h"], ["--help"]):
        sys.exit(__doc__)
    named = [a for a in args if re.fullmatch(r"gfx[0-9a-f]+", a)]
    uv_args = [a for a in args if a not in named]

    # the project: like uv, the nearest directory with a pyproject.toml
    root = next((d for d in [Path.cwd(), *Path.cwd().parents] if (d / "pyproject.toml").exists()), None)
    if root is None:
        sys.exit("no pyproject.toml here or in a parent directory")
    lock_file = root / "uv.lock"
    before = Lock(lock_file.read_text()).ready() if lock_file.exists() else []

    subprocess.run(["uv", "lock", *uv_args], cwd=root, check=True)

    text = lock_file.read_text()
    lock = Lock(text)
    targets = sorted(set(before) | set(named) | {g for g in detect_gpus() if g in lock.supported})
    unknown = sorted(set(named) - set(lock.supported))
    if unknown:
        sys.exit(f"not a supported target: {' '.join(unknown)} (see the gfx* extras of your targets member)")
    if not targets:
        sys.exit("no AMD GPU detected; name a target, e.g. `nix run .#lock -- gfx1100`")

    urls = lock.unhashed(targets)
    if urls:
        print(f"Hashing {len(urls)} files for {' '.join(targets)}", file=sys.stderr)
        with ThreadPoolExecutor(max_workers=4) as pool:
            hashes = dict(pool.map(prefetch, sorted(urls)))
        lock_file.write_text(
            ENTRY.sub(
                lambda m: (
                    f'{m.group(1)}{{ url = "{m.group(2)}", hash = "sha256:{hashes[m.group(2)]}"{m.group(3)}}}'
                    if m.group(2) in hashes
                    else m.group(0)
                ),
                text,
            )
        )
    subprocess.run(["git", "add", "--intent-to-add", "uv.lock"], cwd=root, check=False)

    core = lock.packages.get("rocm-sdk-core")
    if core and MANIFESTS:
        have = MANIFESTS.get(core["version"])
        missing = [t for t in targets if have is None or t not in have]
        if missing:
            print(
                f"note: therock-nixos has no hashes for ROCm {core['version']} {' '.join(missing)}; "
                f"run `nix run github:lithinnon/therock-nixos#update -- {core['version']} {' '.join(missing)}` "
                "in a checkout and point the therock input at it",
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
