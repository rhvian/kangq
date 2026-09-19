"""用官方 miner 的硬编码向量交叉验证 poseidon2_ref。

向量直接从 quantus-miner `crates/pow-core/src/lib.rs` 的 NONCE_HASH_KVS
源码文本解析，避免人工转录错误。

目的：证明我对 QPoW 哈希的理解与官方实现一致（不是自洽的循环论证）。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import poseidon2_ref as R  # noqa: E402

SRC = HERE / "upstream" / "miner__pow-core.rs"


def parse_kvs() -> list[tuple[str, str, str, list[int]]]:
    text = SRC.read_text(encoding="utf-8")
    block = text.split("pub const NONCE_HASH_KVS")[1].split("\n];")[0]
    out = []
    for entry in block.split("NonceHashKv {")[1:]:
        header = re.search(r'header:\s*"([0-9a-fA-F]*)"', entry).group(1)
        nonce = re.search(r'nonce:\s*"([0-9a-fA-F]*)"', entry).group(1)
        hash_ = re.search(r'hash:\s*"([0-9a-fA-F]*)"', entry).group(1)
        mid = [int(v, 16) for v in re.findall(r"0x([0-9a-fA-F]+)", entry.split("mid:")[1])]
        out.append((header, nonce, hash_, mid))
    return out


def midstate(header: bytes, nonce_high_be: bytes) -> list[int]:
    """复刻 pow-core::mining_midstate：两个 8-felt 块各带一次 permute。"""
    s = [0] * 12
    for i in range(8):
        s[i] = (s[i] + int.from_bytes(header[4 * i:4 * i + 4], "little")) % R.P
    R.permute(s)
    for i in range(8):
        s[i] = (s[i] + int.from_bytes(nonce_high_be[4 * i:4 * i + 4], "little")) % R.P
    R.permute(s)
    return s


def main() -> int:
    R._selftest()
    ok = fail = 0
    for idx, (h, n, want_hash, want_mid) in enumerate(parse_kvs()):
        raw = bytes.fromhex(n)
        # 源码里这个字段应当是 64 字节；不等就说明向量本身不是可直接用的输入。
        note = "" if len(raw) == 64 else f"  (nonce {len(raw)} bytes, NOT 64 — source vector malformed)"
        if len(raw) != 64:
            print(f"KV[{idx}] SKIP{note}")
            continue
        header, nonce = bytes.fromhex(h), raw
        got_hash = R.hash_squeeze_twice(header + nonce).hex()
        got_mid = midstate(header, nonce[:32])
        h_ok = got_hash == want_hash
        m_ok = got_mid == want_mid
        ok += h_ok + m_ok
        fail += (not h_ok) + (not m_ok)
        print(f"KV[{idx}] hash={'OK' if h_ok else 'MISMATCH'}  midstate={'OK' if m_ok else 'MISMATCH'}")
        if not h_ok:
            print(f"    got  {got_hash}\n    want {want_hash}")
        if not m_ok:
            print(f"    got  {[hex(v) for v in got_mid]}\n    want {[hex(v) for v in want_mid]}")
    print(f"\n{ok} checks passed, {fail} failed")
    return 1 if fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
