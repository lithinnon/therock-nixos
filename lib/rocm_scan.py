# Find (and rewrite) references to ROCm builds other than therock-nixos'.
#
#   rocm_scan.py relink CONFIG.json   copy a package onto TheRock (see relink.nix)
#   rocm_scan.py check  CONFIG.json   fail if a closure holds another ROCm
#
# "Another ROCm" is a store path, outside therock-nixos' closure, that is a
# nixpkgs ROCm package by name (clr, rocblas, llvm-*-rocm, ...) or a ROCm
# prefix by content (lib/libamdhip64.so*, lib/libhsa-runtime64.so*, bin/hipcc).
import glob
import json
import os
import re
import subprocess
import sys

STORE = "/nix/store/"
NAMES = re.compile(
    r"^(clr|hipClang|hip-common|hipcc|hipify|hipblas|hipblas-common|hipblaslt"
    r"|hipcub|hipfft|hiprand|hipsolver|hipsparse|hipsparselt|hiptensor"
    r"|rocm-[a-z0-9-]+|rocprofiler[a-z0-9-]*|roctracer|rocminfo|rocm_smi"
    r"|rocblas|rocsolver|rocsparse|rocfft|rocrand|rocprim|rocthrust|rocwmma"
    r"|rocalution|rccl|miopen|miopengemm|migraphx|mivisionx|composable_kernel"
    r"|amdsmi|aotriton|rpp|half)(-[0-9].*)?$"
    r"|-rocm(-lib|-dev)?$"  # llvm-22.0.0-rocm, compiler-rt-libc-22.0.0-rocm, ...
)
MARKERS = ("lib/libamdhip64.so*", "lib/libhsa-runtime64.so*", "bin/hipcc")
PATH_RE = re.compile(rb"/nix/store/([0-9a-z]{32})-([A-Za-z0-9+._?=-]+)((?:/[A-Za-z0-9+._@=-]+)*)")


def name_of(p):
    return os.path.basename(p)[33:]


def read_graph(f):
    """exportReferencesGraph file -> {path: [references]}"""
    lines = open(f).read().split("\n")
    g, i = {}, 0
    while i + 2 < len(lines) and lines[i]:
        path, n = lines[i], int(lines[i + 2])
        g[path] = lines[i + 3 : i + 3 + n]
        i += 3 + n
    return g


def is_prefix(p):
    return any(glob.glob(os.path.join(p, m)) for m in MARKERS)


def other_rocm(graph, allowed):
    return {
        p for p in graph if p not in allowed and (NAMES.search(name_of(p)) or is_prefix(p))
    }


def tainted(graph, rocm):
    """paths whose closure contains another ROCm"""
    memo = {}

    def t(p):
        if p not in memo:
            memo[p] = False
            memo[p] = p in rocm or any(t(r) for r in graph.get(p, []) if r != p)
        return memo[p]

    return {p for p in graph if t(p)}


def chain(graph, roots, target):
    """the shortest reference chain root -> ... -> target, for messages"""
    prev, queue = {r: None for r in roots}, list(roots)
    for p in queue:
        if p == target:
            out = []
            while p is not None:
                out.append(p)
                p = prev[p]
            return out[::-1]
        for r in graph.get(p, []):
            if r not in prev:
                prev[r] = p
                queue.append(r)
    return [target]


def load(cfg):
    graph = {}
    for f in cfg["graphs"]:
        graph |= read_graph(f)
    allowed = set()
    for f in cfg["allowed"]:
        allowed |= set(read_graph(f))
    return graph, allowed


def check(cfg):
    graph, allowed = load(cfg)
    rocm = other_rocm(graph, allowed)
    if not rocm:
        return
    roots = [r for r in cfg["roots"] if r in graph]
    print("therock: the system closure contains ROCm not from therock-nixos:", file=sys.stderr)
    for p in sorted(rocm, key=name_of):
        via = " <- ".join(name_of(x) for x in reversed(chain(graph, roots, p)[:-1]))
        print(f"  {name_of(p)}  <- {via}", file=sys.stderr)
    print(
        "Relink the package that pulls it in onto TheRock (config.therock.rock.relink pkg),\n"
        "or set therock.exclusive = false.",
        file=sys.stderr,
    )
    sys.exit(1)


def relink(cfg):
    graph, allowed = load(cfg)
    olds = cfg["outputs"]  # output name -> original store path
    self_paths = set(olds.values())
    rocm = other_rocm(graph, allowed) - self_paths
    bad = tainted(graph, rocm)
    runtime, sdk = cfg["runtime"], cfg["sdk"]
    direct = {r for o in self_paths for r in graph.get(o, [])} - self_paths
    errors = []
    for d in sorted(direct & bad - rocm):
        hit = next(r for r in sorted(rocm) if r in chain(graph, [d], r))
        via = " -> ".join(name_of(x) for x in chain(graph, [d], hit))
        errors.append(f"{name_of(d)} depends on another ROCm ({via}); relink it first")
    by_hash = {os.path.basename(p)[:32]: p for p in rocm}
    self_hash = {
        os.path.basename(old)[:32].encode(): os.path.basename(os.environ[o])[:32].encode()
        for o, old in olds.items()
    }
    bad_hashes = {os.path.basename(p)[:32].encode() for p in bad - self_paths}

    def compiler(root):  # nixpkgs' ROCm LLVM (llvm-*-rocm, hipClang)
        n = name_of(root)
        return n.endswith("-rocm") or "clang" in n.lower()

    def target(root, sub):
        """TheRock path for `root` + `sub` (e.g. "/lib/libamdhip64.so.7")"""
        if sub == "":  # a ROCM_PATH-like prefix: the SDK if it has a compiler
            has_cc = os.path.exists(os.path.join(root, "bin/hipcc")) or compiler(root)
            return sdk if has_cc else runtime
        sub = re.sub(r"^/lib64(?=/|$)", "/lib", sub)
        bases = [runtime] if re.match(r"^/lib(/|$)", sub) else []
        bases += [sdk] + ([sdk + "/lib/llvm"] if compiler(root) else [])
        return next((b + sub for b in bases if os.path.lexists(b + sub)), None)

    def rewrite(data, where):
        def sub(m):
            h = m.group(1)
            if h in self_hash:
                return b"/nix/store/" + self_hash[h] + b"-" + m.group(2) + m.group(3)
            root = by_hash.get(h.decode())
            if root is None:
                return m.group(0)
            t = target(root, m.group(3).decode())
            if t is None:
                errors.append(f"{where}: no TheRock equivalent of {name_of(root)}{m.group(3).decode()}")
                return m.group(0)
            return t.encode()

        return PATH_RE.sub(sub, data)

    def patch_elf(f):
        rp = subprocess.run(["patchelf", "--print-rpath", f], capture_output=True, text=True)
        if rp.returncode != 0 or not rp.stdout.strip():
            return
        new = []
        for e in rp.stdout.strip().split(":"):
            m = PATH_RE.fullmatch(e.encode())
            if m and m.group(1).decode() in by_hash:
                t = target(by_hash[m.group(1).decode()], m.group(3).decode()) or runtime + "/lib"
                e = t if os.path.isdir(t) else runtime + "/lib"
            if e not in new:
                new.append(e)
        if new != rp.stdout.strip().split(":"):
            subprocess.run(["patchelf", "--set-rpath", ":".join(new), f], check=True)

    for o, old in olds.items():
        new = os.environ[o]
        subprocess.run(["cp", "-a", "--no-preserve=ownership", old + "/.", new], check=True)
        subprocess.run(["chmod", "-R", "u+w", new], check=True)
        for dirpath, dirs, files in os.walk(new):
            for f in [os.path.join(dirpath, x) for x in files + dirs]:
                rel = f[len(new) :]
                if os.path.islink(f):
                    t = os.readlink(f).encode()
                    nt = rewrite(t, rel)
                    if nt != t:
                        os.remove(f)
                        os.symlink(nt.decode(), f)
                    continue
                if not os.path.isfile(f):
                    continue
                data = open(f, "rb").read()
                if not any(h in data for h in list(self_hash) + list(map(str.encode, by_hash))):
                    continue
                if data[:4] == b"\x7fELF":
                    patch_elf(f)
                    data = open(f, "rb").read()
                    for a, b in self_hash.items():
                        data = data.replace(a, b)  # same length: safe in binaries
                else:
                    nd = rewrite(data, rel)
                    if len(nd) != len(data):
                        try:
                            data.decode()
                        except UnicodeDecodeError:
                            errors.append(f"{rel}: binary file refers to another ROCm")
                            continue
                    data = nd
                mode = os.stat(f).st_mode
                open(f, "wb").write(data)
                os.chmod(f, mode)

    # Nothing of another ROCm may be left (Nix finds references by hash).
    for o in olds:
        new = os.environ[o]
        for dirpath, dirs, files in os.walk(new):
            for f in [os.path.join(dirpath, x) for x in files + dirs]:
                blob = os.readlink(f).encode() if os.path.islink(f) else (open(f, "rb").read() if os.path.isfile(f) else b"")
                for h in bad_hashes:
                    if h in blob:
                        p = next(q for q in bad if os.path.basename(q)[:32].encode() == h)
                        errors.append(f"{f[len(new):]}: still refers to {name_of(p)}")
    if errors:
        print(f"therock relink: {len(errors)} problem(s):", file=sys.stderr)
        for e in sorted(set(errors))[:40]:
            print("  " + e, file=sys.stderr)
        sys.exit(1)
    print(f"therock relink: {len(rocm & direct)} ROCm reference(s) moved to TheRock: "
          + ", ".join(sorted(name_of(p) for p in rocm & direct)))


if __name__ == "__main__":
    {"relink": relink, "check": check}[sys.argv[1]](json.load(open(sys.argv[2])))
