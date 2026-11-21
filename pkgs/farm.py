"""Merge unpacked TheRock wheels into one flat ROCm prefix made of symlinks.

usage: farm.py OUT ROOT... [--devel DEVEL_ROOT]

Each ROOT is a wheel payload dir (_rocm_sdk_core, _rocm_sdk_libraries of the
libraries wheel or of a device wheel). Every file becomes OUT/<relpath> -> its
store path, so the bytes stay in the per-wheel store paths and are shared
(except CMake package configs, which are copied: see below).
Later roots win: device wheels drop their kernels into the libraries tree.

ROCm libraries find siblings and kernel data relative to the path they were
loaded from ($ORIGIN, dladdr) without canonicalising it, so a farm of file
symlinks behaves like the merged tree AMD intended.

The devel wheel is itself an overlay: most of its entries are relative links
into the sibling _rocm_sdk_core / _rocm_sdk_libraries trees. Those resolve to
the same relpath here, so they are dropped; links inside devel are kept as-is.
"""

import os
import sys

SIBLINGS = ("_rocm_sdk_core/", "_rocm_sdk_libraries/")


def entries(root):
    for d, dirs, files in os.walk(root):
        for n in files + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
            p = os.path.join(d, n)
            yield os.path.relpath(p, root), p


def place(out, rel, target):
    dst = os.path.join(out, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    replaced = os.path.lexists(dst)
    if replaced:
        os.remove(dst)
    os.symlink(target, dst)
    return replaced


def main():
    args = sys.argv[1:]
    devel = None
    if "--devel" in args:
        i = args.index("--devel")
        devel = args[i + 1]
        del args[i : i + 2]
    out, roots = args[0], args[1:]
    os.makedirs(out)

    overridden = 0
    for root in roots:
        for rel, path in entries(root):
            overridden += place(out, rel, path)

    kept = redirected = dropped = 0
    if devel:
        for rel, path in entries(devel):
            if not os.path.islink(path):
                overridden += place(out, rel, path)
                continue
            target = os.readlink(path)
            resolved = os.path.normpath(os.path.join("_rocm_sdk_devel", os.path.dirname(rel), target))
            if resolved.startswith("_rocm_sdk_devel/"):
                place(out, rel, target)  # internal link: same layout here
                kept += 1
                continue
            sibling = next((s for s in SIBLINGS if resolved.startswith(s)), None)
            inner = resolved[len(sibling) :] if sibling else None
            if inner is not None and os.path.lexists(os.path.join(out, inner)):
                if inner != rel:
                    place(out, rel, os.path.relpath(inner, os.path.dirname(rel) or "."))
                    redirected += 1
                continue  # already present at the same relpath
            dropped += 1  # e.g. optional rocm-profiler wheel, or a GPU target not selected

    # CMake package configs locate their install prefix from their own real
    # path, which for a link is the wheel's tree, not this prefix: copy them.
    copied = 0
    for d, _, files in os.walk(out):
        for n in files:
            p = os.path.join(d, n)
            if n.endswith(".cmake") and os.path.islink(p):
                data = open(p, "rb").read()
                os.remove(p)
                open(p, "wb").write(data)
                copied += 1

    print(
        f"farm: {sum(1 for _ in entries(out))} entries; {copied} CMake files copied; {overridden} overridden; "
        f"devel links kept {kept}, redirected {redirected}, dropped {dropped}"
    )


if __name__ == "__main__":
    main()
