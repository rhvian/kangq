# KanQ — Quantus (QTC) QPoW 高性能 GPU 挖矿软件

[![Release](https://img.shields.io/badge/release-v1.2-blue)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20NVIDIA%20CUDA-green)](#硬件要求)
[![License](https://img.shields.io/badge/license-NonCommercial%20%7C%20NoFee%20%7C%20Attribution-important)](LICENSE)

> **🔴 重要声明（务必阅读）**
>
> 本项目 **100% 开源、零开发费 / 零抽水（Zero Dev Fee）**。
>
> - 矿工提交给矿池的全部有效 share，收益**归矿工本人所有**——源码中**没有任何**算力分流、份额重定向、隐藏 devfee 的逻辑，欢迎审计（矿池客户端只有 `src/miner.cu` 一个文件，300 行）。
> - **严禁商用**（不得做成收费托管 / 云算力 / 收费套件）。
> - **二次开发禁止加入任何抽水机制**（不得加 devfee、不得分流 share、不得篡改 wallet/worker）。
> - **二次开发必须标注出处**（保留 `Based on KanQ by rhvian/kangq`）并保留 [LICENSE](LICENSE) 全文。
>
> 完整条款见 [LICENSE](LICENSE)。违反任一条款 = 自动失去授权。

---

## 目录

- [功能特性](#功能特性)
- [硬件要求](#硬件要求)
- [快速开始](#快速开始)
- [命令行参数](#命令行参数)
- [多卡](#多卡)
- [后台运行与自动重启](#后台运行与自动重启)
- [日志格式](#日志格式)
- [性能参考](#性能参考)
- [正确性保证](#正确性保证)
- [项目结构](#项目结构)
- [常见问题](#常见问题)
- [许可与出处](#许可与出处)

---

## 功能特性

- **Kryptex QTC 矿池**（`qtc.kryptex.network:7049`）——协议经逆向 + 第三方矿工抓包逐字段确认，见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)
- **CUDA 内核**：Poseidon2/Goldilocks 惰性归约 + 主机 prestate，每 nonce 只跑 2 次置换；RTX 4090 **~920 MH/s**（官方开源 CUDA 862–886）
- **每个候选主机精确复核**：GPU 用惰性归约找候选，提交前主机用精确算法重算，保证发出去的 share 全部有效
- **网络 I/O 与内核异步重叠**：矿池消息非阻塞处理，GPU 不空转
- **job 变更即丢弃**：过期候选不提交，减少 Stale
- **单文件矿池客户端**、无第三方依赖：只需 CUDA Toolkit + NVIDIA 驱动
- **三道自检**（`fieldtest` / `selftest` / `pstest`）把内核钉在官方测试向量上
- **零开发费 / 零抽水**

---

## 硬件要求

| 项目 | 要求 |
|---|---|
| GPU | NVIDIA，计算能力 ≥ 7.5（Turing / Ampere / Ada / Hopper）。实测平台 RTX 4090（sm_89） |
| 显存 | 极小（< 100 MB） |
| 系统 | Linux x86-64。Windows 需自行改 `src/miner.cu` 的 socket 调用（POSIX） |
| 构建依赖 | CUDA Toolkit 12.x（`nvcc`）、GCC 9+ |
| 运行依赖 | NVIDIA 驱动（CUDA 12 兼容） |

---

## 快速开始

```bash
git clone https://github.com/rhvian/kangq.git
cd kangq
./build.sh                        # 自动从 nvidia-smi 检测架构；约 10–20 秒

# 自检（内核改动后必跑；首次也建议跑一遍）
./build/kanq-test fieldtest
./build/kanq-test selftest vectors.txt
./build/kanq-test pstest   vectors.txt

# 挖矿
./run.sh --wallet 你的QTC地址 --worker rig01
```

钱包地址是 Quantus 主网地址（`qz` 开头）。`--worker` 是矿池后台用来区分机器的标签，可选。

先验证一下链路（拿到一个被接受的 share 后自动退出，通常 20–60 秒）：

```bash
./build/kanq --wallet 你的QTC地址 --once
```

---

## 命令行参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `--wallet ADDR` | QTC 钱包地址（`qz...`） | 必填 |
| `--worker NAME` | worker 名，以 `wallet.worker` 登录矿池 | `gpu` |
| `--pool HOST:PORT` | 矿池地址（明文 TCP） | `qtc.kryptex.network:7049` |
| `--device N` | 使用第 N 张 GPU | `0` |
| `--blocks N` | 网格块数（256 线程/块） | `4096` |
| `--iters N` | 每线程连续扫描的 nonce 数 | `16` |
| `--once` | 拿到一个被接受的 share 后退出（验证用） | 关 |
| `--dry-run` | 只搜索并复核，不提交 | 关 |
| `--version` | 显示版本 | — |

`--blocks` / `--iters` 在 4090 上实测不是性能杠杆（871–897 MH/s 全平台），一般不需要改。
区域节点：`qtc-{eu,us,br,sg,hk,ru,ae}.kryptex.network:7049`。

---

## 多卡

每张卡起一个进程，用 `--device` 区分；每个进程有独立随机 salt，不会重复扫描：

```bash
./build/kanq --wallet ADDR --worker rig01-0 --device 0 &
./build/kanq --wallet ADDR --worker rig01-1 --device 1 &
```

同一张卡**不要**跑两个实例：速率腰斩、功耗反而下降。

---

## 后台运行与自动重启

`run.sh` 在矿工退出（矿池断连、15 秒无 job、异常）后 5 秒自动拉起，日志追加到 `kanq.log`：

```bash
nohup ./run.sh --wallet ADDR --worker rig01 >/dev/null 2>&1 &
tail -f kanq.log
```

| 环境变量 | 作用 | 默认 |
|---|---|---|
| `KANQ_RESTART` | `auto` 自动重启；`0` 只跑一次 | `auto` |
| `KANQ_RESTART_DELAY` | 重启间隔（秒） | `5` |
| `KANQ_LOG` | 日志文件；`-` 只打到终端 | `./kanq.log` |

停止：`touch STOP`（矿工下次退出后守护结束），或 `kill` 矿工进程。

systemd 示例（`/etc/systemd/system/kanq.service`）：

```ini
[Unit]
Description=KanQ QTC miner
After=network-online.target

[Service]
WorkingDirectory=/opt/kanq
ExecStart=/opt/kanq/run.sh --wallet ADDR --worker rig01
Environment=KANQ_LOG=-
Restart=always

[Install]
WantedBy=multi-user.target
```

---

## 日志格式

```
KanQ 1.2
GPU #0: NVIDIA GeForce RTX 4090  SMs=128  网格=4096×256  每线程 16 nonce  (每轮 1.68e+07 nonce)
矿池: qtc.kryptex.network:7049  钱包: qz...  worker: rig01
已连接 qtc.kryptex.network:7049
[login] OK session=0ff91544-...  job=e36c9980_18253611008 diff=18253611008 extr=3a4e95df
[job ] 860d9e84_18253611008  diff=18253611008  extr=3a4e95df
  [进度] 922.1 MH/s  轮=275  累计 4.614e+09 nonce  提交=0 接受=0 拒绝=0  job=04a346a0_18253611008
*** share nonce=3a4e95df6ec7...19e20fbb3
    result=0000000010a839...
    [提交] job=ab694279_18253611008
[submt] *** 矿池接受 *** 累计 1
    统计: 提交=1 接受=1 拒绝=0 最后错误=
```

- `[进度]` 每 5 秒一行：累计平均速率、轮数、提交/接受/拒绝
- `[submt] 拒绝: Stale share`：job 切换瞬间的正常损耗（24 小时实跑 2.1%）
- `[cand ] GPU 候选未过主机精确判定`：惰性归约的预期误差（~3e-7/哈希），不会提交

---

## 性能参考

同一张 RTX 4090（450 W）：

| 实现 | 速率 |
|---|---|
| **KanQ 1.2** | **~920 MH/s**（`bench 8` 923.6；矿池实跑 916–922） |
| KanQ 1.1 | ~900 MH/s |
| 官方 quantus-miner CUDA v4.2.0 | 862–886 MH/s |
| 官方 WGSL/Vulkan 路径 | ~106 MH/s（3080 Ti） |
| fl4shminer（闭源） | 1.22 GH/s |

share 难度 18,253,611,008 时约 20 秒一个 share。24 小时长跑：提交 1215 / 接受 1189 / Stale 26，无崩溃。

与闭源矿工的 1.3× 差距做过一轮系统性调查（静态 SASS 账本、sm_89 整数管线微基准、占用率扫描、11 个内核变体），
结论是当前算法形态在 4090 上的平台就是 ~910–925 MH/s，再往上要换算法形态而不是调参。
完整数据与「不要再试的」清单见 [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md)。

---

## 正确性保证

所有哈希实现锚定在同一条链上，改任何一层都沿链重跑下游：

```
tools/upstream/qp-poseidon__poseidon2.rs（上游常量快照）
        │ 解析
        ▼
tools/poseidon2_ref.py ── verify_against_miner.py ─► 官方 NONCE_HASH_KVS 对拍 10/10
   唯一真源           ── verify_prestate.py ───────► prestate 分解对拍 38 + 200 随机
        ├─ gen_constants.py ─► src/constants.cuh（130 个轮常量，禁止手抄）
        ├─ gen_vectors.py ───► vectors.txt（38 组：5 官方 + 33 随机边界）
        ├─ src/qpow_host.h     主机精确实现：每 job 算 prestate、复核每个 GPU 候选
        └─ src/qpow.cuh        GPU 惰性实现：fieldtest / selftest / pstest 三道门
```

- GPU 内核用**惰性归约**（与官方内核相同）：约 2^-33/次乘法的回绕故意不修正，所以 GPU 只找候选，主机精确复核后才提交。
- 难度口径：`U512(hash) < U512::MAX/D`。GPU 按高 256 位 `<=` 收候选，主机用完整 512 位严格 `<` 判定，与链上 `is_valid_nonce` 一致。
- QPoW 精确规格、难度口径、链经济学见 [`docs/QPOW.md`](docs/QPOW.md)。

```bash
python tools/verify_against_miner.py      # 期望 "10 checks passed, 0 failed"
python tools/verify_prestate.py           # 期望 "RESULT: OK"
python tools/gen_constants.py             # 重生成 src/constants.cuh（应与仓库内一致）
python tools/gen_vectors.py               # 重生成 vectors.txt
python tools/khs_miner.py --wallet qz... --selftest   # Python 矿池客户端（参考实现，~1 kH/s）
```

---

## 项目结构

```
kanq/
├── src/
│   ├── miner.cu          # 矿工主程序：矿池客户端 + 挖矿循环 + 主机复核（单文件）
│   ├── kanq_test.cu      # 自检与 bench：fieldtest / selftest / pstest / bench
│   ├── qpow.cuh          # GPU 内核：Goldilocks 惰性域运算 + Poseidon2 置换 + mine_kernel
│   ├── qpow_host.h       # 主机精确实现：prestate、完整哈希、512 位难度判定
│   ├── constants.cuh     # 轮常量（生成器产出，勿手改）
│   └── version.h         # 版本号
├── tools/
│   ├── poseidon2_ref.py          # Python 参考实现（唯一真源）
│   ├── verify_against_miner.py   # 与官方向量对拍
│   ├── verify_prestate.py        # prestate 分解对拍
│   ├── gen_constants.py          # → src/constants.cuh
│   ├── gen_vectors.py            # → vectors.txt
│   ├── khs_miner.py              # Python 矿池客户端（协议参考）
│   └── upstream/                 # 上游 Rust 源码快照
├── docs/
│   ├── PROTOCOL.md       # Kryptex QTC 线协议（抓包实录、错误语义、nonce 布局）
│   ├── QPOW.md           # QPoW 算法规格、难度口径、主网数据
│   └── PERFORMANCE.md    # 性能归因、微基准、试过的变体
├── vectors.txt           # 38 组测试向量
├── build.sh              # 编译 → build/kanq、build/kanq-test
├── run.sh                # 守护运行（自动重启）
├── CHANGELOG.md
├── LICENSE
└── README.md
```

---

## 常见问题

### `找不到 nvcc`
安装 CUDA Toolkit 12.x，或 `NVCC=/usr/local/cuda-12.8/bin/nvcc ./build.sh`。

### 不是 4090 怎么编译
`build.sh` 从 `nvidia-smi` 读计算能力自动选架构；手动指定：`ARCH="sm_86" ./build.sh`，多架构 `ARCH="sm_86 sm_89"`。

### `15 秒内未收到 job`
矿池不可达或钱包地址格式不对（必须是 `qz` 开头的主网地址）。`telnet qtc.kryptex.network 7049` 看连通性。

### 拒绝全是 `Stale share`
正常，job 切换瞬间飞行中的 share 被矿池判过期，24 小时实测 2.1%。若比例明显更高，检查到矿池的延迟或换区域节点。

### 拒绝出现 `Invalid nonce`
不应出现——每个 share 提交前都经主机精确复核。如遇到，跑三道自检并提 issue 附日志。

### 速率明显低于 900 MH/s
1. `nvidia-smi` 看是否有别的进程占卡（同卡两个矿工速率腰斩）
2. 看核心频率是否撞功耗墙（4090 满载 2.5 GHz 左右）
3. `./build/kanq-test bench 8` 测纯内核速率，与矿池实跑对比定位在内核还是网络

### Windows
矿池客户端用 POSIX socket，未做 Windows 移植；内核与自检（`kanq_test.cu`）本身不依赖平台。

---

## 许可与出处

本项目按 [LICENSE](LICENSE) 条款发布。核心要点：

| ✅ 允许 | ❌ 禁止 |
|---|---|
| 个人非商业挖矿使用 | 商业使用（收费托管 / 云算力 / 收费套件） |
| 审阅、学习、研究源码 | 加入任何抽水 / devfee / 算力分流 |
| 学习性 fork 与修改 | 闭源魔改、删除 LICENSE、弱化禁商用条款 |
| 在矿池为本人地址挖矿 | 篡改 wallet/worker 窃取他人算力 |

**二次开发必须**：在用户可见处标注 `Based on KanQ by rhvian/kangq (https://github.com/rhvian/kangq)`、保留 LICENSE 全文、以相同条款发布、公开完整源码。

姊妹项目：[Kan](https://github.com/tvvshow/kan-mine) —— Pearl (PRL) PoUW 矿工，同一许可。

## 致谢

- **Quantus Network**：https://github.com/Quantus-Network（`qp-poseidon`、`quantus-miner` 是常量与测试向量的来源）
- **Kryptex 矿池**：https://pool.kryptex.com/qtc

---

*RTX 4090: ~920 MH/s · 100% 开源 · 零抽水 · 禁商用*
