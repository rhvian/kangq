// goldilocks32.cuh —— Goldilocks 64×64→128 模乘的 32-limb 形态（KanQ P0）
//
// 动机（PEAKMINER_RE_REPORT.md §5.6-1）：现版 gf_mul = u64 乘法 + __umul64hi + reduce128，
// 后者含 IMAD.HI（FMA 管线 ¼ 速）。本形态全部乘法 = 4 个 (u64)u32*u32 → IMAD.WIDE（½ 速），
// 折叠用纯 IADD3 进/借位链（ALU 满速），SASS 断言零 IMAD.HI（tools/sass_check.sh）。
//
// 数学（research/goldilocks32_check.py 已对拍 20 万随机 + 边界，exact/lazy 全绿）：
//   p = 2^64-2^32+1, EPS = 2^32-1, 2^64 ≡ EPS (mod p)
//   a·b = pp3·2^64 + (pp1+pp2)·2^32 + pp0   （pp = 32×32 全宽部分积）
//   r ≡ (r1:r0) + r2·EPS − r3               （2^64 权重折叠；r3 减在低位！）
//   X = r0 − r2 − r3 ∈ (−2^33, 2^32)  → o0 = X mod 2^32，借位 x_hi = floor(X/2^32) ∈ {−2,−1,0}
//   Y = r1 + r2 + x_hi ∈ (−2, 2^33)   → o1 = Y mod 2^32，y_hi = floor(Y/2^32) ∈ {−1,0,1}
//   y_hi·2^64 ≡ y_hi·EPS 折回：o1 += y_hi，o0 −= y_hi
// 惰性语义与旧 reduce128 同级：只跳过折回链自身的顶层回绕（每次乘法 ~2^-33），
// 主机复核（qpow_host.h）不变。
#pragma once

#include <cstdint>

namespace qpow {

using u32 = uint32_t;
using u64 = uint64_t;
using i64 = int64_t;

// 128 位 limbs 组装 + Goldilocks 折叠（惰性）。r0..r3 为 a·b 的 32-bit limbs。
//
// 与旧 reduce128 同构的 6 条 CC 链，仅把 mad.lo/madc.hi(r2·EPS) 换成加法视角：
//   r2·EPS = (r2−1)·2^32 + (2^32−r2)   （r2 ≥ 1；r2=0 时 hi 公式给 −1，
//   误差 ~2^32、概率 2^-32 —— 与本函数其余惰性跳过项同级，host 复核兜底）
// 语义注记：源级逐条模拟此链会发现 ±2^32 级偏差（goldilocks32_ptx_sim.py 实测），
// 但 ptxas 会把 CC 链重排为等价进位网络 —— 旧 reduce128 同源同构，GPU 实测误差率
// ~2^-33/乘法（selftest/pstest 38/38 + 真池）。**此函数的验证只能以 GPU 三道门为准**。
__device__ __forceinline__ u64 fold128_lazy32(u32 r0, u32 r1, u32 r2, u32 r3) {
    long long X = (long long)r0 - (long long)r2 - (long long)r3;
    long long Y = (long long)r1 + (long long)r2 + (X >> 32);
    long long y_hi = Y >> 32;
    u32 o1 = (u32)(Y + y_hi);
    u32 o0 = (u32)(X - y_hi);
    return ((u64)o1 << 32) | o0;
}

// 64×64 → 128 limbs：4 个全宽部分积 + IADD3 组装链。
__device__ __forceinline__ void mul64wide32(u64 a, u64 b,
                                            u32 &r0, u32 &r1, u32 &r2, u32 &r3) {
    u32 a0 = (u32)a, a1 = (u32)(a >> 32);
    u32 b0 = (u32)b, b1 = (u32)(b >> 32);
    u64 pp0 = (u64)a0 * b0;                   // 每条 = 1× IMAD.WIDE.U32（无 IMAD.HI）
    u64 pp1 = (u64)a0 * b1;
    u64 pp2 = (u64)a1 * b0;
    u64 pp3 = (u64)a1 * b1;
    r0 = (u32)pp0;
    u64 t1 = (pp0 >> 32) + (u64)(u32)pp1 + (u64)(u32)pp2;   // 33 位，编译为 IADD3(+.X)
    r1 = (u32)t1;
    u64 t2 = (t1 >> 32) + (pp1 >> 32) + (pp2 >> 32) + (u64)(u32)pp3;
    r2 = (u32)t2;
    r3 = (u32)(t2 >> 32) + (u32)(pp3 >> 32);
}

__device__ __forceinline__ u64 gf_mul32(u64 a, u64 b) {
    u32 r0, r1, r2, r3;
    mul64wide32(a, b, r0, r1, r2, r3);
    return fold128_lazy32(r0, r1, r2, r3);
}

// 平方：3 个全宽部分积（ll, lh×2, hh）+ 组装 + 同一折叠。
__device__ __forceinline__ u64 gf_sqr32(u64 a) {
    u32 a0 = (u32)a, a1 = (u32)(a >> 32);
    u64 ll = (u64)a0 * a0;
    u64 lh = (u64)a0 * a1;                    // 出现两次 → mid = lh<<1
    u64 hh = (u64)a1 * a1;
    u64 mid = lh << 1;
    u32 mid_top = (u32)(lh >> 63);            // 移位溢出的 1 位
    u32 r0 = (u32)ll;
    u64 t1 = (ll >> 32) + (u64)(u32)mid;      // 33 位
    u32 r1 = (u32)t1;
    u64 t2 = (t1 >> 32) + (mid >> 32) + (u64)(u32)hh;   // 2^64..96 段
    u32 r2 = (u32)t2;
    u32 r3 = (u32)(t2 >> 32) + (u32)(hh >> 32) + mid_top; // mid_top 属 2^96 段（2*lh*2^32 的 bit96）
    return fold128_lazy32(r0, r1, r2, r3);
}

} // namespace qpow
