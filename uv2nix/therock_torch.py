"""therock-nixos: this venv's GPU set, for the torch every set shares.

torch's store path is the same for every set of GPUs; what differs lives in
the venv (this module comes with its rocm-sdk-core placeholder). torch's
_rocm_init imports it before loading its libraries:

  * ROCm's kernel-pack loader looks for torch's per-GPU packs next to the
    real libtorch_hip.so, which the venv doesn't change: point it at the
    venv's packs (torch/.kpack/torch_gfxNNNN.kpack & co.) instead.
  * AOTriton looks for its kernel images next to the real libaotriton: load
    this set's copy (next to its images) before torch loads the shared one.
"""

import ctypes
import glob
import os

_site = os.path.dirname(os.path.abspath(__file__))

if "ROCM_KPACK_PATH" not in os.environ:
    _packs = sorted(glob.glob(os.path.join(_site, "*", ".kpack", "*.kpack")))
    if _packs:
        os.environ["ROCM_KPACK_PATH"] = os.pathsep.join(_packs)

for _lib in glob.glob(os.path.join(_site, "_therock_aotriton", "libaotriton_v2.so.*")):
    ctypes.CDLL(_lib, mode=ctypes.RTLD_GLOBAL)
