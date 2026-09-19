// Quantus QPoW (Poseidon2 over Goldilocks) —— 设备端实现（与官方 kernels/mining.cu 同构）。
//
// 正确性锚点：tools/poseidon2_ref.py（与官方 NONCE_HASH_KVS 对拍 10/10）。
// 主机侧精确实现见 qpow_host.h；GPU 只负责找候选，**每个候选都由主机精确复核**。
//
// 与朴素实现相比的三处结构性取舍（朴素版实测 ~100 MH/s，本实现 4090 上 ~920 MH/s）：
//   1. 惰性归约：域元素保持在 [0, 2^64) 而非规范的 [0, p)。加法只做一次 2^64→EPS 折叠，
//      乘法归约 6 条 PTX 指令；两处极罕见的回绕（各约 2^-33/次）故意不修正，结果偏差 ±EPS，
//      该 nonce 的哈希就是错的——所以主机必须复核。这与官方内核是同一个取舍。
//   2. 线性层在 96 位宽累加器（Wide）里累加，每个元素只归约一次；朴素版每次 gf_add 都
//      完整归约 + 规范化（≈10 条指令），一次 permute 里有上千次。
//   3. 轮循环只小幅展开（见 QPOW_UNROLL）。整个 hash 直线展开是 24.8k 条 SASS ≈ 387 KB，超出指令缓存后
//      每个 warp 各自取指：nonce 循环里 warp 一漂移就 −12%（3090 实测，docs/PERFORMANCE.md §2.6）；
//      用 QPOW_LOCKSTEP 拉齐也只能回到持平（+0.7%），省下的 9% 指令被取指延迟吃掉。
//
// 挖矿路径的 nonce 布局约定（与 miner.cu / qpow_host.h 一致）：
//   nonce[0:56]  在一个 job 内固定（extranonce + salt + 0），连同 header 预计算成 prestate
//   nonce[56:64] = 大端 u64 索引，即 felt[22]、felt[23]，按线性层的稀疏贡献直接注入
// 于是每个 nonce 只剩 2 次 permute（朴素版是 4 次）。

#pragma once
#include <cstdint>

#include "constants.cuh"
#ifdef QPOW_LIMB32
#include "goldilocks32.cuh"   // P0: 32-limb mul (KANQ_PLAN.md); sass_check asserts zero IMAD.HI
#endif

namespace qpow {

typedef uint32_t u32;
typedef uint64_t u64;   // 与 constants.cuh 的 uint64_t 同型（Linux 上 unsigned long ≠ unsigned long long）

constexpr u64 P = 0xFFFFFFFF00000001ULL;
constexpr u64 EPS = 0xFFFFFFFFULL;        // 2^32 - 1 = 2^64 mod p
constexpr u32 EPS32 = 0xFFFFFFFFu;

constexpr int WIDTH = 12;
constexpr int RATE = 8;
constexpr int MAX_HITS = 8;

// ---------------------------------------------------------------------------
// Goldilocks 域运算（惰性：输入输出都在 [0, 2^64)）
// ---------------------------------------------------------------------------

// a + b，2^64 进位折成 EPS。折叠本身再进位只在两个输入都贴近 2^64 时发生，不修正。
__device__ __forceinline__ u64 gf_add(u64 a, u64 b) {
    u32 a0 = (u32)a, a1 = (u32)(a >> 32), b0 = (u32)b, b1 = (u32)(b >> 32);
    u32 o0, o1;
    asm("{\n\t"
        ".reg .u32 c;\n\t"
        "add.cc.u32 %0, %2, %4;\n\t"
        "addc.cc.u32 %1, %3, %5;\n\t"
        "addc.u32 c, 0, 0;\n\t"
        "mad.lo.cc.u32 %0, c, %6, %0;\n\t"
        "madc.hi.u32 %1, c, %6, %1;\n\t"
        "}"
        : "=&r"(o0), "=&r"(o1)
        : "r"(a0), "r"(a1), "r"(b0), "r"(b1), "r"(EPS32));
    return ((u64)o1 << 32) | (u64)o0;
}

__device__ __forceinline__ void mul64wide(u64 a, u64 b, u32 &r0, u32 &r1, u32 &r2, u32 &r3) {
    u64 lo = a * b;
    u64 hi = __umul64hi(a, b);
    r0 = (u32)lo;
    r1 = (u32)(lo >> 32);
    r2 = (u32)hi;
    r3 = (u32)(hi >> 32);
}

// 128 → 64 位折叠：2^64 ≡ EPS，2^96 ≡ -1 (mod p)，故
//   x ≡ (r1:r0) + r2*EPS + c*2^32 - (r3 + c)，c 为 64 位加法的进位（c*2^64 ≡ c*2^32 - c）。
// 最后的借位与 o1 的回绕不修正（各约 2^-33），见文件头。
__device__ __forceinline__ u64 reduce128(u32 r0, u32 r1, u32 r2, u32 r3) {
    u32 o0, o1;
    asm("{\n\t"
        ".reg .u32 c;\n\t"
        "mad.lo.cc.u32 %0, %4, %6, %2;\n\t"
        "madc.hi.cc.u32 %1, %4, %6, %3;\n\t"
        "addc.u32 c, %5, 0;\n\t"
        "addc.u32 %1, %1, 0;\n\t"
        "sub.cc.u32 %0, %0, c;\n\t"
        "subc.u32 %1, %1, 0;\n\t"
        "}"
        : "=&r"(o0), "=&r"(o1)
        : "r"(r0), "r"(r1), "r"(r2), "r"(r3), "r"(EPS32));
    return ((u64)o1 << 32) | (u64)o0;
}

__device__ __forceinline__ u64 gf_mul(u64 a, u64 b) {
#ifdef QPOW_LIMB32
    return gf_mul32(a, b);
#else
    u32 r0, r1, r2, r3;
    mul64wide(a, b, r0, r1, r2, r3);
    return reduce128(r0, r1, r2, r3);
#endif
}

// 平方只要 3 个 32 位部分积：(a1:a0)^2 = a0^2 + 2*a0*a1*2^32 + a1^2*2^64
#ifdef QPOW_LIMB32
__device__ __forceinline__ u64 gf_sqr(u64 a) {
    return gf_sqr32(a);
}
#else
__device__ __forceinline__ u64 gf_sqr(u64 a) {
    u32 a0 = (u32)a, a1 = (u32)(a >> 32);
    u64 ll = (u64)a0 * a0;
    u64 lh = (u64)a0 * a1;
    u64 hh = (u64)a1 * a1;
    u64 mid = lh << 1;
    u32 mid_top = (u32)(lh >> 63);
    u32 r0 = (u32)ll, r1, r2, r3;
    asm("{\n\t"
        "add.cc.u32 %0, %3, %4;\n\t"
        "addc.cc.u32 %1, %5, %6;\n\t"
        "addc.u32 %2, %7, %8;\n\t"
        "}"
        : "=&r"(r1), "=&r"(r2), "=&r"(r3)
        : "r"((u32)(ll >> 32)), "r"((u32)mid), "r"((u32)hh),
          "r"((u32)(mid >> 32)), "r"((u32)(hh >> 32)), "r"(mid_top));
    return reduce128(r0, r1, r2, r3);
}
#endif

// x^7，深度 3：x3 与 x4 都从 x2 出发可并行
__device__ __forceinline__ u64 gf_sbox(u64 x) {
    u64 x2 = gf_sqr(x);
    u64 x3 = gf_mul(x2, x);
    u64 x4 = gf_sqr(x2);
    return gf_mul(x4, x3);
}

// 规范化到 [0, p)。惰性值最多比 p 大一次（< 2^64 < 2p）。
__device__ __forceinline__ u64 gf_canon(u64 a) {
    return a - ((a >= P) ? P : 0ULL);
}

// 96 位宽累加器：线性层里把最多二十几个 64 位项加在一起，最后只归约一次。
struct Wide {
    u32 l0, l1, h;
};

__device__ __forceinline__ Wide wide_from(u64 x) {
    Wide w;
    w.l0 = (u32)x;
    w.l1 = (u32)(x >> 32);
    w.h = 0;
    return w;
}

__device__ __forceinline__ void wide_add(Wide &w, u64 x) {
    u32 x0 = (u32)x, x1 = (u32)(x >> 32);
    asm("{\n\t"
        "add.cc.u32 %0, %0, %3;\n\t"
        "addc.cc.u32 %1, %1, %4;\n\t"
        "addc.u32 %2, %2, 0;\n\t"
        "}"
        : "+r"(w.l0), "+r"(w.l1), "+r"(w.h)
        : "r"(x0), "r"(x1));
}

__device__ __forceinline__ void wide_add_wide(Wide &w, const Wide &x) {
    asm("{\n\t"
        "add.cc.u32 %0, %0, %3;\n\t"
        "addc.cc.u32 %1, %1, %4;\n\t"
        "addc.u32 %2, %2, %5;\n\t"
        "}"
        : "+r"(w.l0), "+r"(w.l1), "+r"(w.h)
        : "r"(x.l0), "r"(x.l1), "r"(x.h));
}

__device__ __forceinline__ u64 wide_reduce(const Wide &w) {
#ifdef QPOW_LIMB32
    return fold128_lazy32(w.l0, w.l1, w.h, 0u);
#else
    return reduce128(w.l0, w.l1, w.h, 0u);
#endif
}

__device__ __forceinline__ void add128_wide(u32 &r0, u32 &r1, u32 &r2, u32 &r3, const Wide &w) {
    asm("{\n\t"
        "add.cc.u32 %0, %0, %4;\n\t"
        "addc.cc.u32 %1, %1, %5;\n\t"
        "addc.cc.u32 %2, %2, %6;\n\t"
        "addc.u32 %3, %3, 0;\n\t"
        "}"
        : "+r"(r0), "+r"(r1), "+r"(r2), "+r"(r3)
        : "r"(w.l0), "r"(w.l1), "r"(w.h));
}

// ---------------------------------------------------------------------------
// 置换
// ---------------------------------------------------------------------------

// 外部线性层 M_E = circ(2*M4, M4, M4)，M4 = [[2,3,1,1],[1,2,3,1],[1,1,2,3],[3,1,1,2]]，
// 顺带把**下一轮**的轮常量 rc12 加进去（这样每个元素恰好只归约一次）。
__device__ __forceinline__ void ext_layer(u64 *state, const u64 *rc12) {
    Wide y[12];
#pragma unroll
    for (int chunk = 0; chunk < 3; chunk++) {
        int o = chunk * 4;
        u64 x0 = state[o], x1 = state[o + 1], x2 = state[o + 2], x3 = state[o + 3];
        Wide t01 = wide_from(x0);
        wide_add(t01, x1);
        Wide t23 = wide_from(x2);
        wide_add(t23, x3);
        Wide t0123 = t01;
        wide_add_wide(t0123, t23);
        Wide t01123 = t0123;
        wide_add(t01123, x1);
        Wide t01233 = t0123;
        wide_add(t01233, x3);
        y[o + 3] = t01233;
        wide_add(y[o + 3], x0);
        wide_add(y[o + 3], x0);
        y[o + 1] = t01123;
        wide_add(y[o + 1], x2);
        wide_add(y[o + 1], x2);
        y[o] = t01123;
        wide_add_wide(y[o], t01);
        y[o + 2] = t01233;
        wide_add_wide(y[o + 2], t23);
    }
    Wide sums[4];
#pragma unroll
    for (int k = 0; k < 4; k++) {
        sums[k] = y[k];
        wide_add_wide(sums[k], y[k + 4]);
        wide_add_wide(sums[k], y[k + 8]);
    }
#pragma unroll
    for (int i = 0; i < 12; i++) {
        Wide w = y[i];
        wide_add_wide(w, sums[i % 4]);
        wide_add(w, rc12[i]);
        state[i] = wide_reduce(w);
    }
}

// 内部轮（软件流水）：x 是本轮已过 S-box 的元素 0；先把 1..11 求和，元素 0 的输出最先算出
// 以便调用方立刻开始下一轮 S-box。行和（96 位，未归约）直接骑在乘法累加器上。
// 返回新的元素 0（已加上下一轮常量 rc0）；更新 state[1..11]。
__device__ __forceinline__ u64 int_round_p(u64 *state, u64 x, u64 rc0) {
    // 12 个 64 位值求和：lo32 / hi32 各自在 64 位里累加（都 < 2^36），没有跨值的进位依赖，
    // ptxas 可用 3 输入 IADD3 树形折叠；原来的 add.cc/addc 链是 33 条严格串行指令。
    // 单独收益不可测（docs/PERFORMANCE.md 实验 B），但让展开后的寄存器分配少溢出。
    u64 lo = (u32)state[1], hi = state[1] >> 32;
#pragma unroll
    for (int i = 2; i < 12; i++) { lo += (u32)state[i]; hi += state[i] >> 32; }
    lo += (u32)x; hi += x >> 32;
    u64 mid = (lo >> 32) + (u32)hi;          // < 2^37
    Wide s;
    s.l0 = (u32)lo;
    s.l1 = (u32)mid;
    s.h  = (u32)((mid >> 32) + (hi >> 32));
    Wide s0 = s;
    wide_add(s0, rc0);
    u32 r0, r1, r2, r3;
#ifdef QPOW_LIMB32
    mul64wide32(x, MATRIX_DIAG[0], r0, r1, r2, r3);
#else
    mul64wide(x, MATRIX_DIAG[0], r0, r1, r2, r3);
#endif
    add128_wide(r0, r1, r2, r3, s0);
#ifdef QPOW_LIMB32
    u64 out0 = fold128_lazy32(r0, r1, r2, r3);
#else
    u64 out0 = reduce128(r0, r1, r2, r3);
#endif
#pragma unroll
    for (int i = 1; i < 12; i++) {
#ifdef QPOW_LIMB32
        mul64wide32(state[i], MATRIX_DIAG[i], r0, r1, r2, r3);
#else
        mul64wide(state[i], MATRIX_DIAG[i], r0, r1, r2, r3);
#endif
        add128_wide(r0, r1, r2, r3, s);
#ifdef QPOW_LIMB32
        state[i] = fold128_lazy32(r0, r1, r2, r3);
#else
        state[i] = reduce128(r0, r1, r2, r3);
#endif
    }
    return out0;
}

// 轮循环展开档位（P1 直线展开实验，2026-09-20，3090 数据见 docs/PERFORMANCE.md §2.6）：
//   0  小幅展开（全轮 ×2、部分轮 ×3、末段 ×1），1.2 基线，mine_kernel 4.1k 条 SASS ≈ 64 KB  —— 默认
//   1  单次 permute 全直线（两次 permute 的 pass 循环保留），12.7k 条 ≈ 199 KB
//   2  整个 hash 全直线（pass 循环也展开），24.8k 条 ≈ 387 KB —— PeakMiner 的形态（17.7k 条 / 283 KB）
// 1/2 档指令数比 0 档少 ~9%，但超出指令缓存：warp 在 nonce 循环里漂移后各自取指，npt=16 时 −7% / −12%；
// 必须配合 QPOW_LOCKSTEP 才回到持平（+0.7%，低于采用门槛），所以默认仍是 0。
// 任一档都要配合 QPOW_MIN_BLOCKS=1 放开寄存器（压到 80 寄存器就溢出，直线档掉 −11%）。
#ifndef QPOW_UNROLL
#define QPOW_UNROLL 0
#endif
#if QPOW_UNROLL >= 1
#define QPOW_UNROLL_FULL_ROUNDS _Pragma("unroll")
#define QPOW_UNROLL_PARTIAL_ROUNDS _Pragma("unroll")
#define QPOW_UNROLL_TERMINAL_ROUNDS _Pragma("unroll")
#else
#define QPOW_UNROLL_FULL_ROUNDS _Pragma("unroll 2")
#define QPOW_UNROLL_PARTIAL_ROUNDS _Pragma("unroll 3")
#define QPOW_UNROLL_TERMINAL_ROUNDS _Pragma("unroll 1")
#endif
#if QPOW_UNROLL >= 2
#define QPOW_UNROLL_PASSES _Pragma("unroll")
#else
#define QPOW_UNROLL_PASSES _Pragma("unroll 1")
#endif

// 除去开头那次外部线性层的完整置换。要求 state 已经加过 RC_INITIAL_EXT[0]。
__device__ __forceinline__ void permute_after_initial(u64 *state) {
    QPOW_UNROLL_FULL_ROUNDS
    for (int r = 0; r < 4; r++) {
#pragma unroll
        for (int i = 0; i < 12; i++) state[i] = gf_sbox(state[i]);
        ext_layer(state, RC_INITIAL_EXT[r + 1]);
    }
    u64 x = gf_sbox(state[0]);
    QPOW_UNROLL_PARTIAL_ROUNDS
    for (int r = 0; r < 21; r++) {
        x = gf_sbox(int_round_p(state, x, RC_INTERNAL_EXT[r + 1]));
    }
    state[0] = int_round_p(state, x, 0ULL);
#pragma unroll
    for (int i = 0; i < 12; i++) state[i] = gf_add(state[i], RC_TERMINAL_EXT[0][i]);
    QPOW_UNROLL_TERMINAL_ROUNDS
    for (int r = 0; r < 4; r++) {
#pragma unroll
        for (int i = 0; i < 12; i++) state[i] = gf_sbox(state[i]);
        ext_layer(state, RC_TERMINAL_EXT[r + 1]);
    }
}

__device__ __forceinline__ void permute(u64 *state) {
    ext_layer(state, RC_INITIAL_EXT[0]);
    permute_after_initial(state);
}

// 挖矿专用：从 prestate（已做过第 3 次置换的初始线性层）出发，跑完第 3 次置换，
// 加终止符与 push-ONE，再跑完整的第 4 次置换。之后 state[0..3] 就是第一段 squeeze。
__device__ __forceinline__ void permute_twice_after_initial(u64 *state) {
    QPOW_UNROLL_PASSES
    for (int pass = 0; pass < 2; pass++) {
        if (pass != 0) ext_layer(state, RC_INITIAL_EXT[0]);
        permute_after_initial(state);
        if (pass == 0) {
            state[0] = gf_add(state[0], 1ULL);   // 终止符 0x01（felt[24]）
            state[1] = gf_add(state[1], 1ULL);   // finalize 的 push ONE
        }
    }
}

// ---------------------------------------------------------------------------
// 通用海绵（自检用）：96 字节输入 → 64 字节摘要，与 poseidon2_ref.hash_squeeze_twice 同语义
// ---------------------------------------------------------------------------

__device__ __forceinline__ u32 load_le32(const uint8_t *p) {
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

__device__ __forceinline__ void store_digest32(const u64 *state, uint8_t *out32) {
#pragma unroll
    for (int i = 0; i < 4; i++) {
        u64 v = gf_canon(state[i]);
#pragma unroll
        for (int b = 0; b < 8; b++) out32[i * 8 + b] = (uint8_t)(v >> (8 * b));
    }
}

__device__ __forceinline__ void hash_squeeze_twice(const uint8_t *data, uint8_t *out64) {
    u64 s[WIDTH];
#pragma unroll
    for (int i = 0; i < WIDTH; i++) s[i] = 0;
#pragma unroll 1
    for (int blk = 0; blk < 3; blk++) {
#pragma unroll
        for (int i = 0; i < RATE; i++) s[i] = gf_add(s[i], (u64)load_le32(data + (blk * RATE + i) * 4));
        permute(s);
    }
    s[0] = gf_add(s[0], 1ULL);
    s[1] = gf_add(s[1], 1ULL);
    permute(s);
    store_digest32(s, out64);
    permute(s);
    store_digest32(s, out64 + 32);
}

// ---------------------------------------------------------------------------
// 挖矿路径
// ---------------------------------------------------------------------------

__device__ __forceinline__ u32 bswap32(u32 v) {
    return __byte_perm(v, 0, 0x0123);
}

// 一个 nonce 的第一段 squeeze（4 个规范化 felt）。
//   pre      主机算好的 prestate（见 qpow_host.h::prestate_from_input）
//   idx      nonce 低 64 位（nonce[56:64] 的大端值）
// felt[22] = LE32(nonce[56:60]) = bswap32(hi32(idx))，felt[23] = bswap32(lo32(idx))；
// 它们经外部线性层 M_E 的贡献是稀疏的固定线性组合，直接加到 prestate 上。
__device__ __forceinline__ void first_squeeze_from_prestate(const u64 *pre, u64 idx, u64 *out4) {
    u64 st[WIDTH];
#pragma unroll
    for (int i = 0; i < WIDTH; i++) st[i] = pre[i];
    u64 x6 = (u64)bswap32((u32)(idx >> 32));
    u64 x7 = (u64)bswap32((u32)idx);
    u64 x6_2 = x6 + x6, x6_3 = x6_2 + x6, x6_4 = x6_2 + x6_2, x6_6 = x6_3 + x6_3;
    u64 x7_2 = x7 + x7, x7_3 = x7_2 + x7, x7_4 = x7_2 + x7_2, x7_6 = x7_3 + x7_3;
    u64 c0 = x6 + x7, c1 = x6_3 + x7, c2 = x6_2 + x7_3, c3 = x6 + x7_2;
    st[0] = gf_add(st[0], c0);
    st[1] = gf_add(st[1], c1);
    st[2] = gf_add(st[2], c2);
    st[3] = gf_add(st[3], c3);
    st[4] = gf_add(st[4], x6_2 + x7_2);
    st[5] = gf_add(st[5], x6_6 + x7_2);
    st[6] = gf_add(st[6], x6_4 + x7_6);
    st[7] = gf_add(st[7], x6_2 + x7_4);
    st[8] = gf_add(st[8], c0);
    st[9] = gf_add(st[9], c1);
    st[10] = gf_add(st[10], c2);
    st[11] = gf_add(st[11], c3);
    permute_twice_after_initial(st);
#pragma unroll
    for (int i = 0; i < 4; i++) out4[i] = gf_canon(st[i]);
}

// 第一段 squeeze 是否 <= 目标的高 256 位（大端逐字比较）。
// 摘要字节序：felt i 的 8 字节小端；U512 按大端读，所以 felt0 的最低字节是最高位。
// tgt_hi[k] = 目标前 32 字节里第 k 个 4 字节组的大端值。
// 用 <= 而不是 <：高 256 位相等时结果取决于低 256 位，交给主机精确判定。
__device__ __forceinline__ bool first_squeeze_le_target(const u64 *out4, const u32 *tgt_hi) {
#pragma unroll
    for (int k = 0; k < 8; k++) {
        u64 v = out4[k >> 1];
        u32 h = bswap32((k & 1) ? (u32)(v >> 32) : (u32)v);
        u32 t = tgt_hi[k];
        if (h != t) return h < t;
    }
    return true;
}

// 主机 → 内核的按值参数（落在常量存储区，warp 内广播读取）
struct MiningParams {
    u64 prestate[WIDTH];
    u32 target_hi[8];
    u64 idx_base;          // 本批第一个 nonce 的低 64 位
    u32 total_threads;
    u32 nonces_per_thread;
};

// 每线程连续扫 nonces_per_thread 个 nonce；候选只记录索引，不提前退出，
// 主机对每个候选用精确算法复核（惰性归约会让极少数哈希算错）。
// QPOW_MIN_BLOCKS 决定寄存器上限（1 → 255，实际用 94；4 → 64，官方值）。
// 实测（2026-09-19，4090）：占用率不是杠杆——每调度器 2 个 warp 就饱和，16 与 48 warp/SM 速率相同；
// 放开寄存器 + 小幅展开 885 → ~910 MH/s，其余组合（3/2 块、展开 4/7）都在 895–908 平台上。全部数据见 docs/PERFORMANCE.md。
#ifndef QPOW_MIN_BLOCKS
#define QPOW_MIN_BLOCKS 1
#endif
__global__ void __launch_bounds__(256, QPOW_MIN_BLOCKS) mine_kernel(u32 *results, const MiningParams params) {
    u32 tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= params.total_threads) return;
    u64 mid[WIDTH];
#pragma unroll
    for (int i = 0; i < WIDTH; i++) mid[i] = params.prestate[i];
    u32 tgt[8];
#pragma unroll
    for (int i = 0; i < 8; i++) tgt[i] = params.target_hi[i];
    u32 base = tid * params.nonces_per_thread;
    for (u32 j = 0; j < params.nonces_per_thread; j++) {
#ifdef QPOW_LOCKSTEP
        // 与 QPOW_UNROLL≥1 搭配：每个 nonce 前把块内 8 个 warp 拉齐，让它们同步流过直线代码、共享取指
        // （PeakMiner 靠每线程每 launch 只算 1 个 hash 天然拉齐）。0 档下零成本也零收益。
        // total_threads 总是块大小的整数倍，所以没有线程在前面提前 return。
        __syncthreads();
#endif
        u32 logical = base + j;
        u64 out4[4];
        first_squeeze_from_prestate(mid, params.idx_base + (u64)logical, out4);
        if (!first_squeeze_le_target(out4, tgt)) continue;
        u32 slot = atomicAdd(&results[0], 1u);
        if (slot < (u32)MAX_HITS) results[1 + slot] = logical;
    }
}

} // namespace qpow
