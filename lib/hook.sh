# therock setup hook (rock.hook): build or develop HIP/ROCm software against
# the SDK; the result links the runtime prefix, not the 3 GB SDK.
export ROCM_PATH=@sdk@ HIP_PATH=@sdk@ HIP_PLATFORM=amd
export GPU_TARGETS="@targets@" AMDGPU_TARGETS="@targets@" HIPARCHS="@targets@"
export PYTORCH_ROCM_ARCH="@targets@"
export HIPCXX=@sdk@/lib/llvm/bin/clang++ # CMake's HIP language
# ROCm's CMake packages read GPU_TARGETS as a CMake variable, not from the
# environment (else they probe a GPU, absent in the sandbox, and use gfx906).
export CMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE:-@toolchain@}
addToSearchPath PATH @sdk@/bin
addToSearchPath CMAKE_PREFIX_PATH @sdk@

# RPATH entries into the SDK -> the runtime prefix, where every shared library
# of the SDK also is (dontTherockRuntime=1 keeps them).
therockRuntimeRpath() {
  [ -n "${dontTherockRuntime-}" ] && return
  local o f rp new from=@sdk@/lib to=@runtime@/lib
  for o in $(getAllOutputNames); do
    while IFS= read -r -d '' f; do
      isELF "$f" || continue
      rp=$(patchelf --print-rpath "$f" 2>/dev/null) || continue
      new=${rp//"$from"/"$to"}
      [ "$new" = "$rp" ] || patchelf --set-rpath "$new" "$f"
    done < <(find "${!o}" -type f -print0)
  done
}
postFixupHooks+=(therockRuntimeRpath)
