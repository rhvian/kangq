// Quantus QPoW —— 主机侧**精确**实现（Poseidon2/Goldilocks，规范化算术）。
//
// 用途：
//   1. 每个 job 算一次 prestate（喂给 GPU 内核）
//   2. 复核 GPU 找到的每个候选：GPU 用惰性归约，约 3e-7 的 nonce 哈希会算错，
//      提交错误 share 会被矿池拒绝，所以主机必须用精确算法重算摘要并判定
//   3. 自检：与 vectors.txt（官方 NONCE_HASH_KVS + 参考实现随机向量）对拍
//
// 与 tools/poseidon2_ref.py 同语义；轮常量来自 constants.cuh 的 H_* 表（同一生成器）。
// 性能无关紧要（每 job 一次 + 每候选一次），所以全部用 unsigned __int128 取模，不做任何技巧。

#pragma once
#include <cstdint>
#include <cstring>

#include "constants.cuh"

namespace qpow_host {

constexpr uint64_t P = 0xFFFFFFFF00000001ULL;
constexpr int WIDTH = 12;
constexpr int RATE = 8;

inline uint64_t add(uint64_t a, uint64_t b) {
    return (uint64_t)(((unsigned __int128)a + b) % P);
}

inline uint64_t mul(uint64_t a, uint64_t b) {
    return (uint64_t)(((unsigned __int128)a * b) % P);
}

inline uint64_t sbox(uint64_t x) {
    uint64_t x2 = mul(x, x);
    uint64_t x3 = mul(x2, x);
    uint64_t x4 = mul(x2, x2);
    return mul(x3, x4);
}

// M_E = circ(2*M4, M4, M4)，M4 = [[2,3,1,1],[1,2,3,1],[1,1,2,3],[3,1,1,2]]
inline void external_linear_layer(uint64_t *s) {
    for (int c = 0; c < WIDTH / 4; c++) {
        int i = c * 4;
        uint64_t t01 = add(s[i], s[i + 1]);
        uint64_t t23 = add(s[i + 2], s[i + 3]);
        uint64_t t0123 = add(t01, t23);
        uint64_t t01123 = add(t0123, s[i + 1]);
        uint64_t t01233 = add(t0123, s[i + 3]);
        uint64_t s3 = add(t01233, add(s[i], s[i]));
        uint64_t s1 = add(t01123, add(s[i + 2], s[i + 2]));
        uint64_t s0 = add(t01123, t01);
        uint64_t s2 = add(t01233, t23);
        s[i] = s0; s[i + 1] = s1; s[i + 2] = s2; s[i + 3] = s3;
    }
    uint64_t sums[4];
    for (int k = 0; k < 4; k++) sums[k] = add(add(s[k], s[k + 4]), s[k + 8]);
    for (int i = 0; i < WIDTH; i++) s[i] = add(s[i], sums[i % 4]);
}

inline void internal_linear_layer(uint64_t *s) {
    uint64_t total = 0;
    for (int i = 0; i < WIDTH; i++) total = add(total, s[i]);
    for (int i = 0; i < WIDTH; i++) s[i] = add(total, mul(s[i], H_MATRIX_DIAG[i]));
}

// 置换里"初始线性层 + 第 0 轮常量"之后的全部。与设备端 permute_after_initial 对应，
// 输入要求：已做过 external_linear_layer 且已加 H_INITIAL_RC[0]。
inline void permute_after_initial(uint64_t *s) {
    for (int r = 0; r < 4; r++) {
        for (int i = 0; i < WIDTH; i++) s[i] = sbox(s[i]);
        external_linear_layer(s);
        if (r + 1 < 4) {
            for (int i = 0; i < WIDTH; i++) s[i] = add(s[i], H_INITIAL_RC[r + 1][i]);
        }
    }
    for (int r = 0; r < 22; r++) {
        s[0] = sbox(add(s[0], H_INTERNAL_RC[r]));
        internal_linear_layer(s);
    }
    for (int r = 0; r < 4; r++) {
        for (int i = 0; i < WIDTH; i++) s[i] = sbox(add(s[i], H_TERMINAL_RC[r][i]));
        external_linear_layer(s);
    }
}

inline void permute(uint64_t *s) {
    external_linear_layer(s);
    for (int i = 0; i < WIDTH; i++) s[i] = add(s[i], H_INITIAL_RC[0][i]);
    permute_after_initial(s);
}

inline uint32_t load_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

inline void store_digest32(const uint64_t *s, uint8_t *out32) {
    for (int i = 0; i < 4; i++)
        for (int b = 0; b < 8; b++) out32[i * 8 + b] = (uint8_t)(s[i] >> (8 * b));
}

// 96 字节输入（header 32 || nonce 64）→ 64 字节摘要。
// 24 个数据 felt + 1 个终止符 = 25 felt，按 rate 8 分成 3 个满块 + 余数；
// 收尾时 s[0] += 1（终止符）且 s[1] += 1（push ONE）。
inline void hash_squeeze_twice(const uint8_t *in96, uint8_t *out64) {
    uint64_t s[WIDTH] = {0};
    for (int blk = 0; blk < 3; blk++) {
        for (int i = 0; i < RATE; i++) s[i] = add(s[i], load_le32(in96 + (blk * RATE + i) * 4));
        permute(s);
    }
    s[0] = add(s[0], 1);
    s[1] = add(s[1], 1);
    permute(s);
    store_digest32(s, out64);
    permute(s);
    store_digest32(s, out64 + 32);
}

// 挖矿 prestate：吸收 header 块、nonce[0:32] 块（各含置换），再加上 nonce[32:56] 的 6 个 felt，
// 然后把第 3 次置换的初始线性层和第 0 轮常量也做掉。剩下 felt[22]、felt[23]（nonce[56:64]）
// 由 GPU 按线性层的稀疏贡献注入。
inline void prestate_from_input(const uint8_t *header32, const uint8_t *nonce_first56, uint64_t *pre) {
    uint64_t s[WIDTH] = {0};
    for (int i = 0; i < RATE; i++) s[i] = add(s[i], load_le32(header32 + i * 4));
    permute(s);
    for (int i = 0; i < RATE; i++) s[i] = add(s[i], load_le32(nonce_first56 + i * 4));
    permute(s);
    for (int i = 0; i < 6; i++) s[i] = add(s[i], load_le32(nonce_first56 + 32 + i * 4));
    external_linear_layer(s);
    for (int i = 0; i < WIDTH; i++) s[i] = add(s[i], H_INITIAL_RC[0][i]);
    memcpy(pre, s, sizeof(s));
}

// 从 prestate 出发的精确摘要（隔离"prestate 分解错"与"GPU 算术错"用）。
// x6/x7 的稀疏贡献与设备端 first_squeeze_from_prestate 完全一致。
inline void hash_from_prestate(const uint64_t *pre, uint64_t idx, uint8_t *out64) {
    uint64_t s[WIDTH];
    memcpy(s, pre, sizeof(s));
    uint64_t x6 = __builtin_bswap32((uint32_t)(idx >> 32));
    uint64_t x7 = __builtin_bswap32((uint32_t)idx);
    uint64_t c[4] = {x6 + x7, 3 * x6 + x7, 2 * x6 + 3 * x7, x6 + 2 * x7};
    for (int i = 0; i < 4; i++) {
        s[i] = add(s[i], c[i]);
        s[4 + i] = add(s[4 + i], 2 * c[i]);
        s[8 + i] = add(s[8 + i], c[i]);
    }
    permute_after_initial(s);
    s[0] = add(s[0], 1);
    s[1] = add(s[1], 1);
    permute(s);
    store_digest32(s, out64);
    permute(s);
    store_digest32(s, out64 + 32);
}

// target = (2^512 - 1) / difficulty，大端 64 字节
inline void target_full512(unsigned __int128 difficulty, uint8_t *out64) {
    uint64_t limbs[8];
    for (int i = 0; i < 8; i++) limbs[i] = ~0ULL;
    if (difficulty == 0) difficulty = 1;
    unsigned __int128 rem = 0;
    for (int i = 7; i >= 0; i--) {
        unsigned __int128 cur = (rem << 64) | (unsigned __int128)limbs[i];
        limbs[i] = (uint64_t)(cur / difficulty);
        rem = cur % difficulty;
    }
    for (int k = 0; k < 8; k++) {
        uint64_t v = limbs[7 - k];
        for (int b = 0; b < 8; b++) out64[k * 8 + b] = (uint8_t)(v >> (8 * (7 - b)));
    }
}

// 大端字典序 a < b
inline bool lt_be(const uint8_t *a, const uint8_t *b, size_t n) {
    for (size_t i = 0; i < n; i++) if (a[i] != b[i]) return a[i] < b[i];
    return false;
}

// 内核比较用的目标高 256 位：8 个大端 u32
inline void target_hi_words(const uint8_t *target64, uint32_t *w8) {
    for (int k = 0; k < 8; k++)
        w8[k] = ((uint32_t)target64[4 * k] << 24) | ((uint32_t)target64[4 * k + 1] << 16) |
                ((uint32_t)target64[4 * k + 2] << 8) | (uint32_t)target64[4 * k + 3];
}

} // namespace qpow_host
