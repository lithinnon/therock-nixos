"""therock-site DIR: the rocm-sdk-* placeholder distributions for a venv's site-packages.

Build-time only (python/overrides.nix): writes into DIR's site-packages the
rocm-sdk-core / -libraries / -device-<gfx> distributions as AMD's small stub
packages + dist-info, their payload directories symlinked into the runtime
prefix, and a startup hook (therock.pth) providing what AMD's manylinux
binaries expect from /usr.
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
    # A ROCm root for tools that look for one (aiter, torch.utils.cpp_extension);
    # the system's ROCM_PATH (the full SDK, from the NixOS module) wins.
    os.environ.setdefault("ROCM_PATH", {rocm!r})
    # flash-attn: the Triton backend (via aiter); its CK backend isn't built here.
    os.environ.setdefault("FLASH_ATTENTION_TRITON_AMD_ENABLE", "TRUE")
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
    hook.write_text(HOST_HOOK.format(libs=CONFIG["hostLibs"], headers=CONFIG["libcHeaders"], rocm=CONFIG["runtime"]))
    (sp / "therock.pth").write_text("import _therock_host\n")

    print(f"therock-site: {venv} -> ROCm {CONFIG['version']} ({', '.join(CONFIG['gfx'])}) at {sdk}")


def main():
    if len(sys.argv) != 2 or sys.argv[1].startswith("-"):
        sys.exit(__doc__)
    link(Path(sys.argv[1]).resolve())


if __name__ == "__main__":
    main()
