# gpu-check: verify a TheRock SDK on this machine's GPU (needs /dev/kfd).
#
# Substituted by flake.nix: @targets@ is "gfx=/nix/store/...-rocm-sdk-..." pairs.
set -uo pipefail

declare -A SDKS=(@targets@)

detect() {
  for f in /sys/class/kfd/kfd/topology/nodes/*/properties; do
    v=$(awk '$1 == "gfx_target_version" { print $2 }' "$f" 2>/dev/null)
    [ "${v:-0}" -gt 0 ] && printf 'gfx%d%d%x\n' $((v / 10000)) $((v / 100 % 100)) $((v % 100))
  done | sort -u
}

gfx=${1:-$(detect | head -1)}
[ -n "$gfx" ] || { echo "gpu-check: no AMD GPU found under /sys/class/kfd" >&2; exit 2; }
sdk=${SDKS[$gfx]:-}
[ -n "$sdk" ] || { echo "gpu-check: $gfx is not hashed; run: nix run .#update -- <version> $gfx" >&2; exit 2; }

export ROCM_PATH=$sdk HIP_PATH=$sdk
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0

check() { # name, command...
  local name=$1; shift
  if out=$("$@" 2>&1); then
    printf '  \e[32m✓\e[0m %-26s %s\n' "$name" "$(tail -1 <<<"$out")"
  else
    printf '  \e[31m✗\e[0m %-26s %s\n' "$name" "$(tail -3 <<<"$out" | tr '\n' ' ')"
    failed=$((failed + 1))
  fi
}

cat >"$tmp/vadd.hip" <<'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>
__global__ void vadd(const float* a, const float* b, float* c, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x; if (i < n) c[i] = a[i] + b[i];
}
int main() {
  const int n = 1 << 20; float *a, *b, *c;
  if (hipMallocManaged(&a, n * 4) || hipMallocManaged(&b, n * 4) || hipMallocManaged(&c, n * 4)) return 1;
  for (int i = 0; i < n; i++) { a[i] = i; b[i] = 2 * i; }
  vadd<<<n / 256, 256>>>(a, b, c, n);
  if (hipDeviceSynchronize()) return 1;
  for (int i = 0; i < n; i++) if (c[i] != 3.0f * i) { printf("mismatch at %d\n", i); return 1; }
  hipDeviceProp_t p; if (hipGetDeviceProperties(&p, 0)) return 1;
  printf("%s (%s)\n", p.name, p.gcnArchName); return 0;
}
EOF

cat >"$tmp/sgemm.cpp" <<'EOF'
#include <hip/hip_runtime.h>
#include <rocblas/rocblas.h>
#include <cmath>
#include <cstdio>
#include <vector>
int main() {
  const int n = 512; std::vector<float> A(n * n), B(n * n), C(n * n), R(n * n, 0);
  for (int i = 0; i < n * n; i++) { A[i] = (i % 7) * 0.25f; B[i] = (i % 5) * 0.5f; }
  for (int j = 0; j < n; j++) for (int k = 0; k < n; k++) for (int i = 0; i < n; i++) R[i + j * n] += A[i + k * n] * B[k + j * n];
  float *a, *b, *c; hipMalloc(&a, n * n * 4); hipMalloc(&b, n * n * 4); hipMalloc(&c, n * n * 4);
  hipMemcpy(a, A.data(), n * n * 4, hipMemcpyHostToDevice); hipMemcpy(b, B.data(), n * n * 4, hipMemcpyHostToDevice);
  rocblas_handle h; if (rocblas_create_handle(&h) != rocblas_status_success) return 1;
  const float one = 1, zero = 0;
  if (rocblas_sgemm(h, rocblas_operation_none, rocblas_operation_none, n, n, n, &one, a, n, b, n, &zero, c, n) != rocblas_status_success) return 1;
  hipMemcpy(C.data(), c, n * n * 4, hipMemcpyDeviceToHost);
  double err = 0; for (int i = 0; i < n * n; i++) err = fmax(err, fabs(C[i] - R[i]) / (fabs(R[i]) + 1));
  printf("512x512 rel err %.1e\n", err); return err < 1e-4 ? 0 : 1;
}
EOF

echo "gpu-check: $gfx with $sdk"
check "rocminfo sees $gfx" sh -c "'$sdk/bin/rocminfo' | grep -m1 -o '$gfx'"
check "amd-smi" sh -c "'$sdk/bin/amd-smi' static --asic | grep -m1 MARKET_NAME | sed 's/^ *//'"
check "hipcc compile" "$sdk/bin/hipcc" --offload-arch="$gfx" -O2 "$tmp/vadd.hip" -o "$tmp/vadd"
check "HIP kernel runs" "$tmp/vadd"
check "rocBLAS compile" "$sdk/bin/hipcc" --offload-arch="$gfx" -O2 "$tmp/sgemm.cpp" -o "$tmp/sgemm" \
  -L"$sdk/lib" -lrocblas -Wl,-rpath,"$sdk/lib"
check "rocBLAS sgemm vs CPU" "$tmp/sgemm"

if [ "$failed" -eq 0 ]; then echo "gpu-check: all passed"; else echo "gpu-check: $failed failed"; exit 1; fi
