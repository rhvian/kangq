# Changelog

性能数字只引用 `kanq-test bench` 与矿池实跑的记录；每个版本发布前都在真实矿池拿到过被接受的 share。

---

## 未发布

内核默认路径与 1.2 相同（速率不变），只加了实验开关并记录结论：

- `QPOW_UNROLL=0/1/2`（默认 0）：轮循环小幅展开 / 单 permute 直线 / 整个 hash 直线；`QPOW_LOCKSTEP`：每个 nonce 前拉齐块内 warp。
  3090 实测直线展开 −12%，加 lockstep 后 +0.7%，不采用；机制与数据在 `docs/PERFORMANCE.md §2.6`。
- `QPOW_LIMB32`（默认关）：32-bit limb 乘法实验路径（`src/goldilocks32.cuh`），三道自检通过但指令数 +47%、速率 185 MH/s，不采用。
- `tools/sass_check.sh`：静态 SASS 门（IMAD.HI 计数、溢出）。

---

## 1.2 — 2026-09-19

状态：4090 `bench 8` 923.6 MH/s；矿池实跑 916–922 MH/s；三道自检 38/38；`--once` share accepted。

### 内核

- 轮循环小幅展开（全轮 ×2、部分轮 ×3）+ `__launch_bounds__(256, 1)` 放开寄存器（实际 94 个，0 溢出）：
  885 → ~910 MH/s。前提是寄存器够用——64 寄存器下同样的展开会溢出反而更慢。
- 内部轮 12 元素求和改为 lo32 / hi32 各自累加（无跨值进位链），单独无收益，但让展开后不溢出。
- 做了一轮系统性的性能调查（静态 SASS 账本、sm_89 整数管线微基准、占用率扫描、11 个内核变体），
  结论写在 `docs/PERFORMANCE.md`：当前算法形态在 4090 上的平台就是 ~910–925 MH/s，再往上要换算法形态。

### 矿工

- 新增 `--device <n>` 选择 GPU（多卡每卡起一个进程，salt 不同不重复扫描）。
- 新增 `--version`；未知参数报错退出而不是静默忽略。
- 登录 `agent` 改为 `KanQ/<版本>`。

### 工程

- 项目从研究工作区整理为独立仓库 KanQ：`build.sh` / `run.sh`（断线自动重启）/ `tools/`（参考实现与生成器）/ `docs/`。

---

## 1.1 — 2026-09-18

状态：4090 `bench 8` 901 MH/s；矿池实跑 901.7 MH/s；24 小时长跑提交 1215 / 接受 1189 / Stale 26（2.1%），无崩溃。

### 内核（较 1.0 快 9×，量化归因见 `docs/PERFORMANCE.md §1`）

- nonce 索引移到 nonce[56:64]，主机每 job 算一次 prestate，GPU 每 nonce 只跑 2 次 permute（原 4 次）。
- 惰性归约：域元素保持在 [0, 2^64)，加法一次折叠、乘法归约 6 条 PTX；两处 ~2^-33 的回绕故意不修，
  主机对每个 GPU 候选精确复核后才提交（与官方内核相同取舍）。
- 外部线性层在 96 位累加器里累加，每元素只归约一次。
- 轮循环 `#pragma unroll 1`：全展开 12.6 MB 二进制击穿指令缓存。
- 新增 `pstest`（prestate 分解 + GPU 挖矿路径对主机精确摘要）作为第三道自检门。

### 矿工

- 网络 I/O 改 `MSG_DONTWAIT` 并与内核异步重叠（原 300 ms 阻塞 recv 让 GPU 闲 90%）。
- 候选提交前检查 job 是否已变更，变了直接丢弃不发（减少 Stale）。

---

## 1.0 — 2026-09-17

状态：协议链路打通，真实矿池 share accepted；4090 75–100 MH/s。

- Kryptex QTC 矿池协议逆向完成（`docs/PROTOCOL.md`）：行分隔 JSON、`login` / `job` / `submit` 方言、
  nonce 布局（前 4 字节必须是矿池 `extranonce`）、错误语义；经第三方矿工抓包逐字段确认。
- QPoW（Poseidon2/Goldilocks）独立 Python 参考实现，与官方 `NONCE_HASH_KVS` 对拍 10/10；
  轮常量与测试向量全部由生成器从上游源码解析产出（`tools/`）。
- CUDA 内核 + 主机精确实现，`fieldtest` / `selftest` 两道自检。
