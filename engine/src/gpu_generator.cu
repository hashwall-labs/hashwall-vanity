#include <stdint.h>
#include <stdio.h>
#include <assert.h>

#include <curand_kernel.h>

typedef uint8_t  u8;
typedef uint32_t u32;
typedef uint64_t u64;

#include "arena.c"
#include "third_party/sha256.cu"
#include "sha512.cu"
#include "ed25519.cu"

__constant__ static char *seed_prefix   = "multisig";
__constant__ static char *seed_multisig = "multisig";
__constant__ static char *pda_postfix   = "ProgramDerivedAddress";
__constant__ static u8    program_id[32] = { 6, 129, 196, 206, 71, 226, 35, 104, 184, 177, 85, 94, 200, 135, 175, 9, 46, 252, 126, 251, 182, 108, 163, 245, 47, 191, 104, 212, 172, 156, 183, 168 };

#define MULTISIG_SEEDS_SIZE (8 + 8 + 32 + 1 + 32 + 21) // "multisig" + "multisig" + pk + bump + program_id + "ProgramDerivedAddress"
#define VAULT_SEEDS_SIZE (8 + 32 + 5 + 1 + 1+ 32 + 21) // "multisig" + multisig_pda + "vault" + index + bump + program_id + "ProgramDerivedAddress"

#define CUDA_CHECK(call)                                              \
    do {                                                              \
        cudaError_t err = call;                                       \
        if (err != cudaSuccess) {                                     \
            fprintf(stderr, "CUDA Error in %s at %s:%d: %s\n", #call, \
                    __FILE__, __LINE__, cudaGetErrorString(err));     \
            exit(1);                                                  \
        }                                                             \
    } while (0)

#if CARD == 1060
    #define BLOCK_SIZE 256
    #define MAX_THREADS_PER_SM 2048
    #define SM_COUNT 9
#elif CARD == 1650
    #define BLOCK_SIZE 256
    #define MAX_THREADS_PER_SM 1024
    #define SM_COUNT 14
#elif CARD == 5060
    #define BLOCK_SIZE 256
    #define MAX_THREADS_PER_SM 1536
    #define SM_COUNT 36
#elif CARD == 3050
    #define BLOCK_SIZE 256
    #define MAX_THREADS_PER_SM 1536
    #define SM_COUNT 20
#else
    #error "Invalid CARD value"
#endif

#define BLOCKS_PER_SM (MAX_THREADS_PER_SM / BLOCK_SIZE)
#define GRID_SIZE (BLOCKS_PER_SM * SM_COUNT)
#define TOTAL_THREADS (GRID_SIZE * BLOCK_SIZE)

#define TID (blockDim.x * blockIdx.x + threadIdx.x)

#ifdef TOTAL_THREADS
# define NTHREADS TOTAL_THREADS
#else
# define NTHREADS (gridDim.x * blockDim.x)
#endif

#define each_coal_(tid, nthreads, it, size) (size_t it = (tid); it < (tid) + (nthreads)*(size)/sizeof(u32); it += (nthreads))
#define each_coal(it, size) each_coal_((TID), (NTHREADS), (it), (size))

typedef struct {
    void *memory;
    size_t size;
} DeviceMemoryHeader;

typedef struct {
    DeviceMemoryHeader header;
    curandStateMRG32k3a *curand_states;
    u32 *ed25519_seeds;
    u32 *public_keys;
    u32 *pdas;
    u32 *bumps;
    u32 *b58pdas;
    u32 *found;
} DeviceMemory;

__constant__ u64 d_urandom_seed;
__global__ void init_curand_states(DeviceMemory memory) {
    //curand_init(5051, TID, 0, memory.curand_states + TID);
    curand_init(d_urandom_seed, TID, 0, memory.curand_states + TID);
}

__constant__ char b58digits_ordered[] = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

__device__ __forceinline__ unsigned int fast_div58(unsigned int x) {
    return (x * 1130u) >> 16u;
}

__device__ __forceinline__ unsigned int fast_mod58(unsigned int x) {
    return x - fast_div58(x) * 58u;
}

__device__ bool b58enc(char *b58, unsigned int *b58sz, const unsigned char *data, unsigned int binsz) {
    const unsigned char *bin = data;
    unsigned int carry;
    unsigned int i, j, high, zcount = 0;
    unsigned int size;

    while (zcount < binsz && !bin[zcount])
        ++zcount;

    size = (binsz - zcount) * 138 / 100 + 1;

    unsigned char buf[45];
    for (i = 0; i < 45; ++i) buf[i] = 0;

    for (i = zcount, high = size - 1; i < binsz; ++i, high = j) {
        for (carry = bin[i], j = size - 1; (j > high) || carry; --j) {
            carry += 256u * buf[j];
            buf[j] = (unsigned char)fast_mod58(carry);
            carry = fast_div58(carry);
            if (!j) break;
        }
    }

    for (j = 0; j < size && !buf[j]; ++j);

    if (*b58sz <= zcount + size - j) {
        *b58sz = zcount + size - j + 1;
        return false;
    }

    if (zcount) {
        for (i = 0; i < zcount; ++i) b58[i] = '1';
    }
    for (i = zcount; j < size; ++i, ++j) {
        b58[i] = b58digits_ordered[buf[j]];
    }

    b58[i] = '\0';
    *b58sz = i + 1;
    return true;
}

__device__ int global_found = 0;

__global__ void kernel(DeviceMemory memory) {
    char prefix[6] = "11111";
    int prefix_size = 5;

    for (int i = 0; i < 1; i++) {
        if (global_found) break;

        //
        // random seeds
        //

        for each_coal(i, ED25519_SEED_SIZE) {
            u32 chunk = curand(memory.curand_states + TID);
            memory.ed25519_seeds[i] = chunk;
        }

        //
        // ed25519
        //

        uint32_t m[SHA512_BLOCK_LENGTH/sizeof(u32)];

        uint64_t state[8];
        sha512_init_state(state);

        {
            int cursor = 0;
            for each_coal(i, ED25519_SEED_SIZE)    { m[cursor++] = memory.ed25519_seeds[i]; }
                                                     m[cursor++] = 0x80000000;
            for (int i = cursor; i < 128/4-1; i++) { m[cursor++] = 0; }
                                                     m[cursor++] = ED25519_SEED_SIZE*8;
        }

        sha512_transform_state(state, m, SHA512_OUTPUT_DATA, SHA512_DATA_MEMORY_LOCAL);

        // because ed25519 operates on individual chars
        for (int i = 0; i < ED25519_SEED_SIZE/4; i++) { m[i] = __nv_bswap32(m[i]); }

        ge25519_p3 A;
        u8 *priv_key = (u8 *)m;
        u8 pub_key[ED25519_PUB_KEY_SIZE];

        priv_key[0] &= 248;
        priv_key[31] &= 63;
        priv_key[31] |= 64;

        ge25519_scalarmult_base(&A, priv_key);
        ge25519_p3_tobytes(pub_key, &A);

        {
            int i = 0;
            for each_coal(it, ED25519_PUB_KEY_SIZE) {
                memory.public_keys[it] = *((uint32_t *)pub_key + i);
                i += 1;
            }
        }

        //
        // PDA
        //

        u8 seeds[MULTISIG_SEEDS_SIZE];
        u8 bump = 255;
        int bump_offset;

        {
            int cursor = 0;

            for (int i = 0; i < 8; i++)  { seeds[cursor++] = seed_prefix[i]; }
            for (int i = 0; i < 8; i++)  { seeds[cursor++] = seed_multisig[i]; }
            for (int i = 0; i < 32; i++) { seeds[cursor++] = pub_key[i]; }
            bump_offset = cursor;
                                           seeds[cursor++] = bump;
            for (int i = 0; i < 32; i++) { seeds[cursor++] = program_id[i]; }
            for (int i = 0; i < 21; i++) { seeds[cursor++] = pda_postfix[i]; }
        }

        int is_on_curve = 1;
        u8 hash[32];
        do {
            SHA256(seeds, MULTISIG_SEEDS_SIZE, hash);
            is_on_curve = is_valid_point(hash);
            bump -= 1;
            seeds[bump_offset] = bump;
        } while (is_on_curve);

        {
            int i = 0;
            for each_coal(it, SHA256_DIGEST_LENGTH) {
                memory.pdas[it] = *((uint32_t *)hash + i);
                i += 1;
            }
        }
        for each_coal(it, sizeof(u32)) {
            memory.bumps[it] = bump + 1;
        }

        //
        // base58
        //

        char b58[48] = {0};
        u32 b58_size = 45;
        b58enc(b58, &b58_size, hash, 32);

        {
            int i = 0;
            for each_coal(it, 48) {
                memory.b58pdas[it] = *((uint32_t *)b58 + i);
                i += 1;
            }
        }

        //
        // check prefix
        //

        int found = 1;

        for (int i = 0; i < prefix_size; i++) {
            if (prefix[i] != b58[i]) {
                found = 0;
                break;
            }
        }

        if (found) {
            atomicAdd(&global_found, 1);

            for each_coal(i, 4) {
                memory.found[i] = found;
            }
        }
    }
}

int main() {
    // init memory
    Arena device_arena;
    DeviceMemory device_memory = {0};
    device_memory.header.size = 1*1024*1024*1024;
    cudaMalloc(&device_memory.header.memory, device_memory.header.size);
    cudaMemset(device_memory.header.memory, 0, device_memory.header.size);
    arena_init(&device_arena, device_memory.header.memory, device_memory.header.size);

    // TODO: bad alignment can degrade performance
    device_memory.curand_states = arena_push_array(&device_arena, TOTAL_THREADS, curandStateMRG32k3a);
    device_memory.ed25519_seeds = arena_push_array(&device_arena, TOTAL_THREADS*ED25519_SEED_SIZE, u32);
    device_memory.public_keys   = arena_push_array(&device_arena, TOTAL_THREADS*ED25519_PUB_KEY_SIZE, u32);
    device_memory.pdas          = arena_push_array(&device_arena, TOTAL_THREADS*SHA256_DIGEST_LENGTH, u32);
    device_memory.bumps         = arena_push_array(&device_arena, TOTAL_THREADS, u32);
    device_memory.b58pdas       = arena_push_array(&device_arena, TOTAL_THREADS*48, u32);
    device_memory.found         = arena_push_array(&device_arena, TOTAL_THREADS, u32);

    DeviceMemory mirror = {0};
    mirror.header.memory = malloc(device_memory.header.size);
    mirror.header.size = device_memory.header.size;
#define COPY(type, name) mirror.name = (type *)((u8 *)mirror.header.memory + ((u8 *)device_memory.name - (u8 *)device_memory.header.memory))
    COPY(curandStateMRG32k3a, curand_states);
    COPY(u32, ed25519_seeds);
    COPY(u32, public_keys);
    COPY(u32, pdas);
    COPY(u32, bumps);
    COPY(u32, b58pdas);
    COPY(u32, found);
#undef COPY

    // init curand states
    u64 h_urandom_seed;
    FILE *fp = fopen("/dev/urandom", "rb");
    assert(fread(&h_urandom_seed, sizeof(u64), 1, fp) > 0);
    fclose(fp);

    CUDA_CHECK(cudaMemcpyToSymbol(
        d_urandom_seed,
        &h_urandom_seed,
        sizeof(u64),
        0,
        cudaMemcpyHostToDevice
    ));

    init_curand_states<<<GRID_SIZE, BLOCK_SIZE>>>(device_memory);

    cudaEvent_t event_start, event_stop;
    cudaEventCreate(&event_start);
    cudaEventCreate(&event_stop);
    // main loop
    int found = 0;
    while (!found) {
        cudaEventRecord(event_start);
        {
            // TODO: run multiple rounds inside the kernel instead of rerunning
            // the kernel for every single round
            kernel<<<GRID_SIZE, BLOCK_SIZE>>>(device_memory);
            CUDA_CHECK(cudaDeviceSynchronize());
        }
        cudaEventRecord(event_stop);
        cudaEventSynchronize(event_stop);
        float ms = 0;
        cudaEventElapsedTime(&ms, event_start, event_stop);
        printf("kernel<<<%d, %d>>>() exec time: %f ms\n", GRID_SIZE, BLOCK_SIZE, ms);

        CUDA_CHECK(cudaMemcpy(
            mirror.found, device_memory.found,
            TOTAL_THREADS*sizeof(u32),
            cudaMemcpyDeviceToHost
        ));
        for (int tid = 0; tid < TOTAL_THREADS; tid++) {
            //if (tid == 0) {
            if (mirror.found[tid]) {
                found = 1;

                CUDA_CHECK(cudaMemcpy(
                    mirror.ed25519_seeds, device_memory.ed25519_seeds,
                    TOTAL_THREADS*ED25519_SEED_SIZE*sizeof(u32),
                    cudaMemcpyDeviceToHost
                ));
                CUDA_CHECK(cudaMemcpy(
                    mirror.public_keys, device_memory.public_keys,
                    TOTAL_THREADS*ED25519_PUB_KEY_SIZE*sizeof(u32),
                    cudaMemcpyDeviceToHost
                ));

                printf("create_key: ");
                for each_coal_(tid, NTHREADS, i, ED25519_PUB_KEY_SIZE) {
                    printf("%08x", htobe32(mirror.public_keys[i]));
                }
                printf("\n");

                printf("keypair: [");
                for each_coal_(tid, NTHREADS, i, ED25519_SEED_SIZE) {
                    u32 c = mirror.ed25519_seeds[i];
                    printf("%d,%d,%d,%d,", (u8)(c >> 24), (u8)(c >> 16), (u8)(c >> 8), (u8)(c));
                }

                for each_coal_(tid, NTHREADS, i, ED25519_PUB_KEY_SIZE) {
                    u32 c = mirror.public_keys[i];
                    printf("%d,%d,%d,%d,", (u8)(c), (u8)(c >> 8), (u8)(c >> 16), (u8)(c >> 24));
                }
                printf("]\n");

#if 0
                printf("multisig pda: ");
                for each_coal_(tid, NTHREADS, i, SHA256_DIGEST_LENGTH) {
                    printf("%08x", htobe32(mirror.pdas[i]));
                }
                printf("\n");

                printf("multisig pda (base58): ");
                for each_coal_(tid, NTHREADS, i, 48) {
                    u32 c = mirror.b58pdas[i];
                    printf("%c%c%c%c", (u8)(c), (u8)(c >> 8), (u8)(c >> 16), (u8)(c >> 24));
                }
                printf("\n");

                printf("bump: %d\n", mirror.bumps[tid]);
#endif

                break;
            }
        }
    }

    // copy all device memory to host for debug purposes
#if 0
    {
        DeviceMemory mirror = {0};
        mirror.header.memory = malloc(device_memory.header.size);
        mirror.header.size = device_memory.header.size;

        // TODO: automate this via introspection?
#define COPY(type, name) mirror.name = (type *)((u8 *)mirror.header.memory + ((u8 *)device_memory.name - (u8 *)device_memory.header.memory))
        COPY(curandStateMRG32k3a, curand_states);
        COPY(u32, ed25519_seeds);
        COPY(u32, public_keys);
        COPY(u32, pdas);
        COPY(u32, bumps);
        COPY(u32, b58pdas);
        COPY(u32, found);
#undef COPY

        CUDA_CHECK(cudaMemcpy(
            mirror.header.memory, device_memory.header.memory,
            device_memory.header.size,
            cudaMemcpyDeviceToHost
        ));

#undef TID
#define TID 0
        printf("create_key: ");
        for each_coal(i, ED25519_PUB_KEY_SIZE) {
            printf("%08x", htobe32(mirror.public_keys[i]));
        }
        printf("\n");

        printf("keypair: [");
        for each_coal(i, ED25519_SEED_SIZE) {
            u32 c = mirror.ed25519_seeds[i];
            printf("%d,%d,%d,%d,", (u8)(c >> 24), (u8)(c >> 16), (u8)(c >> 8), (u8)(c));
        }

        for each_coal(i, ED25519_PUB_KEY_SIZE) {
            u32 c = mirror.public_keys[i];
            printf("%d,%d,%d,%d,", (u8)(c >> 24), (u8)(c >> 16), (u8)(c >> 8), (u8)(c));
        }
        printf("]\n");

        printf("multisig pda: ");
        for each_coal(i, SHA256_DIGEST_LENGTH) {
            printf("%08x", htobe32(mirror.pdas[i]));
        }
        printf("\n");

        printf("multisig pda (base58): ");
        for each_coal(i, 48) {
            u32 c = mirror.b58pdas[i];
            printf("%c%c%c%c", (u8)(c), (u8)(c >> 8), (u8)(c >> 16), (u8)(c >> 24));
        }
        printf("\n");

        printf("bump: %d\n", mirror.bumps[TID]);
    }
#endif

    return 0;
}
