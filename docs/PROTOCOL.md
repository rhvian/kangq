# Kryptex Quantus 矿池协议规格

> 状态：**已完全实测确认**，且已用**第三方闭源矿工（fl4shminer）的真实抓包**逐字段验证。
> 证据来源有两类，互相独立：
>   A. 自行探测（研究工作区的 `probe_*.py`，未随仓库发布）——先摸出 `login` / `submit` 方言
>   B. **对已实现矿工 fl4shminer 的 TCP 中间人抓包**
>      ——给出权威字段表，并修正了我最初实现的遗漏

## 0. 一句话总结

Kryptex 的 Quantus 池**不是**官方 QUIC 协议、**不是**标准 Stratum（`mining.subscribe`），
而是一套轻量 JSON-RPC 方言：**`login` 登录 + `submit` 提交**，明文 TCP 行分隔 JSON。

## 0.1 权威报文（fl4shminer 抓包实录）

**登录**（注意 `agent` 字段，以及 `wallet.worker` 形式）：

```json
{"id":1,"method":"login","params":{"agent":"Fl4shMiner/1.4.3",
  "login":"<wallet>.qzprobe","pass":"x"}}
```

**登录响应**（session id + 内联首个 job）：

```json
{"id":1,"error":null,"result":{
  "extensions":["keepalive"],
  "id":"063f5e47-3235-4b15-bb00-31eb1911c580",
  "status":"OK",
  "job":{"difficulty":18253611008,"extranonce":"3a37e843",
         "job_id":"86334eee_18253611008",
         "mining_hash":"d8227906b63edc2a5b8b0600bd8c181b01651aec3a6d834ac2be76226a4bf859",
         "target":"000000003c3c3c3c…"}}}
```

**新 job 推送**（JSON-RPC 通知，`clean_jobs:true` 表示旧 job 作废）：

```json
{"jsonrpc":"2.0","method":"job","params":{"clean_jobs":true,"job":{…}}}
```

**提交 share**（**三个必填字段，我最初全漏了**）：

```json
{"id":2,"method":"submit","params":{
  "id":"063f5e47-3235-4b15-bb00-31eb1911c580",
  "job_id":"f5f6dbc4_18253611008",
  "nonce":"3a37e84319fccd5bb52b5d29791aa17bb2b917455e0afd1eb6ce19e0fe17703ff44abd8273815b741f8e8887c907f27d0cb5427d8d7ea48be171777837f80d82",
  "result":"0000000021efcce455e473dc7d64315ec1c99d7c4d4cf0e3ad8494f11709b01b807a96560fb1797a8a0a5d5edc79f71bfd6c7d50ac511c4474688e0193a2b671"}}
```

| 字段 | 含义 | 我最初的实现 |
|---|---|---|
| `id` | 登录返回的 **session UUID** | ❌ 漏了 |
| `job_id` | 当前 job id | ✅ |
| `nonce` | 64 字节 hex（128 字符） | ✅ 但布局错 |
| `result` | 完整 64 字节摘要 hex（128 字符） | ❌ 漏了 |

**nonce 布局（关键）**：前 4 字节就是 job 里的 `extranonce`。

```
nonce = 3a37e843 19fccd5b b52b5d29 791aa17b …
        └extranonce┘ └──── 矿工自选/计数器 ────┘
```

`nonce` 与对应 `result` 都取自 fl4shminer 成功提交的那一条。

## 0.2 提交的响应语义（**实测，含一个曾掩盖成功的坑**）

| 情形 | 矿池响应 |
|---|---|
| **接受** | `{"id":2,"error":null,"result":{"status":"OK"}}` |
| job 已过期 | `{"id":2,"error":{"code":-1,"message":"Stale share"},"result":null}` |
| job_id 不存在 | `{"id":2,"error":{"code":-1,"message":"Invalid job id"},"result":null}` |
| nonce 不达标 | `{"id":2,"error":{"code":-1,"message":"Invalid nonce"},"result":null}` |

**两个曾把我误导很久的坑：**

1. **接受不是 `result:true`**，而是 `result.status == "OK"`。
   只认 `result:true` 的解析器会把成功误判成"矿池没响应"。
2. **"Stale share" ≠ "份额无效"**。它说明 nonce 是**有效且达标**的，
   只是提交时那个 job 已被新块替换 —— 这其实是"矿工算对了"的强证据。

**由此得出的实现要求**：提交前必须确认 job 未变，否则必然吃 Stale share。
矿池推送新 job 的间隔实测只有数秒，单轮扫描时长必须显著小于它。

## 0.3 完成状态

| 环节 | 状态 | 证据 |
|---|---|---|
| login 握手（含 agent） | ✅ 实测 | 抓包 + 实跑 |
| job 接收与轮转 | ✅ 实测 | 实跑 |
| QPoW 哈希正确性 | ✅ 自证 | 与官方 `NONCE_HASH_KVS` 对拍 **38/38** |
| 难度→target 换算 | ✅ 自证 | `U512(hash) < U512::MAX/D` ≡ 高 256 位比较 |
| 提交字段（id/nonce/result） | ✅ 抓包确认 | §0.1 |
| **提交被矿池接受** | ✅ **实测** | `result.status="OK"`，见 §0.2；每个版本发布前都实测一次 |
| GPU 速率 | **~920 MH/s** | 单张 4090，KanQ 1.2；官方开源 CUDA 862–886 |

## 0.4 性能现实（同一张 4090）

| 实现 | 速率 | 备注 |
|---|---|---|
| fl4shminer 1.4.3 | **1.22 GH/s** | 闭源内核级优化 |
| KanQ 1.2 | **~920 MH/s** | prestate + 惰性归约 + 小幅展开，见 `PERFORMANCE.md` |
| KanQ 1.1 | ~900 MH/s | prestate + 惰性归约 |
| KanQ 1.0 | 75.6 MH/s | 协议正确、内核朴素 |

share 难度 18,253,611,008 → 920 MH/s 下期望约 **20 秒一个 share**。

性能教训（1.0 → 1.1 的量化归因）见 `PERFORMANCE.md §1`；另有一条运维实测：
**同一张卡不要跑两个矿工实例**（速率腰斩、功耗从 255W 掉到 119W）。

## 1. 传输层

| 项 | 值 |
|---|---|
| 明文端点 | `qtc.kryptex.network:7049`（TCP，**不是** TLS） |
| TLS 端点 | `qtc.kryptex.network:8049` |
| 区域节点 | `qtc-{eu,us,br,sg,hk,ru,ae}.kryptex.network` 同端口 |
| 帧格式 | **按行分隔的 JSON**（`\n` 结尾），非长度前缀 |
| TLS 证书 | 自签，DER SHA-256 = `0fa7a4c1…`，**所有区域节点一致** |
| ALPN | 不协商（实测 `selected_alpn=None`） |

## 2. 已明确排除的协议（都实测过）

| 假设 | 结果 |
|---|---|
| 官方 Quantus QUIC 协议（ALPN `quantus-miner/2`，UDP） | **排除**。UDP 打 7049/8049/9834 全失败，而对照组 `cloudflare-quic.com:443` 用 h3 握手成功 → 本机 UDP 正常 |
| 标准 Stratum `mining.subscribe` | **排除**。命名参数/数组/合并单行/大写变体全部静默无响应 |
| `mining.authorize` | **排除**。同上 |
| 官方 `Ready{token}` 帧（长度前缀） | **排除**。TLS 上发送后静默 |
| HTTP / WebSocket 升级 | **排除**。8049 上发 `GET /` 立即被关闭 |
| `getwork` / 裸钱包串 | **排除**。无响应 / 直接关闭 |

## 3. 握手（**已确认可用**）

客户端发送：

```json
{"id":1,"method":"login","params":{"login":"<wallet>","pass":"x"}}
```

服务端响应（单行 JSON）：

```json
{"id":1,"error":null,"result":{
  "extensions":["keepalive"],
  "id":"7bfb3fe8-993c-40d2-a20e-2a3f56c27c7e",
  "status":"OK",
  "job":{
    "difficulty":18253611008,
    "extranonce":"3a36f49e",
    "job_id":"e4fa65ab_18253611008",
    "mining_hash":"1d104e63552591f9f1415812eef65f4b4e2b645a5eb971dac21a070a24b374fb",
    "target":"000000003c3c3c3c3c3c…3c3c"
  }}}
```

要点：
- `params` 是**对象**（命名参数），键名 `login` / `pass`
- 键名 `login` 而非 `user`/`wallet`（实测 `worker` 键被忽略，但加了也不报错）
- 响应里同时带 `id`（session UUID）和 `status:"OK"`
- `extensions:["keepalive"]` → 支持 `mining.ping`

## 4. Job 字段语义

| 字段 | 示例 | 语义 |
|---|---|---|
| `difficulty` | `18253611008` | **share 难度**（不是网络难度）。share target = `U512::MAX / difficulty` |
| `extranonce` | `3a36f49e` | 4 字节 hex，**每连接不同**（两次连接分别 `3a36f49e` / `3a36d5ec`） |
| `job_id` | `e4fa65ab_18253611008` | `<8hex>_<difficulty>` |
| `mining_hash` | `1d104e63…b374fb` | **32 字节 hex = QPoW 的 pre-seal header hash** |
| `target` | `000000003c3c…` | 疑似**占位符**（`0x3c` 重复），与 `U512::MAX/difficulty` 不符 —— 见 §7 |

### 难度交叉验证（[自证]）

`difficulty = 18,253,611,008`，而 `2^256 / 18,253,611,008 = 6.34e66 = 0x3c3c3c3c…`
→ **`0x3c` 重复正是 `2^256 / difficulty` 的形态**，所以 `target` 字段与 difficulty 是自洽的
（我先前误判为占位符）。share 判定仍建议直接用 `difficulty` 算 `U512::MAX / difficulty`。

与主网对照：主网块难度约 `1e11`，矿池 share 难度 `1.83e10`，即 **share ≈ 0.18 个块**——
合理（矿池 share 通常远低于网络难度）。

## 5. 服务端主动推送新 job

```json
{"jsonrpc":"2.0","method":"job","params":{"clean_jobs":true,"job":{…}}}
```

- 是 **JSON-RPC 2.0 通知**（无 `id`）
- `clean_jobs:true` → 旧 job 立即作废，矿工应重开 nonce
- 实测推送频率：连接后约数秒一个（主网出块快）。同一 `extranonce` 会话内不变

## 6. 从 job 到哈希（QPoW 部分，[自证]）

已知 `mining_hash` 即 `pre_seal_header_hash`，所以：

```
input   = mining_hash (32B) || nonce (64B 大端)      # 96B
digest  = Poseidon2_squeeze_twice(input)             # 64B
hi      = digest[:32]                                # 大端 → U512 高位
valid   = U512(digest) < U512::MAX / difficulty
        ≡ hi < (2^256 - 1) / difficulty              # 已实测等价，D ≤ 2^256
```

我已用独立 Python 实现复现该哈希，与**官方 miner 的硬编码向量**对拍 10/10 通过
（`tools/verify_against_miner.py`）。另有 20% 的加速空间：官方 miner 会缓存 midstate
跳过前 2/5 次 permutation，并在第一段 squeeze 不达标时跳过第二段。

## 7. Share 提交（**已确认**）

方法名是 **`submit`**（**没有** `mining.` 前缀 —— 这正是最初探测失败的原因）：

```json
{"id":2,"method":"submit","params":{"login":"<wallet>","job_id":"<当前 job 的 job_id>","nonce":"<64 字节 hex，128 字符，无 0x>"}}
```

响应（正确 job_id + 无效解）：

```json
{"id":2,"error":{"code":-1,"message":"Invalid nonce"},"result":null}
```

响应（job_id 不对）：

```json
{"id":2,"error":{"code":-1,"message":"Invalid job id"},"result":null}
```

### 错误语义（实测确立，这是协议自描述的关键）

| 情形 | 错误消息 |
|---|---|
| `job_id` 不是当前 job | `Invalid job id` |
| `job_id` 正确但 nonce 解不出达标哈希 | `Invalid nonce` |
| 方法名带 `mining.` 前缀 | **静默丢弃**（无任何响应） |

注意：`Invalid nonce` 是**哈希校验**而非格式校验——我用 128 字符合法 hex、错长度、
非 hex、带 `0x` 前缀等 11 种输入测过，**全部返回同一条 `Invalid nonce`**。
所以矿池的校验流程是：查 job → 用 `mining_hash || nonce` 算 QPoW → 与
`U512::MAX/difficulty` 比较。

## 8. 从 job 到哈希（QPoW 部分，[自证]）

已知 `mining_hash` 即 `pre_seal_header_hash`，所以：

```
input   = mining_hash (32B) || nonce (64B 大端)      # 96B
digest  = Poseidon2_squeeze_twice(input)             # 64B
valid   = U512::from_big_endian(digest) < U512::MAX / difficulty
        ≡ digest[:32] < (2^256 - 1) / difficulty     # 已实测等价，D ≤ 2^256
```

我已用独立 Python 实现复现该哈希，与**官方 miner 的硬编码向量**对拍 10/10 通过
（`tools/verify_against_miner.py`）。

### nonce 的位宽与搜索策略（读官方 CUDA 内核得到）

`crates/engine-cuda/src/kernels/mining.cu:476-491`：

```cuda
u64 nonce_base_low = ((u64)params.start_nonce[1] << 32) | (u64)params.start_nonce[0];
u64 nonce_low = nonce_base_low + (u64)logical_index;
```

- nonce 是 **512 bit（64 字节）**，提交时是 **128 字符小写 hex，不带 `0x`**
- 官方内核**每批只递增低 64 位**，高 448 位固定为 `start_nonce` 的高位
  → 说明高 448 位可以随便取（不同矿工取不同值即可避免重复劳动）
- 内核在 `mining_main` 里只算**第一段 squeeze**（`first[8]` 8 个 u32 = 256 bit），
  与 `params.difficulty_target[8..16]` 做**大端逐字节比较**；不达标直接 `continue`，
  **跳过第二段 squeeze**（这就是 commit #100 "no third squeeze on the GPU" 的含义）。

**性能要点**：内核注释明确说明 Goldilocks 归约**故意不做完整进位修正**，
约每 300 万 nonce 有 1 个哈希算错；GPU 只负责**找候选**，由 **CPU 用精确哈希复核**。
所以自建实现必须保留"GPU 找候选 + CPU 复核"这个结构，否则会提交错误 share。

## 9. 为什么要自己做哈希（而不是复用官方 miner）

官方 `quantus-miner` 的传输层是 **QUIC 客户端**（`crates/quic-transport/src/lib.rs:82-99`）：
`quinn` + ALPN `quantus-miner/2` + **证书指纹 pin**（自签证书，无 CA 可校验）。
Kryptex 是明文 TCP + 行分隔 JSON Stratum 方言，**两者不可互通**。

`quic-transport` 只省了两件事：`Ready{token}` 帧与证书 pin。
Kryptex 不需要 token（用 `login` 里的钱包地址），所以**传输层必须自写**，
但 **PoW 内核可直接复用** `mining.cu`（19.5 KB 单文件、自包含）。

## 10. 复现

协议探针脚本（`probe_*.py`）属于研究工作区，不随本仓库发布；本文件 §0.1 的权威报文与 §4 的错误语义即为可直接对照的规格。要复核握手，直接跑 `./kanq --wallet <addr> --once`，日志会打印 login 响应、job 推送与 submit 结果。

## 11. 参考：其它 Quantus 矿池的传输差异

来自 PeakMiner README（非我实测）：

| 矿池 | 端点 | 传输 |
|---|---|---|
| Kryptex | `stratum+tcp://qtc.kryptex.network:7049` | Stratum（本文件即其真实方言） |
| QuanPool | `quic-insecure://mine.quanpool.com:9834` | QUIC，**不校验证书** |
| LuckyPool | `eu.lproute.com:3361` | 自动探测 |

`quic-insecure://` 的存在很重要：它说明**官方 QUIC 协议去掉证书 pin 后就是矿池协议**，
所以接 QuanPool 可以直接复用官方 `crates/quic-transport`，只把 `PinnedCertVerifier`
换成接受任意证书；接 Kryptex 则必须写本文档描述的那套 Stratum 方言。

## 12. 仍未确认

1. **`extranonce` 的确切用途**：job 里给的 4 字节 `3a36f49e` 每连接不同。
   官方内核只在批内递增低 64 位，未使用 extranonce；矿池可能把它作为
   nonce 高位的初始值，或仅用于服务端统计。**不影响能否提交成功**——
   提交任意 64 字节 nonce，只要哈希达标即可（矿池会自行复核）。
2. **是否需要单独上报 worker 名**：`login` 的 `worker` 键实测被忽略；
   可能要用 `login` 字段的 `wallet.worker` 形式（Kryptex 页面写的是 `wallet/worker`）。
3. **`mining.ping` 格式**：`extensions:["keepalive"]` 表明支持，但我发的
   `{"method":"mining.ping","params":[]}` 无响应（可能方法名不同，或本就无需回应）。
