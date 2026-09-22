#include <cuda_runtime.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <vector>

struct SingletonInput {
    uint32_t group_idx;
    uint16_t k16;
    uint16_t reserved;
    uint32_t s_target;
    uint32_t m16;
};

__device__ __forceinline__ uint32_t keeloq_encrypt_dev(uint64_t key, uint32_t pt, int rounds) {
    uint32_t x = pt;
    for (int r = 0; r < rounds; ++r) {
        uint32_t nlf_in = (((x >> 31) & 1U) << 4) |
                          (((x >> 26) & 1U) << 3) |
                          (((x >> 20) & 1U) << 2) |
                          (((x >> 9) & 1U) << 1) |
                          ((x >> 1) & 1U);
        uint32_t feedback = ((key >> (r & 63)) & 1U) ^
                            ((x >> 16) & 1U) ^
                            (x & 1U) ^
                            ((0x3A5C742EU >> nlf_in) & 1U);
        x = (x >> 1) | (feedback << 31);
    }
    return x;
}

__device__ __forceinline__ uint64_t singleton_candidate(uint16_t k16, uint32_t s_target, uint32_t m16, uint32_t prefix16) {
    uint32_t state = m16;
    uint64_t key = (uint64_t)k16;
    for (int i = 0; i < 48; ++i) {
        uint32_t feedback = (i < 16) ? ((prefix16 >> i) & 1U) : ((s_target >> (i - 16)) & 1U);
        uint32_t nlf_in = (((state >> 31) & 1U) << 4) |
                          (((state >> 26) & 1U) << 3) |
                          (((state >> 20) & 1U) << 2) |
                          (((state >> 9) & 1U) << 1) |
                          ((state >> 1) & 1U);
        uint64_t key_bit = feedback ^
                           ((state >> 16) & 1U) ^
                           (state & 1U) ^
                           ((0x3A5C742EU >> nlf_in) & 1U);
        key |= key_bit << (16 + i);
        state = (state >> 1) | (feedback << 31);
    }
    return key;
}

__global__ void prefilter_kernel(
    const SingletonInput* inputs,
    uint32_t groups_in_batch,
    uint32_t batch_base,
    uint32_t sx0,
    uint32_t cx0,
    uint32_t sx1,
    uint32_t cx1,
    uint32_t* out_group,
    uint32_t* out_prefix,
    uint64_t* out_key,
    uint32_t* out_count
) {
    uint64_t total = (uint64_t)groups_in_batch * 65536ULL;
    uint64_t idx = (uint64_t)blockIdx.x * (uint64_t)blockDim.x + (uint64_t)threadIdx.x;
    if (idx >= total) {
        return;
    }

    uint32_t group_pos = (uint32_t)(idx >> 16);
    uint32_t prefix16 = (uint32_t)(idx & 0xFFFFULL);
    const SingletonInput in = inputs[batch_base + group_pos];
    const uint64_t key = singleton_candidate(in.k16, in.s_target, in.m16, prefix16);
    if (keeloq_encrypt_dev(key, sx0, 528) != cx0) {
        return;
    }
    if (keeloq_encrypt_dev(key, sx1, 528) != cx1) {
        return;
    }

    const uint32_t slot = atomicAdd(out_count, 1U);
    out_group[slot] = in.group_idx;
    out_prefix[slot] = prefix16;
    out_key[slot] = key;
}

static bool read_exact(FILE* f, void* buf, size_t size) {
    return fread(buf, 1, size, f) == size;
}

static bool write_exact(FILE* f, const void* buf, size_t size) {
    return fwrite(buf, 1, size, f) == size;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <input.bin> <output.bin>\n", argv[0]);
        return 2;
    }

    FILE* fin = fopen(argv[1], "rb");
    if (!fin) {
        perror("open input");
        return 1;
    }

    uint32_t num_groups = 0;
    uint32_t num_verify = 0;
    if (!read_exact(fin, &num_groups, sizeof(num_groups)) || !read_exact(fin, &num_verify, sizeof(num_verify))) {
        fclose(fin);
        fprintf(stderr, "invalid input header\n");
        return 1;
    }
    if (num_verify < 2) {
        fclose(fin);
        fprintf(stderr, "need at least 2 verify pairs\n");
        return 1;
    }

    std::vector<SingletonInput> host_inputs(num_groups);
    if (num_groups > 0 && !read_exact(fin, host_inputs.data(), sizeof(SingletonInput) * num_groups)) {
        fclose(fin);
        fprintf(stderr, "invalid singleton payload\n");
        return 1;
    }

    uint32_t sx0 = 0;
    uint32_t cx0 = 0;
    uint32_t sx1 = 0;
    uint32_t cx1 = 0;
    if (!read_exact(fin, &sx0, sizeof(sx0)) || !read_exact(fin, &cx0, sizeof(cx0)) ||
        !read_exact(fin, &sx1, sizeof(sx1)) || !read_exact(fin, &cx1, sizeof(cx1))) {
        fclose(fin);
        fprintf(stderr, "invalid verify payload\n");
        return 1;
    }
    fclose(fin);

    FILE* fout = fopen(argv[2], "wb+");
    if (!fout) {
        perror("open output");
        return 1;
    }
    uint32_t total_count = 0;
    if (!write_exact(fout, &total_count, sizeof(total_count))) {
        fclose(fout);
        return 1;
    }

    SingletonInput* dev_inputs = nullptr;
    uint32_t* dev_group = nullptr;
    uint32_t* dev_prefix = nullptr;
    uint64_t* dev_key = nullptr;
    uint32_t* dev_count = nullptr;
    if (cudaMalloc(&dev_inputs, sizeof(SingletonInput) * (size_t)num_groups) != cudaSuccess) {
        fclose(fout);
        return 1;
    }
    if (num_groups > 0 && cudaMemcpy(dev_inputs, host_inputs.data(), sizeof(SingletonInput) * (size_t)num_groups, cudaMemcpyHostToDevice) != cudaSuccess) {
        cudaFree(dev_inputs);
        fclose(fout);
        return 1;
    }

    const uint32_t batch_groups = 256;
    const size_t batch_capacity = (size_t)batch_groups * 65536U;
    if (cudaMalloc(&dev_group, sizeof(uint32_t) * batch_capacity) != cudaSuccess ||
        cudaMalloc(&dev_prefix, sizeof(uint32_t) * batch_capacity) != cudaSuccess ||
        cudaMalloc(&dev_key, sizeof(uint64_t) * batch_capacity) != cudaSuccess ||
        cudaMalloc(&dev_count, sizeof(uint32_t)) != cudaSuccess) {
        cudaFree(dev_inputs);
        if (dev_group) cudaFree(dev_group);
        if (dev_prefix) cudaFree(dev_prefix);
        if (dev_key) cudaFree(dev_key);
        if (dev_count) cudaFree(dev_count);
        fclose(fout);
        return 1;
    }

    std::vector<uint32_t> host_group(batch_capacity);
    std::vector<uint32_t> host_prefix(batch_capacity);
    std::vector<uint64_t> host_key(batch_capacity);
    const int threads = 256;

    for (uint32_t batch_base = 0; batch_base < num_groups; batch_base += batch_groups) {
        uint32_t groups_in_batch = num_groups - batch_base;
        if (groups_in_batch > batch_groups) {
            groups_in_batch = batch_groups;
        }
        uint32_t zero = 0;
        if (cudaMemcpy(dev_count, &zero, sizeof(zero), cudaMemcpyHostToDevice) != cudaSuccess) {
            fclose(fout);
            return 1;
        }
        uint64_t total = (uint64_t)groups_in_batch * 65536ULL;
        int blocks = (int)((total + threads - 1ULL) / threads);
        prefilter_kernel<<<blocks, threads>>>(dev_inputs, groups_in_batch, batch_base, sx0, cx0, sx1, cx1, dev_group, dev_prefix, dev_key, dev_count);
        if (cudaDeviceSynchronize() != cudaSuccess) {
            fclose(fout);
            return 1;
        }

        uint32_t batch_count = 0;
        if (cudaMemcpy(&batch_count, dev_count, sizeof(batch_count), cudaMemcpyDeviceToHost) != cudaSuccess) {
            fclose(fout);
            return 1;
        }
        if (batch_count > 0) {
            if (cudaMemcpy(host_group.data(), dev_group, sizeof(uint32_t) * batch_count, cudaMemcpyDeviceToHost) != cudaSuccess ||
                cudaMemcpy(host_prefix.data(), dev_prefix, sizeof(uint32_t) * batch_count, cudaMemcpyDeviceToHost) != cudaSuccess ||
                cudaMemcpy(host_key.data(), dev_key, sizeof(uint64_t) * batch_count, cudaMemcpyDeviceToHost) != cudaSuccess) {
                fclose(fout);
                return 1;
            }
            for (uint32_t i = 0; i < batch_count; ++i) {
                if (!write_exact(fout, &host_group[i], sizeof(uint32_t)) ||
                    !write_exact(fout, &host_prefix[i], sizeof(uint32_t)) ||
                    !write_exact(fout, &host_key[i], sizeof(uint64_t))) {
                    fclose(fout);
                    return 1;
                }
            }
            total_count += batch_count;
        }
    }

    rewind(fout);
    write_exact(fout, &total_count, sizeof(total_count));
    fclose(fout);

    cudaFree(dev_inputs);
    cudaFree(dev_group);
    cudaFree(dev_prefix);
    cudaFree(dev_key);
    cudaFree(dev_count);
    return 0;
}