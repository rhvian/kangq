"""qp-poseidon (Poseidon2/Goldilocks) 独立 Python 参考实现。

动机：qpow-math 的 get_nonce_hash 把 hash_squeeze_twice 的 64 字节按 big-endian
读成 U512 参与难度比较，但 POSEIDON2_OUTPUT=4 且 digest_to_bytes 只序列化
state[..4]，每次 squeeze 只有 32 字节有效输出。必须用独立实现验证第 2 个
squeeze 到底输出了什么，否则难度口径的推断不可信。

常量从 qp-poseidon/src/poseidon2.rs 直接解析，避免手工转录出错。
"""

from __future__ import annotations

import re
from pathlib import Path

P = 0xFFFFFFFF00000001  # Goldilocks: 2^64 - 2^32 + 1
SRC = Path(__file__).resolve().parent / "upstream" / "qp-poseidon__poseidon2.rs"


def _load_consts() -> dict[str, list]:
    """从 Rust 源码解析四组常量，保持声明顺序。"""
    text = SRC.read_text(encoding="utf-8")

    def grab(name: str, stop: str) -> list[list[int]]:
        # 声明里也有一个 `[...; N]` 类型注解，必须从 `=` 之后开始解析。
        seg = text.split(f"pub const {name}:")[1].split("=", 1)[1].split(stop)[0]
        return [[int(h, 16) for h in re.findall(r"0x([0-9a-fA-F]+)", row)]
                for row in re.findall(r"\[([^\[\]]*)\]", seg) if row.strip()]

    return {
        "internal": [int(h, 16) for h in re.findall(
            r"0x([0-9a-fA-F]+)", text.split("pub const INTERNAL_CONSTANTS:")[1].split("];")[0])],
        "diag": [int(h, 16) for h in re.findall(
            r"0x([0-9a-fA-F]+)", text.split("pub const MATRIX_DIAG:")[1].split("];")[0])],
        "init": grab("INITIAL_EXTERNAL_CONSTANTS", "/// Terminal"),
        "term": grab("TERMINAL_EXTERNAL_CONSTANTS", "// ===="),
    }


C = _load_consts()
assert len(C["internal"]) == 22, len(C["internal"])
assert len(C["diag"]) == 12, len(C["diag"])
assert len(C["init"]) == 4 and len(C["init"][0]) == 12, C["init"]
assert len(C["term"]) == 4 and len(C["term"][0]) == 12, C["term"]


def _mat4(x: list[int]) -> list[int]:
    t01 = (x[0] + x[1]) % P
    t23 = (x[2] + x[3]) % P
    t0123 = (t01 + t23) % P
    t01123 = (t0123 + x[1]) % P
    t01233 = (t0123 + x[3]) % P
    # Rust 原地改写 x[3], x[1], x[0], x[2]；这里返回新列表，调用方必须写回切片。
    return [
        (t01123 + t01) % P,              # x[0] = 2x0 + 3x1 + x2 + x3
        (t01123 + 2 * x[2]) % P,         # x[1] = x0 + 2x1 + 3x2 + x3
        (t01233 + t23) % P,              # x[2] = x0 + x1 + 2x2 + 3x3
        (t01233 + 2 * x[0]) % P,         # x[3] = 3x0 + x1 + x2 + 2x3
    ]


def _external_linear(s: list[int]) -> None:
    for i in range(0, 12, 4):
        s[i:i + 4] = _mat4(s[i:i + 4])
    sums = [sum(s[k::4]) % P for k in range(4)]  # state[k], state[k+4], state[k+8]
    for i in range(12):
        s[i] = (s[i] + sums[i % 4]) % P


def _internal_linear(s: list[int]) -> None:
    total = sum(s) % P
    for i in range(12):
        s[i] = (total + s[i] * C["diag"][i]) % P


def permute(s: list[int]) -> list[int]:
    _external_linear(s)
    for rc in C["init"]:
        for i in range(12):
            s[i] = pow((s[i] + rc[i]) % P, 7, P)
        _external_linear(s)
    for k in range(22):
        s[0] = pow((s[0] + C["internal"][k]) % P, 7, P)
        _internal_linear(s)
    for rc in C["term"]:
        for i in range(12):
            s[i] = pow((s[i] + rc[i]) % P, 7, P)
        _external_linear(s)
    return s


def _bytes_to_u64s(data: bytes) -> list[int]:
    """4 字节小端 + 0x01 终止符（qp-poseidon serialization::bytes_to_u64s_iter）。"""
    out, pos = [], 0
    while pos + 4 <= len(data):
        out.append(int.from_bytes(data[pos:pos + 4], "little"))
        pos += 4
    last = bytearray(4)
    rem = data[pos:]
    last[:len(rem)] = rem
    last[len(rem)] = 1
    out.append(int.from_bytes(bytes(last), "little"))
    return out


def _absorb(data: bytes) -> list[int]:
    s = [0] * 12
    buf: list[int] = []
    for felt in _bytes_to_u64s(data):
        buf.append(felt)
        if len(buf) == 8:
            for i in range(8):
                s[i] = (s[i] + buf[i]) % P
            permute(s)
            buf = []
    # finalize_state(): push ONE，然后用 ZERO 填满剩余 rate 槽位，再 permute 一次
    for i, f in enumerate(buf):
        s[i] = (s[i] + f) % P
    for i in range(len(buf), 8):
        s[i] = (s[i] + (1 if i == len(buf) else 0)) % P
    permute(s)
    return s


def _digest_bytes(s: list[int]) -> bytes:
    return b"".join(v.to_bytes(8, "little") for v in s[:4])


def hash_bytes(data: bytes) -> bytes:
    return _digest_bytes(_absorb(data))


def hash_squeeze_twice(data: bytes) -> bytes:
    s = _absorb(data)
    first = _digest_bytes(s)
    permute(s)
    return first + _digest_bytes(s)


def _selftest() -> None:
    """用 qp-poseidon 自己的 Rust 测试向量校验，全绿才可信。"""
    zero_perm = permute([0] * 12)
    expect = [0xc9bc9432e1686884, 0x03ecbab0dcdd2189, 0x5e7ac885b3dc1215,
              0x6ac07513801d191f, 0xca5c593fb184dcfc, 0x414dec5f3e455287,
              0x1a17df170127ae41, 0xe7e592bd0af9b0a5, 0xc71a9b27edc66a4c,
              0x2728671759ac43c2, 0xb9969c20f7f672f9, 0xc5140b586823b92f]
    assert zero_perm == expect, f"permute(zero) mismatch: {[hex(v) for v in zero_perm]}"

    vectors = [
        (bytes(7), "b01975012df91d9f9f040c34655f23f3ec1f6d1738d85679e9848143756637c9"),
        (bytes(8), "eacd9e48d2e968131e48c8e69f2a211cc06c7778db6c5467348b45418fc7f585"),
        (bytes(range(32)), "36884f9093be80632397f5736dce2fece627a4182daf3cdbf8bf12c8e3e02668"),
        (bytes(range(64)), "dd0d06fbe4e7575d0eeac53706482cbbe592e269a35bcd5591a495814371724e"),
        (b"hello world", "fd1f5d7d4701c25bbdd5dd6e3be6abb474fffbaa402f814dce95f8283abbf3e7"),
        (b"test 512-bit hash".ljust(0), ""),
    ]
    for data, want in vectors:
        if not want:
            continue
        got = hash_bytes(data).hex()
        assert got == want, f"hash_bytes({data[:8]!r}...) got {got} want {want}"
    print("selftest OK: permute(zero) + 5 hash_bytes vectors match Rust")


if __name__ == "__main__":
    import sys
    _selftest()

    if "--check-zero-tail" in sys.argv:
        # 对真实量级的输入（32B 块头 + 64B nonce = 96B）检查第 2 段 squeeze
        nonzeros = 0
        for k in range(2000):
            bh = k.to_bytes(32, "big")
            nonce = (k * 0x9E3779B97F4A7C15 + 1).to_bytes(64, "big")
            h = hash_squeeze_twice(bh + nonce)
            if h[32:] != bytes(32):
                nonzeros += 1
                if nonzeros == 1:
                    print("first non-zero second half:", h.hex())
        print(f"inputs=2000  second-half non-zero: {nonzeros}")
