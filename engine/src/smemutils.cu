/*
TODO:
- try inlining these
*/

__device__ void memwrite64(uint32_t *dst, int offset, int stride, int i, uint64_t *src) {
    const int idx1 = offset + stride * i * 2;
    const int idx2 = offset + stride * (i * 2 + 1);
    dst[idx1] = (uint32_t)(*src >> 32);
    dst[idx2] = (uint32_t)(*src);
}

__device__ void memwrite64(uint32_t *dst, int offset, int stride, int i, uint64_t src) {
    const int idx1 = offset + stride * i * 2;
    const int idx2 = offset + stride * (i * 2 + 1);
    dst[idx1] = (uint32_t)(src >> 32);
    dst[idx2] = (uint32_t)src;
}

__device__ void memread64(uint64_t *dst, uint32_t *src, int offset, int stride, int i) {
    const int idx1 = offset + stride * i * 2;
    const int idx2 = offset + stride * (i * 2 + 1);
    *dst = (uint64_t)src[idx1] << 32 | (uint64_t)src[idx2];
}

__device__ void smemwrite64(uint32_t *dst, int i, uint64_t *src) {
    int offset = threadIdx.x;
    int stride = blockDim.x;
    memwrite64(dst, offset, stride, i, src);
}

__device__ void smemwrite64(uint32_t *dst, int i, uint64_t src) {
    int offset = threadIdx.x;
    int stride = blockDim.x;
    memwrite64(dst, offset, stride, i, src);
}

__device__ void smemread64(uint64_t *dst, uint32_t *src, int i) {
    int offset = threadIdx.x;
    int stride = blockDim.x;
    memread64(dst, src, offset, stride, i);
}

__device__ void smemwrite32(uint32_t *dst, int i, uint32_t *src) {
    const int sidx = threadIdx.x + i * blockDim.x;
    dst[sidx] = *src;
}

__device__ void smemwrite32(uint32_t *dst, int i, uint32_t src) {
    const int sidx = threadIdx.x + i * blockDim.x;
    dst[sidx] = src;
}

__device__ void smemread32(uint32_t *dst, uint32_t *src, int i) {
    const int sidx = threadIdx.x + i * blockDim.x;
    *dst = src[sidx];
}

__device__ void lmemwrite64(uint32_t *dst, int i, uint64_t *src) {
    int offset = 0;
    int stride = 1;
    memwrite64(dst, offset, stride, i, src);
}

__device__ void lmemwrite64(uint32_t *dst, int i, uint64_t src) {
    int offset = 0;
    int stride = 1;
    memwrite64(dst, offset, stride, i, src);
}

__device__ void lmemread64(uint64_t *dst, uint32_t *src, int i) {
    int offset = 0;
    int stride = 1;
    memread64(dst, src, offset, stride, i);
}
