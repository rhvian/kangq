// kanq-test —— QPoW CUDA 内核自检与测速（KanQ 内核改动的三道门 + bench）。
//
// 用法：
//   kanq-test fieldtest                      域运算 + permute(0) 对参考值
//   kanq-test selftest vectors.txt           主机精确实现 + GPU 惰性实现，各对 38 组向量
//   kanq-test pstest   vectors.txt           prestate 分解（主机）+ GPU 挖矿路径，对主机精确摘要
//   kanq-test bench    [秒] [每线程nonce数] [块数]   挖矿内核真实口径测速
//
// 设计原则：先用官方向量把内核钉死，再谈性能。任何内核改动都必须重跑 selftest + pstest。

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <chrono>
#include <fstream>

#include "qpow.cuh"
#include "qpow_host.h"

using namespace qpow;

static bool hex_to_bytes(const std::string &s, uint8_t *out, size_t n) {
    if (s.size() != n * 2) return false;
    for (size_t i = 0; i < n; i++) {
        auto hv = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        };
        int hi = hv(s[i * 2]), lo = hv(s[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}

static std::string bytes_to_hex(const uint8_t *b, size_t n) {
    static const char *H = "0123456789abcdef";
    std::string s;
    s.reserve(n * 2);
    for (size_t i = 0; i < n; i++) { s.push_back(H[b[i] >> 4]); s.push_back(H[b[i] & 0xf]); }
    return s;
}

#define CUDA_CHECK(x)                                                                    \
    do {                                                                                  \
        cudaError_t e = (x);                                                              \
        if (e != cudaSuccess) {                                                           \
            fprintf(stderr, "CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); \
            std::exit(1);                                                                 \
        }                                                                                 \
    } while (0)

struct Vectors {
    std::vector<uint8_t> in;     // n * 96
    std::vector<std::string> want; // 128 hex
    size_t n = 0;
};

static bool load_vectors(const char *path, Vectors &v) {
    std::ifstream f(path);
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return false; }
    std::string a, b, c;
    while (f >> a >> b >> c) {
        uint8_t buf[96];
        if (!hex_to_bytes(a, buf, 32) || !hex_to_bytes(b, buf + 32, 64)) {
            fprintf(stderr, "vector %zu: bad hex\n", v.n);
            return false;
        }
        v.in.insert(v.in.end(), buf, buf + 96);
        v.want.push_back(c);
        v.n++;
    }
    if (v.n == 0) { fprintf(stderr, "no vectors in %s\n", path); return false; }
    printf("载入 %zu 组向量\n", v.n);
    return true;
}

// ---------------------------------------------------------------------------
// 内核
// ---------------------------------------------------------------------------

__global__ void hash_batch_kernel(const uint8_t *data, uint8_t *out, uint32_t n) {
    uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    hash_squeeze_twice(data + (size_t)i * 96, out + (size_t)i * 64);
}

// 每组向量一个 prestate（12 felt）+ 一个 idx；输出第一段 squeeze 的 32 字节
__global__ void prestate_batch_kernel(const u64 *pre, const u64 *idx, uint8_t *out32, uint32_t n) {
    uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    u64 out4[4];
    first_squeeze_from_prestate(pre + (size_t)i * WIDTH, idx[i], out4);
#pragma unroll
    for (int k = 0; k < 4; k++)
#pragma unroll
        for (int b = 0; b < 8; b++) out32[(size_t)i * 32 + k * 8 + b] = (uint8_t)(out4[k] >> (8 * b));
}

__global__ void field_probe_kernel(u64 *out) {
    u64 s[WIDTH];
#pragma unroll
    for (int i = 0; i < WIDTH; i++) s[i] = 0;
    permute(s);
#pragma unroll
    for (int i = 0; i < WIDTH; i++) out[i] = gf_canon(s[i]);
    out[12] = gf_canon(gf_add(0, 0));
    out[13] = gf_canon(gf_mul(1, 1));
    out[14] = gf_canon(gf_mul(2, 2));
    out[15] = gf_canon(gf_mul(P - 1, P - 1));
    out[16] = gf_canon(gf_mul((u64)1 << 32, (u64)1 << 32));
    out[17] = gf_canon(gf_add(P - 1, 1));
    out[18] = gf_canon(gf_mul(3, 7));
    out[19] = gf_canon(gf_sqr(P - 1));
    out[20] = gf_canon(gf_sbox(2));
    out[21] = gf_canon(gf_mul(0, 12345));
    out[22] = gf_canon(gf_add(P - 2, P - 2));
    out[23] = gf_canon(gf_mul(P - 1, 2));
    // 注意别用 2^63 这类"128 位积低 64 位为 0、高位非 0"的输入：那会命中惰性归约里
    // 故意不修正的最终借位（结果偏 +EPS），实测确认过。随机输入触发概率约 2^-33。
    out[24] = gf_canon(gf_sqr(((u64)1 << 63) + 0x12345));
}

// ---------------------------------------------------------------------------
// 子命令
// ---------------------------------------------------------------------------

static int cmd_fieldtest() {
    const int N = 25;
    u64 *d = nullptr;
    CUDA_CHECK(cudaMalloc(&d, N * sizeof(u64)));
    field_probe_kernel<<<1, 1>>>(d);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
    u64 h[N];
    CUDA_CHECK(cudaMemcpy(h, d, sizeof(h), cudaMemcpyDeviceToHost));
    cudaFree(d);

    // permute(0) 的参考值：主机精确实现（它本身在 selftest 里对官方向量）
    uint64_t ref[WIDTH] = {0};
    qpow_host::permute(ref);
    int bad = 0;
    for (int i = 0; i < WIDTH; i++) {
        if (h[i] != ref[i]) {
            printf("permute(0)[%2d] 期望 %016llx 实际 %016llx\n", i,
                   (unsigned long long)ref[i], (unsigned long long)h[i]);
            bad++;
        }
    }
    // (2^63 + 0x12345)^2 mod p：用主机精确算
    uint64_t sq63 = qpow_host::mul(((uint64_t)1 << 63) + 0x12345, ((uint64_t)1 << 63) + 0x12345);
    struct { const char *name; u64 got, want; } sc[] = {
        {"add(0,0)", h[12], 0},
        {"mul(1,1)", h[13], 1},
        {"mul(2,2)", h[14], 4},
        {"mul(p-1,p-1)", h[15], 1},
        {"mul(2^32,2^32)", h[16], EPS},
        {"add(p-1,1)", h[17], 0},
        {"mul(3,7)", h[18], 21},
        {"sqr(p-1)", h[19], 1},
        {"sbox(2)", h[20], 128},
        {"mul(0,12345)", h[21], 0},
        {"add(p-2,p-2)", h[22], P - 4},
        {"mul(p-1,2)", h[23], P - 2},
        {"sqr(2^63+k)", h[24], sq63},
    };
    for (auto &s : sc) {
        if (s.got != s.want) {
            printf("%-16s 期望 %016llx 实际 %016llx\n", s.name,
                   (unsigned long long)s.want, (unsigned long long)s.got);
            bad++;
        }
    }
    printf("field/permute 自检: %s（%d 项失败）\n", bad == 0 ? "全部通过" : "有失败", bad);
    return bad == 0 ? 0 : 1;
}

static int cmd_selftest(const char *path) {
    Vectors v;
    if (!load_vectors(path, v)) return 1;

    // 1) 主机精确实现
    size_t ok_h = 0, bad_h = 0;
    for (size_t i = 0; i < v.n; i++) {
        uint8_t out[64];
        qpow_host::hash_squeeze_twice(v.in.data() + i * 96, out);
        std::string got = bytes_to_hex(out, 64);
        if (got == v.want[i]) ok_h++;
        else {
            bad_h++;
            if (bad_h <= 3) printf("HOST MISMATCH #%zu\n  got  %s\n  want %s\n", i, got.c_str(), v.want[i].c_str());
        }
    }
    printf("主机精确实现: %zu 通过, %zu 失败\n", ok_h, bad_h);

    // 2) GPU 惰性实现
    std::vector<uint8_t> h_out(v.n * 64);
    uint8_t *d_in = nullptr, *d_out = nullptr;
    CUDA_CHECK(cudaMalloc(&d_in, v.in.size()));
    CUDA_CHECK(cudaMalloc(&d_out, h_out.size()));
    CUDA_CHECK(cudaMemcpy(d_in, v.in.data(), v.in.size(), cudaMemcpyHostToDevice));
    uint32_t threads = 128, blocks = (uint32_t)((v.n + threads - 1) / threads);
    hash_batch_kernel<<<blocks, threads>>>(d_in, d_out, (uint32_t)v.n);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaMemcpy(h_out.data(), d_out, h_out.size(), cudaMemcpyDeviceToHost));
    cudaFree(d_in);
    cudaFree(d_out);

    size_t ok_g = 0, bad_g = 0;
    for (size_t i = 0; i < v.n; i++) {
        std::string got = bytes_to_hex(h_out.data() + i * 64, 64);
        if (got == v.want[i]) ok_g++;
        else {
            bad_g++;
            if (bad_g <= 3) printf("GPU MISMATCH #%zu\n  got  %s\n  want %s\n", i, got.c_str(), v.want[i].c_str());
        }
    }
    printf("GPU 惰性实现: %zu 通过, %zu 失败（惰性归约的预期误差率 ~3e-7/哈希，38 组里出现即视为 bug）\n", ok_g, bad_g);
    return (bad_h == 0 && bad_g == 0) ? 0 : 1;
}

static int cmd_pstest(const char *path) {
    Vectors v;
    if (!load_vectors(path, v)) return 1;

    std::vector<u64> pre(v.n * WIDTH), idx(v.n);
    std::vector<uint8_t> want32(v.n * 32);
    size_t bad_decomp = 0;
    for (size_t i = 0; i < v.n; i++) {
        const uint8_t *in = v.in.data() + i * 96;
        uint8_t full[64], via_pre[64];
        qpow_host::hash_squeeze_twice(in, full);
        memcpy(want32.data() + i * 32, full, 32);
        // nonce[56:64] 大端 → idx
        u64 x = 0;
        for (int b = 0; b < 8; b++) x = (x << 8) | in[32 + 56 + b];
        idx[i] = x;
        qpow_host::prestate_from_input(in, in + 32, pre.data() + i * WIDTH);
        qpow_host::hash_from_prestate(pre.data() + i * WIDTH, x, via_pre);
        if (memcmp(full, via_pre, 64) != 0) {
            bad_decomp++;
            if (bad_decomp <= 3)
                printf("DECOMP MISMATCH #%zu\n  full %s\n  pre  %s\n", i,
                       bytes_to_hex(full, 64).c_str(), bytes_to_hex(via_pre, 64).c_str());
        }
    }
    printf("prestate 分解（主机精确）: %zu 组, %zu 不一致\n", v.n, bad_decomp);

    u64 *d_pre = nullptr, *d_idx = nullptr;
    uint8_t *d_out = nullptr;
    std::vector<uint8_t> got32(v.n * 32);
    CUDA_CHECK(cudaMalloc(&d_pre, pre.size() * sizeof(u64)));
    CUDA_CHECK(cudaMalloc(&d_idx, idx.size() * sizeof(u64)));
    CUDA_CHECK(cudaMalloc(&d_out, got32.size()));
    CUDA_CHECK(cudaMemcpy(d_pre, pre.data(), pre.size() * sizeof(u64), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_idx, idx.data(), idx.size() * sizeof(u64), cudaMemcpyHostToDevice));
    uint32_t threads = 128, blocks = (uint32_t)((v.n + threads - 1) / threads);
    prestate_batch_kernel<<<blocks, threads>>>(d_pre, d_idx, d_out, (uint32_t)v.n);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaMemcpy(got32.data(), d_out, got32.size(), cudaMemcpyDeviceToHost));
    cudaFree(d_pre); cudaFree(d_idx); cudaFree(d_out);

    size_t bad_gpu = 0;
    for (size_t i = 0; i < v.n; i++) {
        if (memcmp(got32.data() + i * 32, want32.data() + i * 32, 32) != 0) {
            bad_gpu++;
            if (bad_gpu <= 3)
                printf("GPU PRESTATE MISMATCH #%zu\n  got  %s\n  want %s\n", i,
                       bytes_to_hex(got32.data() + i * 32, 32).c_str(),
                       bytes_to_hex(want32.data() + i * 32, 32).c_str());
        }
    }
    printf("GPU 挖矿路径 vs 主机精确前 32 字节: %zu 组, %zu 不一致\n", v.n, bad_gpu);
    return (bad_decomp == 0 && bad_gpu == 0) ? 0 : 1;
}

// 与 miner.cu 完全相同的内核与启动形态；目标设为 0，几乎不可能命中，测的就是纯哈希吞吐。
static int cmd_bench(double seconds, uint32_t nonces_per_thread, uint32_t blocks) {
    const uint32_t block_size = 256;
    uint8_t header[32], nonce56[56];
    for (int k = 0; k < 32; k++) header[k] = (uint8_t)(k * 3 + 1);
    for (int k = 0; k < 56; k++) nonce56[k] = (uint8_t)(k * 7 + 5);

    MiningParams params{};
    qpow_host::prestate_from_input(header, nonce56, params.prestate);
    for (int k = 0; k < 8; k++) params.target_hi[k] = 0;
    params.total_threads = blocks * block_size;
    params.nonces_per_thread = nonces_per_thread;
    params.idx_base = 0;

    u32 *d_res = nullptr;
    CUDA_CHECK(cudaMalloc(&d_res, (1 + MAX_HITS) * sizeof(u32)));
    CUDA_CHECK(cudaMemset(d_res, 0, (1 + MAX_HITS) * sizeof(u32)));
    const uint64_t per_launch = (uint64_t)params.total_threads * nonces_per_thread;
    printf("bench: %u 块 × %u 线程 × %u nonce/线程 = %.3g nonce/launch\n",
           blocks, block_size, nonces_per_thread, (double)per_launch);

    mine_kernel<<<blocks, block_size>>>(d_res, params);   // 预热
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    auto t0 = std::chrono::steady_clock::now();
    uint64_t total = 0;
    // 每轮同步：不同步的话主机会把上千次 launch 排进队列，8 秒的时间窗变成 40 多秒
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < seconds) {
        params.idx_base += per_launch;
        mine_kernel<<<blocks, block_size>>>(d_res, params);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());
        total += per_launch;
    }
    CUDA_CHECK(cudaDeviceSynchronize());
    double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    u32 hits = 0;
    CUDA_CHECK(cudaMemcpy(&hits, d_res, sizeof(hits), cudaMemcpyDeviceToHost));
    printf("%.2f s 内 %llu 次哈希 -> %.2f MH/s  (hits=%u)\n", el, (unsigned long long)total,
           (double)total / el / 1e6, hits);
    printf("share 难度 18253611008 -> 期望 %.1f 秒/share\n", 18253611008.0 / ((double)total / el));
    cudaFree(d_res);
    return 0;
}

static void usage() {
    printf("usage:\n");
    printf("  kanq-test fieldtest\n");
    printf("  kanq-test selftest vectors.txt\n");
    printf("  kanq-test pstest   vectors.txt\n");
    printf("  kanq-test bench    [seconds=8] [nonces_per_thread=32] [blocks=4096]\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 1; }
    cudaDeviceProp prop{};
    CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
    printf("GPU: %s  sm_%d%d  %zu MB  SMs=%d\n", prop.name, prop.major, prop.minor,
           prop.totalGlobalMem >> 20, prop.multiProcessorCount);

    std::string cmd = argv[1];
    if (cmd == "fieldtest") return cmd_fieldtest();
    if (cmd == "selftest") { if (argc < 3) { usage(); return 1; } return cmd_selftest(argv[2]); }
    if (cmd == "pstest") { if (argc < 3) { usage(); return 1; } return cmd_pstest(argv[2]); }
    if (cmd == "bench") {
        double s = argc > 2 ? atof(argv[2]) : 8.0;
        uint32_t npt = argc > 3 ? (uint32_t)strtoul(argv[3], nullptr, 10) : 16;
        uint32_t blocks = argc > 4 ? (uint32_t)strtoul(argv[4], nullptr, 10) : 4096;
        return cmd_bench(s, npt, blocks);
    }
    usage();
    return 1;
}
