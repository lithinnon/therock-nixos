"""therock: use the shared TheRock (ROCm) of this machine from Python venvs.

  therock link [VENV]   point a venv's ROCm packages at the shared SDK
  therock info          show the SDK this command was built for

`therock link` installs placeholder rocm-sdk-core / -libraries / -device-<gfx>
distributions (metadata + symlinks, no payload). uv and pip see them as
installed at the locked version and never download AMD's ROCm wheels; torch
& co. load ROCm from the Nix store. Re-run it after anything uninstalls them.
It also links AOTriton's kernel images into torch, and adds a startup hook
that provides what AMD's manylinux binaries expect from /usr.
"""

import base64
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

CONFIG = json.loads(Path(os.environ.get("THEROCK_CONFIG", "@config@")).read_text())

# Python dists we replace -> (stub packages copied from AMD's wheel, payload dir, subdirs linked to the SDK)
DISTS = {
    "rocm_sdk_core": (["rocm_sdk_core"], "_rocm_sdk_core", ["bin", "etc", "include", "lib", "libexec", "share"]),
    "rocm_sdk_libraries": (["rocm_sdk_libraries"], "_rocm_sdk_libraries", ["bin", "lib", "share", ".kpack"]),
}

HOST_HOOK = '''\
# Installed by `therock link`: what TheRock's manylinux binaries expect from /usr.
def _setup():
    import ctypes, os
    for path in {libs!r}:
        try:
            ctypes.CDLL(path, mode=ctypes.RTLD_GLOBAL)  # satisfies DT_NEEDED by soname
        except OSError:
            pass
    # libc headers for kernels JIT-compiled in-process (hipRTC/comgr, e.g. MIOpen)
    cpath = [p for p in os.environ.get("CPATH", "").split(os.pathsep) if p]
    if {headers!r} not in cpath:
        os.environ["CPATH"] = os.pathsep.join(cpath + [{headers!r}])
    # After a suspend/resume, GPU timestamps read 0 until reboot (ROCm/MIOpen#3964),
    # which breaks MIOpen's timed kernel search; FAST picks kernels untimed.
    try:
        with open("/sys/power/suspend_stats/success") as f:
            if int(f.read()) > 0:
                os.environ.setdefault("MIOPEN_FIND_MODE", "FAST")
    except (OSError, ValueError):
        pass

_setup()
del _setup
'''


def remove(path: Path):
    """Remove a file, link or tree, including read-only copies from the Nix store."""
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        for root, dirs, _ in os.walk(path):
            for d in [root, *(os.path.join(root, x) for x in dirs)]:
                if not os.path.islink(d):
                    os.chmod(d, 0o755)
        shutil.rmtree(path)


def copy_writable(src: Path, dst: Path):
    """Copy a tree out of the Nix store without its read-only modes."""
    shutil.copytree(src, dst, copy_function=shutil.copyfile)
    for root, dirs, files in os.walk(dst):
        os.chmod(root, 0o755)
        for f in files:
            os.chmod(os.path.join(root, f), 0o644)


def site_packages(venv: Path) -> Path:
    found = sorted(venv.glob("lib/python3.*/site-packages"))
    if not found:
        sys.exit(f"therock: no lib/python3.*/site-packages under {venv} (create it with `uv venv`)")
    return found[-1]


def record_line(sp: Path, path: Path) -> str:
    rel = path.relative_to(sp).as_posix()
    if path.is_symlink() or path.is_dir():
        return f"{rel},,"  # uninstalling removes the link, never what it points to
    digest = base64.urlsafe_b64encode(hashlib.sha256(path.read_bytes()).digest()).rstrip(b"=").decode()
    return f"{rel},sha256={digest},{path.stat().st_size}"


def write_dist(sp: Path, dist: str, files: list[Path], requires: list[str] = ()):
    info = sp / f"{dist}-{CONFIG['version']}.dist-info"
    for old in sp.glob(f"{dist}-*.dist-info"):
        remove(old)
    info.mkdir()
    meta = [f"Metadata-Version: 2.1", f"Name: {dist.replace('_', '-')}", f"Version: {CONFIG['version']}"]
    meta += [f"Requires-Dist: {r}" for r in requires]
    (info / "METADATA").write_text("\n".join(meta) + "\n")
    (info / "INSTALLER").write_text("therock-nixos\n")
    (info / "WHEEL").write_text("Wheel-Version: 1.0\nGenerator: therock-nixos\nRoot-Is-Purelib: false\nTag: py3-none-linux_x86_64\n")
    lines = [record_line(sp, f) for f in files + [info / "METADATA", info / "INSTALLER", info / "WHEEL"]]
    (info / "RECORD").write_text("\n".join(lines + [f"{(info / 'RECORD').relative_to(sp).as_posix()},,"]) + "\n")


def link(venv: Path):
    sp = site_packages(venv)
    sdk = Path(CONFIG["runtime"])
    for dist, (pkgs, payload, subdirs) in DISTS.items():
        stub_root = Path(CONFIG["stubs"][dist])
        files: list[Path] = []
        for pkg in pkgs:
            remove(sp / pkg)
            copy_writable(stub_root / pkg, sp / pkg)
            files += [p for p in (sp / pkg).rglob("*") if p.is_file()]
        pdir = sp / payload
        remove(pdir)
        pdir.mkdir()
        shutil.copyfile(stub_root / payload / "__init__.py", pdir / "__init__.py")
        files.append(pdir / "__init__.py")
        for d in subdirs:
            if (sdk / d).exists():
                (pdir / d).symlink_to(sdk / d, target_is_directory=True)
                files.append(pdir / d)
        write_dist(sp, dist, files)
    for gfx in CONFIG["gfx"]:  # kernels are already in the SDK; metadata only
        write_dist(sp, f"rocm_sdk_device_{gfx}", [], [f"rocm-sdk-libraries=={CONFIG['version']}"])

    hook = sp / "_therock_host.py"
    remove(hook)
    hook.write_text(HOST_HOOK.format(libs=CONFIG["hostLibs"], headers=CONFIG["libcHeaders"]))
    (sp / "therock.pth").write_text("import _therock_host\n")

    torch_lib = sp / "torch" / "lib"
    images = torch_lib / "aotriton.images"
    if torch_lib.is_dir() and CONFIG["aotriton"] and not (images.exists() and not images.is_symlink()):
        if images.is_symlink():
            images.unlink()
        images.mkdir()
        for family_dir in CONFIG["aotriton"]:
            for d in Path(family_dir, "aotriton.images").iterdir():
                (images / d.name).symlink_to(d, target_is_directory=True)

    print(f"therock: {venv} -> ROCm {CONFIG['version']} ({', '.join(CONFIG['gfx'])}) at {sdk}")
    if not torch_lib.is_dir() and CONFIG["aotriton"]:
        print("therock: torch not installed yet; run `therock link` again after `uv sync` for AOTriton kernels")


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        sys.exit(__doc__)
    if args[0] == "link":
        venv = Path(args[1] if len(args) > 1 else os.environ.get("VIRTUAL_ENV", ".venv"))
        link(venv.resolve())
    elif args[0] == "info":
        print(json.dumps(CONFIG, indent=2))
    else:
        sys.exit(f"therock: unknown command {args[0]!r}\n\n{__doc__}")


if __name__ == "__main__":
    main()
