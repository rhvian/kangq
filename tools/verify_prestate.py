"""prestate 分解的权威对拍（挖矿内核 v2 的数学前提）。

v2 内核把每个 nonce 的哈希拆成两段：
  主机：state = absorb(header) ∘ absorb(nonce[0:32]) ；s[0..5] += felt(nonce[32:56])；
        M_E(state) + INITIAL_RC[0]                                   ← prestate
  GPU： prestate + M_E 对 felt[22]、felt[23] 的稀疏贡献 → 置换剩余部分 → 终止符/ONE → 置换 → 第一段 squeeze

本脚本用 poseidon2_ref（已与官方向量对拍）逐组验证：这条拆分路径与 hash_squeeze_twice 前 32 字节完全一致。
覆盖 vectors.txt 全部 38 组 + 200 组随机输入。

用法：python verify_prestate.py
"""

from __future__ import annotations

import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import poseidon2_ref as R  # noqa: E402

P = R.P
VEC = HERE.parent / "vectors.txt"


def le32(b: bytes, off: int) -> int:
    return int.from_bytes(b[off:off + 4], "little")


def bswap32(x: int) -> int:
    return int.from_bytes((x & 0xFFFFFFFF).to_bytes(4, "big"), "little")


def permute_after_initial(s: list[int]) -> None:
    """置换里"初始线性层 + 第 0 轮常量"之后的全部，与 qpow.cuh / qpow_host.h 同结构。"""
    for r in range(4):
        for i in range(12):
            s[i] = pow(s[i], 7, P)
        R._external_linear(s)
        if r + 1 < 4:
            for i in range(12):
                s[i] = (s[i] + R.C["init"][r + 1][i]) % P
    for k in range(22):
        s[0] = pow((s[0] + R.C["internal"][k]) % P, 7, P)
        R._internal_linear(s)
    for rc in R.C["term"]:
        for i in range(12):
            s[i] = pow((s[i] + rc[i]) % P, 7, P)
        R._external_linear(s)


def prestate(header: bytes, nonce56: bytes) -> list[int]:
    s = [0] * 12
    for i in range(8):
        s[i] = (s[i] + le32(header, 4 * i)) % P
    R.permute(s)
    for i in range(8):
        s[i] = (s[i] + le32(nonce56, 4 * i)) % P
    R.permute(s)
    for i in range(6):
        s[i] = (s[i] + le32(nonce56, 32 + 4 * i)) % P
    R._external_linear(s)
    for i in range(12):
        s[i] = (s[i] + R.C["init"][0][i]) % P
    return s


def first32_from_prestate(pre: list[int], idx: int) -> bytes:
    s = list(pre)
    x6 = bswap32(idx >> 32)
    x7 = bswap32(idx & 0xFFFFFFFF)
    c = [x6 + x7, 3 * x6 + x7, 2 * x6 + 3 * x7, x6 + 2 * x7]
    for i in range(4):
        s[i] = (s[i] + c[i]) % P
        s[4 + i] = (s[4 + i] + 2 * c[i]) % P
        s[8 + i] = (s[8 + i] + c[i]) % P
    permute_after_initial(s)
    s[0] = (s[0] + 1) % P
    s[1] = (s[1] + 1) % P
    R.permute(s)
    return b"".join(v.to_bytes(8, "little") for v in s[:4])


def check(header: bytes, nonce: bytes) -> bool:
    want = R.hash_squeeze_twice(header + nonce)[:32]
    idx = int.from_bytes(nonce[56:64], "big")
    got = first32_from_prestate(prestate(header, nonce[:56]), idx)
    return got == want


def main() -> int:
    bad = 0
    n = 0
    for line in VEC.read_text().splitlines():
        h, nn, _ = line.split()
        n += 1
        if not check(bytes.fromhex(h), bytes.fromhex(nn)):
            bad += 1
            print(f"MISMATCH vectors.txt #{n}")
    print(f"vectors.txt: {n} 组, {bad} 不一致")
    rng = random.Random(20260918)
    bad_r = 0
    for k in range(200):
        header = rng.randbytes(32)
        nonce = rng.randbytes(64)
        if k % 4 == 0:  # 覆盖 idx 的进位边界
            nonce = nonce[:56] + bytes([0xFF] * 8)
        if not check(header, nonce):
            bad_r += 1
    print(f"随机: 200 组, {bad_r} 不一致")
    ok = bad == 0 and bad_r == 0
    print("RESULT:", "OK" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
