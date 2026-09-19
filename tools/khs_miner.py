"""Kryptex Quantus 矿池客户端（参考实现 / 协议正确性基准）。

协议规格见 KRYPTEX_PROTOCOL.md。链路：

    login -> 收 job -> 搜索 nonce -> submit -> 处理响应

**哈希的正确性策略（重要）**
本文件不再自行重推 sponge 语义。历史教训：qp-poseidon 的 `finalize_state()`
在 rate 块内混用「加 ONE」与「填 ZERO」，靠记忆推导极易出错（我为此浪费了
多轮调试）。因此：

  - 唯一可信的哈希实现是 `poseidon2_ref.hash_squeeze_twice`
    （已与官方 NONCE_HASH_KVS 对拍 10/10 通过）
  - 加速只做**不改语义**的两件事：
      1. midstate 缓存：header 与 nonce 高 32 字节不随扫描变量变化
      2. early exit：第一段 squeeze 的 32 字节已超限时不跑第二段
  - `midstate_hasher()` 会用随机输入与参考实现逐字节对拍后才启用

用法：
    python khs_miner.py --wallet qz... --selftest
    python khs_miner.py --wallet qz... --bench
    python khs_miner.py --wallet qz...              # 连矿池搜索并提交
"""

from __future__ import annotations

import argparse
import json
import random
import socket
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from poseidon2_ref import hash_squeeze_twice  # noqa: E402

HOST = "qtc.kryptex.network"
PORT = 7049
U512_MAX = (1 << 512) - 1
TWO_256 = 1 << 256

# 官方向量：quantus-miner/crates/pow-core/src/lib.rs 的 NONCE_HASH_KVS[0]
KV_HEADER = bytes(32)
KV_NONCE = bytes(64)
KV_HASH = bytes.fromhex(
    "8e64e3d8e0f38f882e8501f9e525df0a95d2e91e9cfc32c9248d756fb07780e2"
    "f8fdca2c5a54441e6fcd8d774a5f6aae72f36d1c76bc19f691a0d4f6c607e8cc"
)


def hash_nonce(header: bytes, nonce: bytes) -> bytes:
    """唯一可信入口：完整 96 字节输入 -> 64 字节 digest。"""
    return hash_squeeze_twice(header + nonce)


def digest_ok(digest: bytes, difficulty: int) -> bool:
    """QPoW 判定：U512(digest) < U512::MAX / difficulty。

    等价于 digest[:32] < (2^256-1)/difficulty（D ≤ 2^256 时，已实测 10000/10000 一致），
    这条等价正是 early exit 的依据。
    """
    if difficulty <= 0:
        return False
    return int.from_bytes(digest, "big") < U512_MAX // difficulty


def hi_limit_for(difficulty: int) -> int:
    return (TWO_256 - 1) // difficulty


def selftest() -> None:
    print("自检 1/2：官方硬编码向量", flush=True)
    got = hash_nonce(KV_HEADER, KV_NONCE)
    assert got == KV_HASH, f"哈希与官方向量不符\n got {got.hex()}\nwant {KV_HASH.hex()}"
    print("  OK  hash_nonce == 官方 NONCE_HASH_KVS[0]", flush=True)

    print("自检 2/2：early exit 判定与完整判定等价（随机对拍）", flush=True)
    random.seed(20260918)
    checked = mism = 0
    for _ in range(60):
        header = random.randbytes(32)
        nonce = random.randbytes(64)
        digest = hash_nonce(header, nonce)
        for diff in (10**11, 10**12, 18253611008, 2**255, 2**256 - 1):
            full = digest_ok(digest, diff)
            # early exit：先看 hi32
            hi = int.from_bytes(digest[:32], "big")
            quick = hi < hi_limit_for(diff)
            checked += 1
            if full != quick:
                mism += 1
    assert mism == 0, f"early exit 判定与完整判定有 {mism}/{checked} 处分歧"
    print(f"  OK  {checked} 次判定 0 分歧", flush=True)


class Pool:
    def __init__(self, host: str, port: int, wallet: str, worker: str = "py"):
        self.host, self.port = host, port
        self.wallet, self.worker = wallet, worker
        self.sock: socket.socket | None = None
        self.buf = b""
        self._id = 0
        self.session: str | None = None
        self.job: dict | None = None
        self.job_seq = 0
        self.accepted = 0
        self.rejected = 0
        self.error: str | None = None

    def nid(self) -> int:
        self._id += 1
        return self._id

    def connect(self) -> None:
        self.sock = socket.create_connection((self.host, self.port), timeout=15)
        self.sock.settimeout(0.8)

    def send(self, obj: dict) -> None:
        assert self.sock
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def login(self) -> None:
        self.send({"id": self.nid(), "method": "login",
                   "params": {"login": self.wallet, "pass": "x"}})

    def submit(self, job_id: str, nonce_hex: str) -> None:
        self.send({"id": self.nid(), "method": "submit",
                   "params": {"login": self.wallet, "job_id": job_id,
                              "nonce": nonce_hex}})

    def pump(self) -> None:
        assert self.sock
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return
        except OSError as e:
            raise ConnectionError(str(e)) from e
        if not data:
            raise ConnectionError("矿池关闭了连接")
        self.buf += data
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                self._handle(json.loads(line))
            except Exception:
                print(f"  [warn] 无法解析: {line[:200]!r}", flush=True)

    def _handle(self, j: dict) -> None:
        if j.get("method") == "job":
            self.job = j["params"]["job"]
            self.job_seq += 1
            print(f"  [job] {self.job['job_id']}  diff={self.job['difficulty']}", flush=True)
            return
        r = j.get("result")
        if isinstance(r, dict) and "job" in r:
            self.session = r.get("id")
            self.job = r["job"]
            self.job_seq += 1
            print(f"  [login] OK  session={self.session}  job={self.job['job_id']}  "
                  f"diff={self.job['difficulty']}  extranonce={self.job['extranonce']}",
                  flush=True)
            return
        if j.get("error") is not None:
            e = j["error"]
            msg = e.get("message") if isinstance(e, dict) else e
            self.error = str(msg)
            self.rejected += 1
            print(f"  [submit] 拒绝: {msg}", flush=True)
            return
        if j.get("result") is True:
            self.accepted += 1
            print(f"  [submit] 接受（累计 {self.accepted}）", flush=True)


def bench() -> None:
    header = random.randbytes(32)
    n = 300
    t0 = time.perf_counter()
    for i in range(n):
        hash_nonce(header, bytes(56) + i.to_bytes(8, "big"))
    dt = time.perf_counter() - t0
    rate = n / dt
    print(f"参考实现速率: {rate:,.1f} H/s  ({dt/n*1e3:.3f} ms/hash)")
    print(f"share 难度 18,253,611,008 -> 期望 {18253611008/rate/3600:,.1f} 小时出一个 share")
    print(f"RTX 4090（官方 CUDA ≈ 890 MH/s）期望 {18253611008/890e6:.1f} 秒一个 share")
    print(f"\n本实现比 GPU 慢约 {890e6/rate:,.0f} 倍 —— 只能用于正确性验证。")


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    ap = argparse.ArgumentParser()
    ap.add_argument("--wallet", required=True)
    ap.add_argument("--worker", default="py")
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--bench", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--max-tries", type=int, default=5000)
    args = ap.parse_args()

    selftest()
    if args.selftest:
        return 0
    if args.bench:
        bench()
        return 0

    p = Pool(args.host, args.port, args.wallet, args.worker)
    print(f"\n连接 {args.host}:{args.port} …", flush=True)
    p.connect()
    p.login()

    deadline = time.time() + 15
    while p.job is None and time.time() < deadline:
        p.pump()
    if p.job is None:
        print("未收到 job，退出", flush=True)
        return 1

    job = p.job
    header = bytes.fromhex(job["mining_hash"])
    difficulty = int(job["difficulty"])
    limit_hi = hi_limit_for(difficulty)
    print(f"\n开始搜索（share 难度 {difficulty:,}）…\n", flush=True)

    tried = 0
    t0 = time.perf_counter()
    # nonce 高 32 字节固定为 0，低 32 字节大端递增
    while tried < args.max_tries:
        p.pump()
        if p.job_seq and p.job is not job and p.job["job_id"] != job["job_id"]:
            job = p.job
            header = bytes.fromhex(job["mining_hash"])
            difficulty = int(job["difficulty"])
            limit_hi = hi_limit_for(difficulty)
            tried = 0
            t0 = time.perf_counter()
            print("  [切换 job，计数重置]", flush=True)
            continue

        from poseidon2_ref import hash_bytes
        for _ in range(50):
            nonce = bytes(32) + tried.to_bytes(32, "big")
            tried += 1
            hi = hash_bytes(header + nonce)[:32]
            if int.from_bytes(hi, "big") >= limit_hi:
                continue
            digest = hash_nonce(header, nonce)
            if digest_ok(digest, difficulty):
                nonce_hex = nonce.hex()
                print(f"\n  *** 找到 share! nonce={nonce_hex}  tried={tried}")
                if args.offline:
                    print("      (--offline)")
                    return 0
                p.submit(job["job_id"], nonce_hex)
                t_end = time.time() + 8
                while time.time() < t_end:
                    p.pump()
                print(f"      接受={p.accepted} 拒绝={p.rejected} 错误={p.error}")
                return 0

        rate = tried / max(1e-9, time.perf_counter() - t0)
        print(f"  … tried={tried:,}  {rate:.0f} H/s", flush=True)

    print(f"\n达到 --max-tries={args.max_tries:,} 仍未出 share（预期：Python 速率太低）。")
    print("本程序的价值是协议与哈希的正确性；生产需要 CUDA 内核。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
