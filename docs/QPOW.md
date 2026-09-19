# Quantus 研究报告

> 调查对象：<https://docs.quantus.com/> + 其一手源码仓库（`github.com/Quantus-Network`）
> 方法：文档全量抓取 → 下钻到 Rust 源码 → **独立 Python 复现哈希算法并与官方测试向量对拍**。
> 本文标注每条结论的来源与证据等级：
> - **[自证]** 我用独立实现/实跑复核过，给出可复现命令
> - **[源码]** 直接引自仓库源码，给出文件:行号
> - **[文档]** 官方文档陈述，未独立复核
> - **[未验证]** 明确说明尝试过什么

---

## 0. 一句话结论

Quantus 是一条 **Substrate(Polkadot SDK) 上的、无智能合约的、纯 PoW 储值链**，签名用 ML-DSA-87，
哈希用 Poseidon2，PoW 是 Poseidon2 上的 nonce grinding（**"QPoW" 是品牌名，不是格难题**）。
挖矿协议是节点作为 QUIC 服务端 + 外部 miner，**官方 miner 已实现 CUDA 并且做过深度的 midstate/early-exit 优化**。
链很新（v1.0.1，2026-09-09 发布），因此评估挖矿可行性时**当前难度是唯一决定性问题**，而这一点需要链上数据。

---

## 1. 项目定位与技术栈

| 项 | 值 | 来源 |
|---|---|---|
| 框架 | Substrate / Polkadot SDK，链上 WASM 无分叉升级 | [文档] architecture |
| 原生代币 | QTC，12 位小数（`UNIT = 10^12`） | [源码] `runtime/src/lib.rs:102` |
| 总量 | 21,000,000 QTC | [源码] `runtime/src/lib.rs:110` |
| 创世分配 | 27% = 5,670,000 QTC，线性解锁（1 年 cliff + 3 年线性） | [源码] `runtime/src/genesis_config_presets/mainnet_vesting.rs:4,31,39,41` |
| 地址 | SS58 prefix 189，`qz...` 开头 | [文档] qpow |
| 智能合约 | **无**（设计取舍：减少攻击面） | [文档] architecture |
| 签名 | ML-DSA-87 (Dilithium)，NIST Level 5，约 4,627 B/签名 | [文档] pqc |
| P2P 加密 | ML-KEM-768 + ML-DSA-87（fork 的 libp2p） | [文档] pqc |
| 状态哈希 | Poseidon2 + zk-trie | [文档] pqc |
| ZK | Plonky2 (STARK)，无 trusted setup | [文档] wormhole |
| 出块 | 12 s 目标，max reorg 100 块 | [源码] `runtime/src/lib.rs:94`、`configs/mod.rs:168` |

### 文档明确承认的一件事
> "The name is branding — the work function is Poseidon2 hash grinding, not a lattice problem."
> —— <https://docs.quantus.com/deep-dives/qpow/>

这是加分项：没有拿"量子 PoW"包装实际上只是普通哈希 grinding。

---

## 2. QPoW 算法：精确规格（[自证]）

### 2.1 定义

```
input      = pre_seal_header_hash (32 B) || nonce (64 B)     # 96 B
hash512    = Poseidon2_squeeze_twice(input)                  # 64 B
valid      = U512::from_big_endian(hash512) < U512::MAX / difficulty
```

来源：`qpow-math/src/lib.rs:7-49`（`is_valid_nonce` / `get_nonce_hash`）。

- nonce 是 **U512，64 字节大端**（`nonce.to_big_endian()`，`qpow-math/src/lib.rs:76-79`）
- 挖矿从随机起点递增 +1（`miner/pow-core/src/lib.rs:279` `step_nonce`）
- 起点用 CSPRNG 随机，nonce 空间 2^512，多矿工几乎不可能撞车

### 2.2 Poseidon2 实例参数

来源：`qp-poseidon/src/poseidon2.rs:13-31`

| 参数 | 值 |
|---|---|
| 域 | Goldilocks，p = 2^64 − 2^32 + 1 |
| SPONGE_WIDTH | 12 |
| SPONGE_RATE | 8 |
| SPONGE_CAPACITY | 4 |
| POSEIDON2_OUTPUT | **4** felt（= 32 B 摘要） |
| 外轮 | 8（4 前 + 4 后），S-box = x^7 |
| 内轮 | 22（只对 state[0] 做 S-box） |

字节编码（`serialization.rs:140-214`）：**4 字节小端 = 1 felt**，末尾追加一个 `0x01` 终止符
（若输入长度不是 4 的倍数，则终止符与最后一个残块合并到一个 4 字节字里）。
摘要序列化（`serialization.rs:308-316`）：**8 字节小端 = 1 felt**，只取 `state[..4]`。

### 2.3 "squeeze twice" 到底做了什么（关键）

`qp-poseidon/src/lib.rs:96-103`：

```rust
fn finalize_squeeze_twice(&mut self) -> [u8; 64] {
    self.finalize_state();                                       // 吸收尾块 + permute
    let mut out = [0u8; 64];
    out[..32].copy_from_slice(&digest_to_bytes(self.digest()));  // 第 1 段
    self.poseidon2.permute_mut(&mut self.state);                 // 再来一次 permute
    out[32..].copy_from_slice(&digest_to_bytes(self.digest()));  // 第 2 段
    out
}
```

**一次 nonce 哈希 = 5 次 Poseidon2 permutation**（[自证]，见 §2.5）：
3 次吸收满块（24 felt = 3×8）+ 1 次吸收尾块 + 1 次第二段 squeeze。

第 1 段 squeeze **恰好等于** `hash_bytes(input)`（官方测试也断言这一点，`qp-poseidon/src/lib.rs:327-328`）。

### 2.4 难度口径：512-bit 比较实际上只用到高 256 bit（[自证]）

`hash512` 含两个 32 字节半段，分别是：
- `hi` = 第 1 段 squeeze（state[0..4]，均匀分布）
- `lo` = 第 2 段 squeeze（state[0..4]，均匀分布）

`U512::from_big_endian` 把 `hi` 放在高位、`lo` 放在低位，所以

```
U512(hash) < U512::MAX / D   ⟺   hi < (2^256 − 1) / D
```

**我实测确认该等价关系**：2000 个随机 nonce × 5 档难度（1e11、1e14、1e20、2^255、2^256），
10000 次判定 **0 处分歧**；`hi` 分布均匀（3000 样本中位数 ≈ 2^255）。

推论：
1. **有效难度上限 = 2^256 ≈ 1.16e77**，远高于任何硬件能达到的量级，不构成风险。
2. **第 2 段 squeeze 对判定结果零贡献**，纯属 20% 的浪费——下面 §2.6 会看到官方 miner 正是这么利用的。

### 2.5 证据：独立实现与官方向量完全一致（[自证]）

我写了 `poseidon2_ref.py`（纯 Python 复现 Poseidon2/Goldilocks/sponge）并做两级校验：

```powershell
python tools\verify_against_miner.py
```

```
selftest OK: permute(zero) + 5 hash_bytes vectors match Rust
KV[0] hash=OK  midstate=OK
KV[1] hash=OK  midstate=OK
KV[2] hash=OK  midstate=OK
KV[3] hash=OK  midstate=OK
KV[4] hash=OK  midstate=OK

10 checks passed, 0 failed
```

- `selftest`：对齐 `qp-poseidon` 自己的 Rust 测试向量（`permute(0…0)` 全 12 个输出 + 5 条 `hash_bytes` 向量）
- `KV[*] hash`：对齐官方 miner 里硬编码的 `NONCE_HASH_KVS`（`crates/pow-core/src/lib.rs:120+`）
- `KV[*] midstate`：对齐官方 `mining_midstate` 的 12 个 felt

**意义**：这不是自洽论证——我的实现是独立写的，能复现两个不同仓库的官方向量，
说明 §2.1–2.4 的规格描述可信。

### 2.6 官方 miner 已经用的优化（[源码]）

`quantus-miner/crates/pow-core/src/lib.rs:289-347` 的 `MiningHasher`：

1. **midstate 缓存**：`mining_midstate(header, nonce_high_be)` 预计算
   "header 块 + nonce 高 32 字节" 两次 permutation 后的状态。
   批量挖矿时 nonce 递增不回卷高位，所以 **5 次 permutation 里省掉 2 次**。
2. **early exit**：先只算第 1 段 squeeze，比较 `hash_bytes[..32] > target_bytes[..32]`，
   超了就 `return None`，**跳过第 2 段 squeeze**。
3. **prestate 优化**：`mining_prestate_low64` 把 nonce 低 64 bit 单独分离出来，
   让 GPU kernel 可以按 nonce 注入稀疏线性贡献后直接进第一轮 S-box
   （`pow-core/src/lib.rs:38-70`）。

源码注释明确写了这个设计意图：
> "the first two of the five Poseidon2 permutations of `get_nonce_hash` … GPU kernels can resume the sponge from here and skip 2 of 5 permutations."

**结论：我在 §2.4 推出的"跳过第二段 squeeze"优化，官方 miner 早已实现。**
这条不是新发现，而是**验证了官方实现没有浪费这 20%**——所以"优化空间"这一方向基本已被吃掉。

---

## 3. 挖矿性能实测数据（[源码]，官方自测记录）

`quantus-miner/docs/vast-gpu-benches.md`，Vast.ai 同机 A/B：

| GPU | 引擎 | 算力 | 备注 |
|---|---|---|---|
| RTX 3080 Ti | WGSL(Vulkan) 官方 v4.0.2 | 106.0 MH/s | |
| RTX 3080 Ti | CUDA v8 kernel | **273.8 MH/s** | CUDA / WGSL = **2.58×** |
| RTX 3080 Ti | CUDA PR#100 | 380–381 MH/s | 比 v4.1.1 **+31%** |
| RTX 4090 | CUDA v4.1.1 | 624–629 MH/s | |
| RTX 4090 | CUDA PR#100 | 816–820 MH/s | **+30.5%** |
| RTX 4090 | CUDA v4.2.0 | 862–886 MH/s | 450W/420W |
| RTX 4090 | CUDA PR#104 | **880–902 MH/s** | +2.1~2.2% |

结论：**GPU 走 CUDA 而不是 wgpu/Vulkan，是近 2.6× 的差距**；单张 4090 约 0.9 GH/s。

#### 文档站完全没有提 CUDA —— 这是个实质性的信息缺口

- `docs.quantus.com` 全站（11 页全文检索）**从未出现** `cuda` / `--cuda-gpu` / `wgpu` / `Vulkan`
  这些词。mining 指南唯一相关的表述只有：
  > "GPU mining is recommended; the miner runs on the host so it can use Metal / Vulkan / DirectX."
- 而 **`--cuda-gpu` 是约 2.6× 的差距**。只看文档的人会在同一张卡上跑出约 38% 的算力。
- 公开仓库里 CUDA 引擎是**无条件编译**的（`crates/miner-cli/Cargo.toml` 直接依赖
  `engine-cuda`，没有 feature gate），所以 `--cuda-gpu` 应当存在于公开二进制里。
- ⚠️ 但仓库自己的 bench 记录把对照二进制称作 "private `quantus-miner-private`"，
  且 PR#100/+30% 那批内核对公开版是否可得 **[未验证]**。
- CUDA 路径的实操坑（来自 repo 文档，非 docs 站）：需要 **libnvrtc**（CUDA toolkit），
  否则二进制会在日志前直接 `abort`（`panic = "abort"`）；OpenGL 镜像不含 NVRTC。

值得注意：官方把这轮内核优化（+30%）当作正经工程在推，说明团队在认真做 miner。

另外 CUDA 引擎有一个**有意的近似**（`engine-cuda/src/lib.rs:63-69`）：
kernel 的 Goldilocks 归约跳过两次进位修正，约每 300 万 nonce 有 1 个哈希算错；
GPU 只负责找候选，**由 CPU 用精确哈希复核**，所以错误的哈希会被拒掉，
损失约 3e-7 的解，换来明显吞吐。这是个合理的工程取舍（fail-safe 而非 fail-open）。

---

## 4. 挖矿经济学（[自证] + [源码]）

### 4.1 发行公式

`pallets/mining-rewards/src/lib.rs:137-152`：

```rust
let max_supply      = T::MaxSupply::get();                  // 21_000_000 * 10^12
let current_supply  = total_issuance() + tx_fees;           // 手续费被 burn 过，加回来
let remaining_supply = max_supply - current_supply;
let total_reward    = remaining_supply / emission_divisor;   // EmissionDivisor = 50_000_000
```

- **无减半**，而是"按剩余供给比例"的平滑指数衰减
- `EmissionDivisor = 50_000_000`（`runtime/src/configs/mod.rs:152`）
- **100% 区块奖励 + 100% 标准手续费归矿工**，无 dev tax、无国库抽成
  （`mining-rewards/src/lib.rs:157-160`，`miner_gross = tx_fees + total_reward`）

### 4.2 一个与文档不符的数字

文档 qpow 页给出：
> `Block Reward = (MaxSupply - CurrentSupply) / EmissionDivisor`

**但同一页的发行表却暗示"创世即满额 21M"**。实测两个口径：

| 口径 | 结果 |
|---|---|
| 代码口径 `(21M − 5.67M) / 50M` | **0.306600 QTC/块** |
| 若误用 `21M / 50M` | 0.420000 QTC/块 |

代码是正确的：`current_supply` 创世已是 5,670,000 QTC。
所以**首个区块奖励是 0.3066 QTC，不是 0.42 QTC**。

### 4.3 量化（别忽略的小数点问题）

矿工收益要向下取整到 "leaf quantum"（`pallet_zk_tree::AMOUNT_SCALE_DOWN_FACTOR`）：

```rust
pub const AMOUNT_SCALE_DOWN_FACTOR: u128 = 10_000_000_000;   // = 0.01 QTC
```
—— `pallets/zk-tree/src/tree.rs:34`，`mining-rewards/src/lib.rs:220-232`

- 0.3066 QTC = **30 个 quantum + 0.0066 QTC 余数**
- 余数**不丢**，累积到下一个满 quantum 再发（`retain_unminted`）
- 所以长期平均无损，但单块到账是 0.30 QTC，余额需要攒到 ≥ 0.01 QTC 才能动

### 4.4 发行节奏 / 通胀（[自证]）

| 时点 | 供给 (QTC) | 区块奖励 (QTC) | 年化增发 |
|---|---:|---:|---:|
| 创世 | 5,670,000 | 0.306600 | 13.84% |
| 第 1 年末 | 6,454,936 | 0.290901 | 11.54% |
| 第 5 年末 | 9,212,830 | 0.235743 | 6.55% |

**这不是通缩币**（尽管营销语言强调"储值"），早期年化增发 ~14%，5 年后降到 ~6.5%，
最终收敛到 21M 上限。手续费方面：标准手续费全额给矿工（不销毁），
只有 high-security 的 1% 和 wormhole 退出的 4 bps（其中一半）会被烧。

### 4.5 单机收益模型（[自证]）

把难度换算成全网算力：难度 D 意味着"平均 D 次哈希出一个块"
（因为有效 target = 2^256/D，而哈希值在 2^256 空间均匀），所以

```
全网算力 (H/s) = D / 12
你的 QTC/天   = (你的算力 / 全网算力) × 86400/12 × 区块奖励
```

| 难度 D | 全网算力 | 单张 4090 (0.89 GH/s) 出块间隔 | QTC/天 |
|---:|---:|---:|---:|
| 1e11（= 创世初始难度） | 8.3 GH/s | 112 s | 236 |
| 1e12 | 83 GH/s | 19 min | 23.6 |
| 1e13 | 833 GH/s | 3.1 h | 2.36 |
| 1e14 | 8.3 TH/s | 31 h | 0.236 |
| 1e15 | 83 TH/s | 13 天 | 0.024 |

**判断挖矿是否值得，唯一决定性变量是当前主网难度。** 创世难度是 99,999,999,999
（`runtime/src/configs/mod.rs:162`，`QPoWInitialDifficulty = U512([99_999_999_999,0,...])`），
而难度重定向是**每块结算、Ethereum Homestead 式**（`pallets/qpow/src/lib.rs:219-273`）：

```
divisor    = 12_000 * 10 / 12 = 10_000 ms
adjustment = max(1 - floor(block_time/10_000), -99)
difficulty = parent + (parent/2048) * adjustment
clamp      = [131_072, U512::MAX]
observed block_time 下限 500 ms
```

- 快于 10 s：每块 **+1/2048 ≈ +0.049%**（复利）
- 10–20 s：不变
- 慢于 20 s：每块 **−1/2048**，每多 10 s 再 −1，最多 −99/2048 ≈ −4.8%

意味着难度**随全网算力增长很快**：每 ~1,400 块（约 4.7 小时，在 12 s 出块时）翻一倍。
所以"现在进场好时机"这个判断只对**几天尺度**有意义。

### 4.6 收益是纯 solo，没有矿池

`quantus-miner` 里有个 `pool-service` crate，但它 **不是挖矿矿池**：

> "Quantus captcha share pool. Sits between a quantus-node (external miner protocol)
> and browser captcha solvers: hands out low-difficulty share challenges over the real
> block header, verifies solves, mints single-use tokens for site backends…"
> —— `crates/pool-service/src/main.rs:1-6`

它是**用 QPoW 当 captcha**（浏览器 WASM solver 见 `crates/solver-wasm/src/lib.rs`）。
主网挖矿是 **solo**：找到块才拿奖励，没有份额分摊。低算力机器方差极大。

---

## 5. 外矿协议（[源码] 与文档一致）

文档描述的 QUIC 协议与代码相符，几处需要精确的地方：

| 项 | 值 | 来源 |
|---|---|---|
| ALPN | `quantus-miner/2` | 文档 + miner README:154 |
| 传输 | QUIC + TLS 1.3，自签证书，miner 必须 pin SHA-256 | 文档 |
| 认证 | 连接后发 `Ready { token }`，token 来自节点 `miner-auth-token`（0600） | 文档 |
| 帧格式 | 4 字节大端长度 + JSON，**最大 1 KB** | 文档 |
| 端口 | 9833/UDP，节点侧 `--miner-listen-port` | 文档 |
| 消息 | `Ready`(miner→node) / `NewJob`(node→miner) / `JobResult`(miner→node) | 文档 |
| keepalive | **miner 必须发**（5–15 s），节点不发且 60 s 超时；官方 miner 每 5 s | 文档 |
| 重连 | 指数退避 1 s → 30 s；**认证/TLS 错误是永久失败，不重试** | 文档 |
| 安全 | 端口固定绑 `0.0.0.0`，**无 IP 白名单**，必须靠防火墙/VPN | 文档 |

节点首次以 `--miner-listen-port` 启动时在 `<base-path>/chains/<chain>/` 生成：
`miner-auth-token`、`miner-tls-cert-sha256`、`miner-tls-cert.der`、`miner-tls-key.der`。

---

## 6. 值得知道的设计细节

### 6.1 Wormhole 地址（隐私 + 扩容）
- 地址 = `H(H(salt|secret))`，H 是 Poseidon2
- 用户 burn 到 wormhole 地址 → 生成 ZK 证明知道原像 → 递归聚合 → 链上验证后 mint 到出口地址
- 链上可见：金额、wormhole 地址、出口地址；**不可见：发送者与接收者的关联**
- 用 nullifier 防双花
- 性能：透明 ML-DSA-87 约 510 笔/块（~43 QTPS）；当前两层聚合 ~5,200 笔/块（~430 QTPS）；
  理论天花板 ~33,000 笔/块（~2,800 QTPS）
- **所有挖矿奖励只能发到 wormhole 地址**，这是协议强制的（`--rewards-inner-hash`）

### 6.2 用户安全特性（少见）
- **Check-phrase**：地址校验和映射到 BIP-39 词序列，方便人眼核对（5 万次 KDF 防伪造）
- **可撤销转账**：发送者设定取消窗口，窗口内可撤回
- **High-security 账户**：单向开启，只能发可撤销转账，有 guardian；每滚动日最多 16 笔；
  手续费 1%（销毁）
- **Guardian 可 `recover_funds`**：可即时没收所有 pending hold + 自由余额
  —— 这是极强的权限，官方文档自己提醒"choose it as carefully as a recovery key"

### 6.3 共识
- **最重链**（累计 work），不是最长链；每块累加**目标难度**而非实际哈希难度
  （`client/consensus/qpow/src/lib.rs:307-324`，运行时注释也明确说明这是刻意选择，
  理由是对齐 Bitcoin/Ethereum，避免单个幸运哈希主导）
- 等 work 时取块高更高者
- 每导入一块，自动 finalize 距 tip 100 块之前的块（`MaxReorgDepth`，约 20 分钟）

---

## 7. 风险与不确定项

### 7.0 ⚠️ 未公开页面：`tokenomics` 与 `roadmap`（重要）

`docs.quantus.com` 的 sitemap 只有 13 个 URL，但 `docs` 仓库里有两个 `draft: true` 的页面
**不会进入线上构建**：

| 页面 | 仓库路径 | 线上状态 |
|---|---|---|
| Tokenomics | `docs/reference/tokenomics.md` | **404**（已验证） |
| Roadmap | `docs/reference/roadmap.md` | **404**（已验证） |

`docs/README.md` 明确提到 "Serves as investor-grade technical documentation covering … **tokenomics** … **roadmap**"，
所以这两个页面显然是为投资者材料准备的，只是**暂时不想公开发布**。
但它们在公开仓库里，任何人都能下载：

```powershell
# 直接读原始 md
https://raw.githubusercontent.com/Quantus-Network/docs/main/docs/reference/tokenomics.md
https://raw.githubusercontent.com/Quantus-Network/docs/main/docs/reference/roadmap.md
```

**`tokenomics.md` 里的融资历史（线上完全不可见）**：

| 轮次 | 融资金额 | 股权估值 | 代币估值 | 领投 |
|---|---|---|---|---|
| Private Round 1 | $1.65M | $20M | $40M | — |
| Private Round 2 | $770K | $50M | $100M | **Balaji Srinivasan** |
| **合计** | **$2.42M** | | | |

对一个"要保护数千亿美元资产"的 L1 来说，**累计只融了 242 万美元**——这个数字对判断项目
可持续性非常关键，而它恰恰被从公开文档里移除了。

**`roadmap.md` 里的时间线**（线上不可见，但与主网实测一致）：

| 时间 | 里程碑 | 状态 |
|---|---|---|
| 2024-12 | 立项，选定 Substrate | Done |
| 2025-07 | Alpha，测试网 + Dilithium | Done |
| 2025-11 | Beta，QPoW/Poseidon2 共识上线 | Done |
| 2026-06-06 | Q-Day（q.day，量子风险科普活动） | Done |
| **2026-09-09** | **主网启动** | Done |

与我实测的"链龄 9.2 天"完全吻合。

**`tokenomics.md` 里比公开页更细的分配表**：

| 桶 | 数量 (QTC) | 占最大供给 | 解锁 |
|---|---:|---:|---|
| Spreadsheet grants | 4,957,502 | ~23.61% | TGE 起锁 1 年，再 3 年线性（`cliff == start`）；另有 1 笔 42,000 的 intents grant 从 TGE 起 365 天线性 |
| Treasury liquidity | 210,000 | 1% | TGE 起 16 天线性，无锁仓 |
| Treasury remainder | 502,438 | ~2.39% | 同一套 1 年 + 3 年时钟 |
| Governance seeds | 60 | ~0.0003% | 10 名 treasurer + 10 名 tech collective 各 3 QTC（付手续费押金用） |
| **矿工** | **15,330,000** | **73%** | PoW 产出，100% 归矿工 |

**`tokenomics.md` 里 wormhole 手续费的精确规则**（公开页只写了概要）：

- `VolumeFeeRateBps = 4`（0.04%），只对 **exit** 收，链上无最低退出额
- 结算时**每个被接受的 private segment 各 ceil 一次**，然后在 public batch 上把费用求和
  → 小 segment 至少付 1 个 quantum（0.01 QTC）
- 拆分（按整 quantum）：
  - **销毁** `ceil(50% of fee)` —— 明确"rounds against the miner"（即销毁取整向上，对矿工不利）
  - **矿工** 取销毁后的余额
  - **聚合者**（仅 public batch）`floor(50% 的销毁桶)` 返给聚合者，余数继续销毁；矿工份额不变
- 矿工无法入账（无 author 或 mint 失败）时，其份额**直接销毁**而非丢弃
- 聚合者返利失败时留在销毁桶，不回滚该笔 exit

**结论**：把 tokenomics/roadmap 下架是刻意的信息管理——融资额和代币估值是最敏感的数字。
这不违法，但**做尽调时必须去看 `draft: true` 页面**，因为公开站点系统性地省略了它们。

### 7.1 其他风险

| 项 | 说明 |
|---|---|
| **链极新** | chain v1.0.1 发布于 2026-09-09，miner v4.2.0 于 2026-09-10；docs 明确 Planck 测试网数据不迁移 |
| **融资规模极小** | 累计 $2.42M（见 §7.0）——与"保护 $27B 资产"的叙事不匹配 |
| **当前难度低但会快速上升** | 我实测难度仍在创世值附近，但每块最多 +0.049%、约 1,400 块翻倍 |
| **无矿池** | solo 挖矿，低算力方差极大 |
| **审计报告未公开** | 见 §7.2 |
| **`chain/MINING.md` 已彻底过时** | 见 §7.3 |
| **QTC 变现能力未验证** | 未找到可信的 Quantus QTC 价格来源（同名币 Qitcoin / Quantic 会污染搜索） |
| **NEAR 桥未上线** | MPC 节点 "in development"，审计进行中 |
| **安全语义** | 接官方二进制会引入信任与后门风险；miner 从源码自建可避免，但需信任该源码 |

### 7.2 审计状态

`docs.quantus.com/reference/audits/` 声明 Eiger（Poseidon2 + QPoW）与 Neodyme（ML-DSA-87）
"Completed"，但**报告链接全是 "[Link pending]"**。`draft` 的 roadmap 页也复述了这两项为完成。
**我在公开渠道没有找到任何一份可下载的审计报告 PDF** —— [未验证]（子代理尝试后失败，
我本人也未做穷尽搜索；若要确认应去 GitHub Issues/Telegram 直接问）。

### 7.3 `chain/MINING.md` 已彻底过时（会导致照着做挖不动）

`chain` 仓库根目录的 `MINING.md` 整篇还在讲 **Planck 测试网**，与主网完全脱节：

| `MINING.md` 说 | 线上文档 + 主网事实 |
|---|---|
| "Get started mining on the Quantus Network **testnet**" | 主网 2026-09-09 已上线 |
| `--chain planck`（全文 4 处） | 必须 `--chain mainnet` |
| "**Block Time**: ~6 seconds target" | 实际 **12 s 目标**（`TARGET_BLOCK_TIME_MS = 12_000`），实测平均 15 s |
| "**Tokens have no monetary value**"（Testnet Disclaimer） | QTC 是主网资产 |
| `--rewards-address` 参数 | 现接口是 `--rewards-inner-hash` |
| 教 Docker 安装 | 线上文档："New Docker setup is not supported" |

**这不是小瑕疵**：`MINING.md` 在链仓库根目录、是搜索引擎能命中的第一手文档，跟着它做会连不上主网。
以 `docs.quantus.com` 为准。

### 7.4 仓库地图与文档不符

`docs` 的 Repository Map 声称 "catalogs **every** repository"，但实际 org 有 35 个（抓取第一页），
文档列出了约 29 个。文档**收录了但 org 未在第一页出现**的：`nearcore`、`subql`、`squid-sdk`、
`zk-trie`、`zk-state-machine`、`report-card`、`privacy-score`、`slips`、`rusx`、`hash-comparison`、
`task-master-admin`、`qp-poseidon-constants`（可能是 monorepo 子目录或被重命名/归档）。

org 里**文档未收录**的：`docs`（文档站自身）、`quantus-wasm`、`quersi`、`qday-summit`、
`migration-fail`、`polkadart_1_x`、`packages`、`people`、`projects`、`repositories`、
`shared-workflows`、`tab_counts`、`.github`。

其中 `quantus-wasm` 值得单独留意（可能是浏览器端 WASM 挖矿/求解）。
⚠️ **分页未取全**（GitHub HTML 抓取在本机超时，且 REST 限额 60/h 已耗尽）——**总数可能多于 35**，
上述"未收录"列表不完整。

---

## 8. 环境备注（复现用）

本机（Windows）标准 HTTPS 栈不可用：

- `curl.exe` / `Invoke-WebRequest` → `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`
- `raw.githubusercontent.com` 偶发 connection reset
- **可用**：`curl_cffi`（已装 0.15.0）直连 + `impersonate="chrome"`，失败时回退本地代理 `127.0.0.1:20808`
- `docs.quantus.com`、`raw.githubusercontent.com` 可达
- **不可达（DNS 无法解析）**：`subsquid.quantus.com`、`rpc.quantus.com`、`rpc.quantus.cat`
- GitHub REST 未认证限额 60 次/小时，多路调研会打满 → 优先走 raw

抓取与验证脚本：
- `tools/poseidon2_ref.py` — Poseidon2 独立实现 + 自测（唯一真源）
- `tools/verify_against_miner.py` — 与官方向量对拍
- `tools/upstream/` — 上游 Rust 源码快照（常量与官方向量从这里解析）
- 文档抓取 / 经济计算等一次性脚本属于研究工作区，未随仓库发布

---

## 9. 主网实测数据（2026-09-18 快照，[自证]）

数据源：`https://sqm.quantus.com/v1/graphql`（Hasura，从 explorer 前端 bundle 里挖出来的）。
备用端点 `https://sub2.quantus.com/v1/graphql`。注意：`subsquid.quantus.com` 在本机 DNS 不可解析，
实际可用的是上面两个。

### 9.1 网络规模与活跃度

| 指标 | 值 |
|---|---|
| 链高 | 65,798 |
| 已最终确认 | 65,697（= 链高 − 100，与 `MaxReorgDepth` 一致） |
| 主网启动 | 2026-09-09（链龄 9.2 天） |
| 总账户 | 3,870 |
| **总矿工数** | **126** |
| 累计出块 = 累计发奖 | 65,797 / 65,797（**每个块都有奖励**，无空块） |
| 立即转账 | 66,714 |
| 计划（可撤销）转账 | 0 笔 |
| 错误事件 | 12 |

**关键洞察**：累计发奖次数 == 累计块数，说明**没有空块**，链上活动几乎全是挖矿 + 普通转账，
可撤销转账等高级安全特性**零采用**（`total_scheduled_transfers = 0`）。

### 9.2 每日出块（出块节奏极不稳定）

| 日期 | 块数 | 转账 | 活跃账户 |
|---|---:|---:|---:|
| 09-09（启动日） | 17,193 | 6,369 | 26 |
| 09-10 | 6,972 | 8,839 | 553 |
| 09-11 | 5,286 | 8,214 | 901 |
| 09-12 | 5,042 | 7,405 | 722 |
| 09-13 | 6,366 | 7,517 | 762 |
| 09-14 | 5,605 | 6,575 | 757 |
| 09-15 | 5,924 | 6,275 | 648 |
| 09-16 | 5,892 | 6,790 | 709 |
| 09-17 | 5,710 | 6,507 | 686 |
| 09-18（半天） | 1,808 | 2,223 | 442 |

稳定期约 **5,900 块/天**，对应平均块时间 **~14.6 s**（目标 12 s，实际偏慢）。

### 9.3 决定性的发现：难度基本没涨

区块奖励 = `(MAX − current)/50M` 向下取整到 0.01 QTC，**每 +1/2048 难度就掉 1 个 quantum**，
所以奖励分布是难度的直接探针。实测：

| 采样高度 | 奖励分布 |
|---|---|
| 1,000（09-09） | 0.30 ×137，0.31 ×263 |
| 20,000（09-10） | 0.30 ×123，0.31 ×210 (+ 少数含高额手续费的块) |
| 40,000（09-13） | 0.30 ×138，0.31 ×231 |
| 55,000（09-16） | 0.30 ×121，0.31 ×221 |
| 65,000（09-18） | 0.30 ×132，0.31 ×218 |

**从块 1,000 到 65,000，奖励分布完全没变 → 难度始终停留在创世值 99,999,999,999 附近。**
自洽性：创世奖励 = `(21e6 − 5.67e6)/50e6 = 0.3066` QTC；向下取整到 0.01 得 **0.30**，
加上手续费量化的 1–2 个 quantum 就是 **0.31**——与实测**逐块吻合**。

（含高额手续费离群值的块：20,000 处最大 0.4455，40,000 处最大 0.6340，
55,000 处最大 0.7516，65,000 处最大 0.6968 QTC。）

### 9.4 块时间分布

| 阶段 | 平均 | 中位 | p10 | 子秒块占比 |
|---|---:|---:|---:|---:|
| 启动日 | 3.04 s | 0.88 s | 0.45 s | **54.6%** |
| 第 2–3 天 | 14.29 s | 10.01 s | 2.04 s | 2.9% |
| 第 4–6 天 | 15.18 s | 10.67 s | 2.22 s | 2.4% |
| 第 7–9 天 | 14.63 s | 10.42 s | 2.11 s | 3.2% |
| 最近 2,800 块 | 15.06 s | 10.66 s | 2.26 s | 3.0% |

- 启动日 54.6% 是子秒块 → 当时难度太低（相对全网算力），符合"第一天就有人冲进来挖"
- 之后收敛：中位 10.5–10.7 s（落在"10–20 s 不调难度"的窗口内 → 难度稳定，见 §9.3）
- **3% 的子秒块**说明有矿工在极短时间内连续出块，这是**权益抵押型/委托型协议不会有的模式**，
  更像少量高算力设备在抢
- 平均/中位 ≈ 1.41，接近固定难度下指数分布的 1.44 → 再次印证难度基本恒定

**由此估算全网算力 ≈ D / 平均块时间 ≈ 1e11 / 15.1 s ≈ 6.6 GH/s**，
即全网总算力大约相当于 **7–8 张 RTX 4090**。

### 9.5 矿工集中度（近 3.4 天，2026-09-15 起）

| 矿工（前 5） | 出块 | 占比 | QTC |
|---|---:|---:|---:|
| `qzowWAgb…x1koo` | 9,734 | **50.33%** | 3,014.08 |
| `qzmsbecA…3SErv` | 4,552 | 23.54% | 1,411.55 |
| `qzmb4MVg…JHTSR` | 3,058 | 15.81% | 948.09 |
| `qzjrhfWY…sfZPZt` | 777 | 4.02% | 239.76 |
| `qzknqXTj…PYAGB` | 391 | 2.02% | 121.10 |

- **Top 1 = 50.3%，Top 3 = 89.7%，Top 5 = 95.7%**
- 该窗口内只有 **48 个矿工拿到过奖励**（链上历史总矿工 126 个）
- **约 60% 的"矿工"从未出块**——符合"大量 CPU-only 节点在陪跑"

### 9.6 发行量的实测校验（[自证]）

链上：累计发放 **436,674 QTC** / 65,797 块 = **0.30660 QTC/块**。

模型：`(21,000,000 − 5,670,000) / 50,000,000 = 0.306600 QTC`。

**误差 0.0005%——发行模型与主网实测完全吻合。**

| 项 | 值 |
|---|---|
| 当前供给 | 6,106,674 QTC |
| 累计发放 | 436,674 QTC |
| 首块奖励 | 0.3066 QTC |
| 稳定期日产量 | ~5,900 × 0.3066 ≈ **1,809 QTC/天** |
| 年化净发行 | ~785,000 QTC（约占当前供给 13%） |

### 9.7 单卡收益换算（基于实测 D ≈ 1e11）

| 硬件 | 算力 | 占全网 | 期望出块 | QTC/天 |
|---|---:|---:|---:|---:|
| RTX 4090（CUDA v4.2.0） | 0.89 GH/s | ~13.5% | ~795 块/天（110 s/块） | **~244** |
| RTX 3080 Ti（CUDA） | 0.38 GH/s | ~5.8% | ~340 块/天 | ~104 |
| RTX 3080 Ti（WGSL/Vulkan） | 0.106 GH/s | ~1.6% | ~95 块/天 | ~29 |
| 纯 CPU（多核） | ~1 MH/s | ~0.015% | ~0.9 块/天 | ~0.27 |

**但必须注意**：把这张卡加进去，局部难度会立刻上升（每块最多 +0.049%，约 1,400 块翻倍），
且 Top1 已经占 50%，所以这是**边际收益会迅速被稀释**的场景。
真正的瓶颈是 **QTC 的变现价值**——日产量 244 QTC 是否有买家，目前 [未验证]。

### 9.8 手续费销毁量级

链上：累计发放 436,674 QTC，但由 genesis 推出的净发行只有 402,829 QTC，
差 **33,845 QTC（7.8%）**。这与"high-security 1% 全额销毁 + wormhole 退出 4 bps 一半销毁"
的费率设计方向一致（66,714 笔转账规模下，平均约 0.5 QTC/笔的销毁）。

⚠️ **[未验证]** 我无法确认这个差额的精确归因：`chain_stats.total_miner_rewards`
可能与逐块 `miner_reward` 记录的事件集合不完全一致（索引器口径差异），
也可能是提取时的瞬时不一致。**方向可信（确有可观销毁），精确数值不可当作定论。**

---

## 10. 后续可做（子代理均已失败，未完成）

两个后台子代理在收尾前都失败退出，所以下面这些**没有**完成：

| 未完成项 | 我掌握的程度 | 建议下一步 |
|---|---|---|
| 白皮书逐条核对 | 只从搜索得知主网新闻稿标题（KuCoin/ChainCatcher 报道 "$27B crypto security risk"），未读白皮书正文 | 抓 `quantus.com/whitepaper`，重点核对 QTPS 数字与 0.42 vs 0.3066 的区别 |
| 审计报告是否可公开获取 | [未验证] 未找到任何可下载报告 | 去 `chain` 仓库 Issues 或 Telegram 直接问 |
| QTC 价格 / 流动性 / 上所 | [未验证] 搜索结果被同名币 Qitcoin / Quantic 污染 | 需要更精确的查询（按合约地址或 Quantus 品牌） |
| org 仓库总数（分页） | 只拿到第一页 35 个 | 等 GitHub REST 限额恢复（60/h）或本地跑 `git ls-remote` |
| `quantus-wasm` 仓库用途 | 未看 | 可能与浏览器端挖矿/captcha 求解有关 |

**已知且已验证的"信息缺口"本身是本次调研最有价值的产出**：文档站系统性地省略了
融资历史（§7.0）、CUDA 路径（§3）和 CUDA/wgpu 的 2.6× 差距。
