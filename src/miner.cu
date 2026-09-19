// KanQ —— 对接 Kryptex Quantus (QTC) 矿池的 GPU 矿工主程序。
//
// 协议（完整规格见 docs/PROTOCOL.md，全部为实测逆向 + 第三方矿工抓包确认）：
//   连接   TCP 明文，行分隔 JSON（'\n' 结尾）
//   登录   {"id":1,"method":"login","params":{"agent":"...","login":"<wallet>.<worker>","pass":"x"}}
//   响应   {"id":1,"error":null,"result":{"extensions":["keepalive"],"id":"<session>","status":"OK","job":{...}}}
//   推送   {"jsonrpc":"2.0","method":"job","params":{"clean_jobs":true,"job":{...}}}
//   提交   {"id":N,"method":"submit","params":{"id":"<session>","job_id":"<id>","nonce":"<128hex>","result":"<128hex>"}}
//   接受   {"id":N,"error":null,"result":{"status":"OK"}}
//   拒绝   {"id":N,"error":{"code":-1,"message":"Invalid nonce" | "Stale share" | ...},"result":null}
//
// 关键：submit 的方法名是 `submit`，**没有** `mining.` 前缀；带前缀会被矿池静默丢弃。
//
// 计算结构：主机每个 job 算一次 prestate（header + nonce[0:56] 吸收完毕 + 第 3 次置换的
// 初始线性层），GPU 每个 nonce 只跑 2 次置换找候选；**每个候选都由主机精确复核**（GPU 用惰性
// 归约，约 3e-7 的哈希会算错）后才提交。
//
// nonce 布局：
//   nonce[0:4]   = extranonce（矿池下发，抓包确认必须）
//   nonce[4:12]  = 本进程随机 salt（多实例/多次运行不重复扫描）
//   nonce[12:56] = 0
//   nonce[56:64] = 大端 u64 索引（GPU 扫描变量）
//
// 构建：./build.sh（或 nvcc -O3 -arch=sm_89 -std=c++17 -o kanq src/miner.cu -lpthread）

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <chrono>
#include <thread>
#include <mutex>
#include <random>
#include <stdexcept>

#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#include "version.h"
#include "qpow.cuh"
#include "qpow_host.h"

using namespace qpow;

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

static bool hex_to_bytes(const std::string &s, uint8_t *out, size_t n) {
    if (s.size() != n * 2) return false;
    for (size_t i = 0; i < n; i++) {
        auto hv = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        };
        int hi = hv(s[i * 2]), lo = hv(s[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}

static std::string bytes_to_hex(const uint8_t *b, size_t n) {
    static const char *H = "0123456789abcdef";
    std::string s;
    s.reserve(n * 2);
    for (size_t i = 0; i < n; i++) { s.push_back(H[b[i] >> 4]); s.push_back(H[b[i] & 0xf]); }
    return s;
}

// 从 JSON 文本抓 `"key":"value"` 或 `"key":123`
static bool json_str(const std::string &s, const std::string &key, std::string &out) {
    std::string pat = "\"" + key + "\"";
    size_t p = s.find(pat);
    if (p == std::string::npos) return false;
    p = s.find(':', p + pat.size());
    if (p == std::string::npos) return false;
    p++;
    while (p < s.size() && (s[p] == ' ' || s[p] == '\t')) p++;
    if (p >= s.size()) return false;
    if (s[p] == '"') {
        size_t e = s.find('"', p + 1);
        if (e == std::string::npos) return false;
        out = s.substr(p + 1, e - p - 1);
        return true;
    }
    size_t e = p;
    while (e < s.size() && s[e] != ',' && s[e] != '}' && s[e] != ']' && s[e] != ' ') e++;
    out = s.substr(p, e - p);
    return !out.empty();
}

static unsigned __int128 parse_u128(const std::string &dec) {
    unsigned __int128 v = 0;
    for (char c : dec) if (c >= '0' && c <= '9') v = v * 10 + (unsigned)(c - '0');
    return v;
}

#define CUDA_CHECK(x)                                                                    \
    do {                                                                                  \
        cudaError_t e_ = (x);                                                             \
        if (e_ != cudaSuccess)                                                            \
            throw std::runtime_error(std::string("CUDA: ") + cudaGetErrorString(e_) +    \
                                     " @" __FILE__ ":" + std::to_string(__LINE__));       \
    } while (0)

// ---------------------------------------------------------------------------
// 矿池客户端
// ---------------------------------------------------------------------------

struct Job {
    std::string job_id, mining_hash, difficulty, extranonce;
    bool valid = false;
};

class Pool {
public:
    bool connect_to(const std::string &hostport) {
        auto pos = hostport.rfind(':');
        std::string host = hostport.substr(0, pos);
        std::string port = hostport.substr(pos + 1);
        struct addrinfo hints{}, *res = nullptr;
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0) {
            fprintf(stderr, "DNS 解析失败: %s\n", host.c_str());
            return false;
        }
        for (auto *p = res; p; p = p->ai_next) {
            int fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
            if (fd < 0) continue;
            if (::connect(fd, p->ai_addr, p->ai_addrlen) == 0) { fd_ = fd; break; }
            close(fd);
        }
        freeaddrinfo(res);
        if (fd_ < 0) { fprintf(stderr, "连接失败: %s\n", hostport.c_str()); return false; }
        int one = 1;
        setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        printf("已连接 %s\n", hostport.c_str());
        return true;
    }

    void login(const std::string &wallet, const std::string &worker) {
        std::string user = worker.empty() ? wallet : wallet + "." + worker;
        send("{\"id\":" + std::to_string(++id_) +
             ",\"method\":\"login\",\"params\":{\"agent\":\"" KANQ_AGENT "\",\"login\":\"" +
             user + "\",\"pass\":\"x\"}}");
    }

    void submit(const std::string &job_id, const std::string &nonce_hex, const std::string &result_hex) {
        send("{\"id\":" + std::to_string(++id_) + ",\"method\":\"submit\",\"params\":{" +
             std::string("\"id\":\"") + session_ + "\"," +
             "\"job_id\":\"" + job_id + "\"," +
             "\"nonce\":\"" + nonce_hex + "\"," +
             "\"result\":\"" + result_hex + "\"}}");
        submitted_++;
    }

    // 非阻塞地读走所有可读数据并处理。内核一轮只有几十毫秒，这里绝不能阻塞
    // （早期版本用 300 ms 的 SO_RCVTIMEO 阻塞 recv，一轮 1.5 s 时损失 17%，换成快内核就是灾难）。
    void pump() {
        char buf[65536];
        for (;;) {
            ssize_t n = recv(fd_, buf, sizeof(buf), MSG_DONTWAIT);
            if (n > 0) {
                inbox_.append(buf, (size_t)n);
                if ((size_t)n < sizeof(buf)) break;
            } else if (n == 0) {
                throw std::runtime_error("矿池关闭了连接");
            } else {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) break;
                throw std::runtime_error("recv 失败");
            }
        }
        size_t p;
        while ((p = inbox_.find('\n')) != std::string::npos) {
            std::string line = inbox_.substr(0, p);
            inbox_.erase(0, p + 1);
            if (!line.empty()) handle(line);
        }
    }

    Job job() { std::lock_guard<std::mutex> lk(m_); return job_; }
    uint64_t job_seq() { std::lock_guard<std::mutex> lk(m_); return job_seq_; }
    int accepted() const { return accepted_; }
    int rejected() const { return rejected_; }
    int submitted() const { return submitted_; }
    const std::string &last_error() const { return last_error_; }

private:
    void send(const std::string &s) {
        std::string out = s + "\n";
        if (::send(fd_, out.data(), out.size(), 0) < 0) throw std::runtime_error("send 失败");
    }

    void handle(const std::string &line) {
        if (line.find("\"method\":\"job\"") != std::string::npos) {
            Job j;
            json_str(line, "job_id", j.job_id);
            json_str(line, "mining_hash", j.mining_hash);
            json_str(line, "difficulty", j.difficulty);
            json_str(line, "extranonce", j.extranonce);
            j.valid = !j.job_id.empty() && !j.mining_hash.empty() && !j.difficulty.empty();
            if (j.valid) {
                std::lock_guard<std::mutex> lk(m_);
                job_ = j;
                job_seq_++;
                printf("[job ] %s  diff=%s  extr=%s\n", j.job_id.c_str(), j.difficulty.c_str(), j.extranonce.c_str());
            }
            return;
        }
        // login 响应：session id + 内联首个 job
        if (line.find("\"job\"") != std::string::npos && line.find("\"result\"") != std::string::npos) {
            Job j;
            json_str(line, "job_id", j.job_id);
            json_str(line, "mining_hash", j.mining_hash);
            json_str(line, "difficulty", j.difficulty);
            json_str(line, "extranonce", j.extranonce);
            j.valid = !j.job_id.empty() && !j.mining_hash.empty();
            std::string sid;
            size_t q = line.find("\"result\"");
            if (q != std::string::npos) json_str(line.substr(q), "id", sid);
            if (j.valid) {
                std::lock_guard<std::mutex> lk(m_);
                session_ = sid;
                job_ = j;
                job_seq_++;
                printf("[login] OK session=%s job=%s diff=%s extr=%s\n", sid.c_str(),
                       j.job_id.c_str(), j.difficulty.c_str(), j.extranonce.c_str());
            }
            return;
        }
        // submit 结果：拒绝带 message；接受是 {"error":null,"result":{"status":"OK"}}
        std::string msg;
        if (line.find("\"error\":{") != std::string::npos && json_str(line, "message", msg)) {
            rejected_++;
            last_error_ = msg;
            printf("[submt] 拒绝: %s\n", msg.c_str());
            return;
        }
        if (line.find("\"status\":\"OK\"") != std::string::npos || line.find("\"result\":true") != std::string::npos) {
            accepted_++;
            printf("[submt] *** 矿池接受 *** 累计 %d\n", accepted_);
            return;
        }
        printf("[pool ] 未识别: %s\n", line.substr(0, 200).c_str());
    }

    int fd_ = -1;
    int id_ = 0;
    int accepted_ = 0, rejected_ = 0, submitted_ = 0;
    std::string inbox_, last_error_, session_;
    Job job_;
    uint64_t job_seq_ = 0;
    std::mutex m_;
};

// ---------------------------------------------------------------------------

static void usage() {
    printf(
        "KanQ " KANQ_VERSION " —— Quantus (QTC) GPU 矿工，对接 Kryptex 矿池\n\n"
        "用法:\n"
        "  kanq --wallet <addr> [--pool <host:port>] [--worker <name>] [--device <n>]\n"
        "       [--iters <n>] [--blocks <n>] [--once] [--dry-run]\n\n"
        "  --pool     矿池地址，默认 qtc.kryptex.network:7049\n"
        "  --wallet   你的 QTC 钱包地址（qz...）\n"
        "  --worker   worker 名（以 wallet.worker 形式登录，默认 gpu）\n"
        "  --device   使用第几张 GPU（默认 0；多卡每卡起一个进程）\n"
        "  --blocks   网格块数（默认 4096，256 线程/块）\n"
        "  --iters    每线程连续扫的 nonce 数（默认 16）\n"
        "  --once     拿到一个被接受的 share 后退出（验证用）\n"
        "  --dry-run  只搜索并复核，不提交\n"
        "  --version  显示版本\n");
}

static int real_main(int argc, char **argv);

int main(int argc, char **argv) {
    try {
        return real_main(argc, argv);
    } catch (const std::exception &e) {
        fprintf(stderr, "致命错误: %s\n", e.what());
        return 1;
    }
}

static int real_main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);

    std::string pool = "qtc.kryptex.network:7049";
    std::string wallet, worker = "gpu";
    uint32_t iters = 16, blocks = 4096;
    int device = 0;
    const uint32_t block_size = 256;
    bool once = false, dry = false;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&](std::string &dst) { if (i + 1 < argc) dst = argv[++i]; };
        if (a == "--pool") next(pool);
        else if (a == "--wallet") next(wallet);
        else if (a == "--worker") next(worker);
        else if (a == "--device") { std::string t; next(t); device = atoi(t.c_str()); }
        else if (a == "--iters") { std::string t; next(t); iters = (uint32_t)strtoul(t.c_str(), nullptr, 10); }
        else if (a == "--blocks") { std::string t; next(t); blocks = (uint32_t)strtoul(t.c_str(), nullptr, 10); }
        else if (a == "--once") once = true;
        else if (a == "--dry-run") dry = true;
        else if (a == "--version") { printf("KanQ %s\n", KANQ_VERSION); return 0; }
        else if (a == "-h" || a == "--help") { usage(); return 0; }
        else { fprintf(stderr, "未知参数: %s\n\n", a.c_str()); usage(); return 1; }
    }
    if (wallet.empty() || iters == 0 || blocks == 0) { usage(); return 1; }

    printf("KanQ %s\n", KANQ_VERSION);
    CUDA_CHECK(cudaSetDevice(device));
    cudaDeviceProp prop{};
    CUDA_CHECK(cudaGetDeviceProperties(&prop, device));
    const uint64_t per_launch = (uint64_t)blocks * block_size * iters;
    printf("GPU #%d: %s  SMs=%d  网格=%u×%u  每线程 %u nonce  (每轮 %.3g nonce)\n",
           device, prop.name, prop.multiProcessorCount, blocks, block_size, iters, (double)per_launch);
    printf("矿池: %s  钱包: %s  worker: %s\n", pool.c_str(), wallet.c_str(), worker.c_str());

    Pool p;
    if (!p.connect_to(pool)) return 1;
    p.login(wallet, worker);

    Job job;
    auto t0 = std::chrono::steady_clock::now();
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < 15) {
        p.pump();
        job = p.job();
        if (job.valid) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    if (!job.valid) { fprintf(stderr, "15 秒内未收到 job\n"); return 1; }

    // 本进程的 nonce 模板：extranonce | salt | 0 | idx
    uint8_t nonce_tmpl[64];
    memset(nonce_tmpl, 0, sizeof(nonce_tmpl));
    {
        std::random_device rd;
        for (int i = 0; i < 8; i++) nonce_tmpl[4 + i] = (uint8_t)rd();
    }

    u32 *d_res = nullptr;
    const size_t res_bytes = (1 + MAX_HITS) * sizeof(u32);
    CUDA_CHECK(cudaMalloc(&d_res, res_bytes));
    u32 h_res[1 + MAX_HITS];

    MiningParams params{};
    params.total_threads = blocks * block_size;
    params.nonces_per_thread = iters;
    uint8_t header[32], target_full[64];
    uint64_t last_seq = 0;
    Job cur;
    double hashes_total = 0;
    uint64_t launches = 0, gpu_false = 0;
    auto bench_start = std::chrono::steady_clock::now();
    auto last_report = bench_start;
    int last_acc = 0, last_rej = 0;

    for (;;) {
        p.pump();
        uint64_t seq = p.job_seq();
        if (seq != last_seq) {
            Job j = p.job();
            if (!hex_to_bytes(j.mining_hash, header, 32)) {
                fprintf(stderr, "mining_hash 非法: %s\n", j.mining_hash.c_str());
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                continue;
            }
            memset(nonce_tmpl, 0, 4);
            if (j.extranonce.size() < 8 || !hex_to_bytes(j.extranonce.substr(0, 8), nonce_tmpl, 4)) {
                fprintf(stderr, "extranonce 非法: %s\n", j.extranonce.c_str());
            }
            qpow_host::target_full512(parse_u128(j.difficulty), target_full);
            qpow_host::target_hi_words(target_full, params.target_hi);
            qpow_host::prestate_from_input(header, nonce_tmpl, params.prestate);
            params.idx_base = 0;
            last_seq = seq;
            cur = j;
        }

        CUDA_CHECK(cudaMemsetAsync(d_res, 0, res_bytes));
        mine_kernel<<<blocks, block_size>>>(d_res, params);
        CUDA_CHECK(cudaGetLastError());
        p.pump();                                   // 网络 I/O 与 GPU 并行
        CUDA_CHECK(cudaDeviceSynchronize());
        CUDA_CHECK(cudaMemcpy(h_res, d_res, res_bytes, cudaMemcpyDeviceToHost));
        const uint64_t idx_base = params.idx_base;
        params.idx_base += per_launch;
        hashes_total += (double)per_launch;
        launches++;

        u32 hits = h_res[0];
        for (u32 k = 0; k < hits && k < (u32)MAX_HITS; k++) {
            uint64_t idx = idx_base + h_res[1 + k];
            uint8_t nonce[64];
            memcpy(nonce, nonce_tmpl, 64);
            for (int b = 0; b < 8; b++) nonce[56 + b] = (uint8_t)(idx >> (8 * (7 - b)));
            uint8_t in[96], digest[64];
            memcpy(in, header, 32);
            memcpy(in + 32, nonce, 64);
            qpow_host::hash_squeeze_twice(in, digest);
            if (!qpow_host::lt_be(digest, target_full, 64)) {
                gpu_false++;
                printf("[cand ] GPU 候选未过主机精确判定（高 256 位相等或惰性归约误差），累计 %llu\n",
                       (unsigned long long)gpu_false);
                continue;
            }
            std::string nonce_hex = bytes_to_hex(nonce, 64), result_hex = bytes_to_hex(digest, 64);
            printf("*** share nonce=%s\n    result=%s\n", nonce_hex.c_str(), result_hex.c_str());
            if (dry) { if (once) return 0; continue; }
            // share 只对找到它时的 job 有效；job 变了就是 Stale，不发
            p.pump();
            if (p.job_seq() != last_seq) {
                printf("    [丢弃] job 已变更，不提交\n");
                continue;
            }
            printf("    [提交] job=%s\n", cur.job_id.c_str());
            p.submit(cur.job_id, nonce_hex, result_hex);
        }

        auto now = std::chrono::steady_clock::now();
        if (p.accepted() != last_acc || p.rejected() != last_rej) {
            last_acc = p.accepted();
            last_rej = p.rejected();
            printf("    统计: 提交=%d 接受=%d 拒绝=%d 最后错误=%s\n", p.submitted(), last_acc, last_rej,
                   p.last_error().c_str());
            if (once && last_acc > 0) return 0;
        }
        if (std::chrono::duration<double>(now - last_report).count() >= 5.0) {
            last_report = now;
            double el = std::chrono::duration<double>(now - bench_start).count();
            printf("  [进度] %.1f MH/s  轮=%llu  累计 %.3e nonce  提交=%d 接受=%d 拒绝=%d  job=%s\n",
                   hashes_total / el / 1e6, (unsigned long long)launches, hashes_total,
                   p.submitted(), p.accepted(), p.rejected(), cur.job_id.c_str());
        }
    }
}
