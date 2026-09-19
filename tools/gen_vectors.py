"""生成 CUDA 内核的验证向量文件。

组成：
  1. 官方 quantus-miner 的 NONCE_HASH_KVS 五组（hash_squeeze_twice 的 64 字节输出）
  2. 参考实现算出的随机向量，覆盖边界（全 0 / 全 ff / 长度不变但内容变）

格式：每行 `<header_hex> <nonce_hex> <hash_hex>`。
"""

from __future__ import annotations

import random
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import poseidon2_ref as R  # noqa: E402

SRC = HERE / "upstream" / "miner__pow-core.rs"
OUT = HERE.parent / "vectors.txt"


def official_vectors() -> list[tuple[str, str, str]]:
    """解析官方 NONCE_HASH_KVS。

    注意：源码里至少有一条 nonce 不是 128 hex 字符（畸形条目），
    必须按**字符长度**过滤而不是按字节长度，否则会写进非法向量。
    """
    text = SRC.read_text(encoding="utf-8")
    block = text.split("pub const NONCE_HASH_KVS")[1].split("\n];")[0]
    out = []
    skipped = 0
    for entry in block.split("NonceHashKv {")[1:]:
        h = re.search(r'header:\s*"([0-9a-fA-F]*)"', entry).group(1)
        n = re.search(r'nonce:\s*"([0-9a-fA-F]*)"', entry).group(1)
        d = re.search(r'hash:\s*"([0-9a-fA-F]*)"', entry).group(1)
        if len(h) == 64 and len(n) == 128 and len(d) == 128:
            out.append((h, n, d))
        else:
            skipped += 1
            print(f"  跳过畸形向量: len(h)={len(h)} len(n)={len(n)} len(hash)={len(d)}")
    if skipped:
        print(f"  （共跳过 {skipped} 条）")
    return out


def main() -> int:
    rows: list[tuple[str, str, str]] = []
    rows.extend(official_vectors())
    n_official = len(rows)

    random.seed(20260918)
    cases = [
        (bytes(32), bytes(64)),
        (b"\xff" * 32, b"\xff" * 64),
        (bytes(range(32)), bytes(range(64))),
        (bytes(32), b"\x00" * 63 + b"\x01"),          # nonce = 1（大端最低字节）
        (bytes(32), b"\x00" * 60 + b"\xff\xff\xff\xff"),  # nonce 低 4 字节全 1
    ]
    # 断言每条种子都是合法长度，防止再写出畸形向量
    for h, n in cases:
        assert len(h) == 32 and len(n) == 64, (len(h), len(n))
    for _ in range(20):
        cases.append((random.randbytes(32), random.randbytes(64)))
    # 只改 nonce 低 4 字节：验证扫描路径
    base_h, base_n = random.randbytes(32), random.randbytes(64)
    for k in range(8):
        cases.append((base_h, base_n[:60] + k.to_bytes(4, "big")))

    for h, n in cases:
        rows.append((h.hex(), n.hex(), R.hash_squeeze_twice(h + n).hex()))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as f:
        for h, n, d in rows:
            f.write(f"{h} {n} {d}\n")
    print(f"wrote {OUT}: {len(rows)} 组（{n_official} 组官方 + {len(rows)-n_official} 组参考实现）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
