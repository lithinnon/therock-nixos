// A HIP kernel and a rocBLAS SGEMM, checked against the CPU.
#include <hip/hip_runtime.h>
#include <rocblas/rocblas.h>
#include <cmath>
#include <cstdio>
#include <vector>

__global__ void scale(float* x, float s, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) x[i] *= s;
}

#define CHECK(e) do { if ((e) != 0) { std::fprintf(stderr, "failed: %s\n", #e); return 1; } } while (0)

int main() {
  const int n = 256;
  std::vector<float> A(n * n), B(n * n), C(n * n), R(n * n, 0);
  for (int i = 0; i < n * n; i++) { A[i] = (i % 7) * 0.25f; B[i] = (i % 5) * 0.5f; }
  for (int j = 0; j < n; j++)
    for (int k = 0; k < n; k++)
      for (int i = 0; i < n; i++) R[i + j * n] += 2 * A[i + k * n] * B[k + j * n];

  float *a, *b, *c;
  CHECK(hipMalloc(&a, n * n * 4)); CHECK(hipMalloc(&b, n * n * 4)); CHECK(hipMalloc(&c, n * n * 4));
  CHECK(hipMemcpy(a, A.data(), n * n * 4, hipMemcpyHostToDevice));
  CHECK(hipMemcpy(b, B.data(), n * n * 4, hipMemcpyHostToDevice));
  scale<<<n * n / 256, 256>>>(a, 2.0f, n * n);  // A *= 2 on the GPU
  CHECK(hipGetLastError());

  rocblas_handle h;
  CHECK(rocblas_create_handle(&h));
  const float one = 1, zero = 0;
  CHECK(rocblas_sgemm(h, rocblas_operation_none, rocblas_operation_none, n, n, n, &one, a, n, b, n, &zero, c, n));
  CHECK(hipMemcpy(C.data(), c, n * n * 4, hipMemcpyDeviceToHost));

  double err = 0;
  for (int i = 0; i < n * n; i++) err = std::fmax(err, std::fabs(C[i] - R[i]) / (std::fabs(R[i]) + 1));
  hipDeviceProp_t p;
  CHECK(hipGetDeviceProperties(&p, 0));
  std::printf("%s: kernel + rocBLAS sgemm, rel err %.1e\n", p.gcnArchName, err);
  return err < 1e-4 ? 0 : 1;
}
