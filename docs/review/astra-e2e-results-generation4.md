**Generation 4 Astra 独立 Release E2E：授权的 synthetic/socket 场景通过；最终发布验收不通过。**

日期：2026-09-26（UTC）。本轮自写 orchestration 使用新的隔离根、run ID、一次性密钥，独立启动并测试冻结的 Release E2E App，未以 Luna runner 的 PASS 代替证明。实际完成 11 次 capture、19 个 raw representations、8 次已接受 partial-request peer close、两种 receive buffer 的大响应、真实进程退出/重开和直接 AES-GCM 解密校验；另完成有界 100k mixed Core 历史测试。未发现未解除的 P0/P1。源码审查发现 **两项 P2、一项 P3**，详见 [中文源码报告](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/review/astra-source-review-generation4.md)，本报告不据此宣布 release ready。

**实物、机器及运行身份**

| 项目 | 实际值 |
|---|---|
| 冻结 base / HEAD | `79e987a982f15f9193392c9af98b66465efd5ee2` |
| canonical source | 520 inputs；`31d1ecf48be82594bf35fb5b74e85b8fd4947d3ae8a265d23dd787c220148b2c`；审计前后不变 |
| App | `build/hardening-phase6-20260925/generation-4/ReleaseE2EDerivedData/Build/Products/Release/MacClippyE2E.app` |
| executable SHA-256 | `5badd1a4c78177fab207f866c0b5fa0054ce60edc95e91cf502425a91712a592` |
| bundle / build | `com.macallyouneed.macclippy.e2e`；1.0.0 (1)；内嵌 Release 与上述 source SHA 一致 |
| 架构 / 最低系统字段 | arm64 + x86_64；`LSMinimumSystemVersion=14.0`；实际执行 arm64 |
| 硬件 | Mac16,6，Apple M4 Max，16 CPUs，64 GiB RAM（68,719,476,736 bytes） |
| 系统 | macOS **26.6.2**，build **25G83** |
| 编译环境 | Xcode **26.4.1 (17E202)**；Swift **6.3.1**，swiftlang-6.3.1.1.2 / clang-2100.0.123.102；Python **3.14.4** |
| 主 run ID | `c0b8aed3-cded-402a-b287-35829832721b` |
| 主测试根 | `/private/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/mce5-a4-sb7qemyi`，0700；已删除 |
| 密钥 / socket | 新生成 32-byte key，0600；control socket 0600；只在该根使用 |
| 实际 App PID | 首次 **66529**，有序退出后重开 **66584**，两个不同进程，均已退出 |
| 主 run 时段 | 08:41:29.717913 → 08:41:43.690772 UTC（约 13.973 s，含 10 s read-timeout 场景） |

完整环境在 [environment.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/environment.json)，实物与输入核验在 [identity-before.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/identity-before.json) 和 [identity-after.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/identity-after.json)。Shipping App 只核验 metadata/hash/架构，未启动；不能将 universal 文件等同于 Intel 或 macOS 14 的运行通过。

**独立性、断言与运行边界**

入口：[run_astra_e2e.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run_astra_e2e.py)。该文件由 Astra 编写，没有 import Luna/product Python runner；直接用 AF_UNIX socket 发请求、校验每条完整 newline JSON、长度、SHA-256 和单调时钟完成时间。Swift [astra-helper.swift](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/astra-helper.swift) 只负责隐藏启动、读取精确 run-specific named pasteboard、CryptoKit 直接解密和清理该 run 的 synthetic defaults/named board。

每次启动/关闭核验 run ID、canonical root、bundle、Release 配置、source SHA、PID 与 executable 路径；通过自有 PID 的只读 libproc 以及 root 内的 flock 验证进程和锁。未访问 `NSPasteboard.general`，未查询或操作已安装 PID 50253，未读正常用户 App 数据根、Keychain/TCC 状态，未开启可见 GUI，也未与 TextEdit、Safari、Terminal、Finder 交互。

生产调用链是 `E2E capture fixture → named board → 生产 observer/read → Runtime capture queue → ClipboardStore/BlobStore/SearchStore`。第一个 ASCII fixture 通过自然后台 observer poll，其余 10 个使用受支持的 forced immediate **生产 observer read**；这不是 SQL 直接写入主 E2E 数据。每次 capture 后由独立 helper 重新读取同一 named board，逐个比较 `(itemIndex, UTI, byteCount, SHA-256)`，因此没有只信任服务器自己的 round-trip 布尔值。source bundle 必须为 `com.macallyouneed.macclippy.e2e.synthetic`，record ID 必须唯一。

重现现有运行可在仓库根依次执行 `python3 -B build/hardening-phase6-20260925/generation-4/astra-review/verify_frozen.py after` 与 `python3 -B build/hardening-phase6-20260925/generation-4/astra-e2e/run_astra_e2e.py`；runner 每次重新生成 root/key/run ID。其配套 reviewer 可执行文件及源码均保留在授权 evidence 目录。旧 disposable key 已销毁，保存的密文用于完整性证据，不提供事后解密密钥。

**socket 场景逐项结果**

| 场景 | 独立断言与实测 | 结果 |
|---|---|---|
| 精确 11-byte `{"command":` 后关闭 peer，重复 8 次 | hex=`7b22636f6d6d616e64223a`；每次看到实际 accepted socket 新 fd（本次均 21）后再关闭；随后 ping 成功 | **PASS**，关闭旧 P1 指定缺陷 |
| 8 次关闭期间进程/锁不变 | 每次均 PID 66529、同 executable/run ID；lock device=16777231、inode=96786099，持续占有；无 restart/terminate | **PASS** |
| 分片 65,536-byte 请求 | newline 在内的完整帧恰好 65,536 bytes，依次发送 11 / 1,013 / 7,168 / 剩余 bytes，间隔 60/80/100 ms；响应完整、身份一致；耗时 **0.263418166 s**，断言 <3 s | **PASS** |
| 大响应，RCVBUF 请求及实测均 1,024 | 延迟 **250 ms** 再持续读取；完整 **66,183 bytes**，单个末尾 newline，JSON 可解码；**0.262238750 s**，断言 <5 s | **PASS**，关闭旧 P2 指定缺陷 |
| 大响应，normal 实测 RCVBUF=8,192 | 同样延迟 250 ms；完整 **66,183 bytes**、newline、JSON；**0.258656542 s**，断言 <5 s | **PASS** |
| malformed JSON | `ok=false,errorCode=invalid-request`，86-byte 完整响应；0.000761791 s；后续 ping 健康 | **PASS** |
| unknown command | `ok=false,errorCode=unknown-command`，184-byte 完整响应；0.000255458 s；后续 ping 健康 | **PASS** |
| partial JSON 保持连接、不补 newline | **10.001998500 s** 收到 86-byte `invalid-request`，断言 9–12 s；后续 ping 健康 | **PASS，按现有协议** |

read timeout 的响应码实际就是 `invalid-request`，服务器没有独立 `read-timeout` 错误码；报告未虚构更精确的错误诊断。read 与 write 各有自己的 I/O 等待预算，不能从本次结果推出全部异步 command handler 的端到端绝对时限。

精确分片请求 SHA-256：`2841f681e7cb0b3e2b358e7139502595620a4d55cd05d96df6fd9a3cddd7c55d`。两种大响应中解码出的原始文本均为 **65,536 bytes**，SHA-256 均为：

`e99b63028fdf23b3dd1c8da81b01d72e3c7f375877c35ef048ceb046e40c5b39`

完整 wire response 的 SHA-256 则分别为：1 KiB `ad40e94f32c48a339ea39ff47474a1dbd3ce48ba200e153c852913a3aa979327`；normal `54ec3ef06d2bef7f96301248a2f59dac9e28972fbbf5e5b05e905c59116ac790`。响应带有时间字段，两个 wire hash 不同是预期；比较 payload 本身的长度、哈希和表示身份均相同。

原始请求/响应：[0012 fragmented request](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/0012-fragmented65536.request)、[0023 small-buffer response](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/0023-large-response-one-kib.response)、[0025 normal response](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/0025-large-response-normal.response)、[完整事件时间线](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/events.jsonl)。最终再校验 **82 组请求/响应、164 个 raw 文件**的记录长度/哈希和响应 framing，全部一致，见 [evidence-crosscheck.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/evidence-crosscheck.json)。

**synthetic 内容覆盖：11 records、19 representations**

下表每一行均通过 record/source/format/payload 身份校验；“字节”是选定 raw UTI 的字节数，不把 preview 或 decoded character count 当作原始字节长度。`UTF8` 指 `public.utf8-plain-text`。

| fixture | record ID | 实际 primary / raw UTI | raw bytes | native items / representations | 结果 |
|---|---|---|---:|---:|---|
| ASCII，自然 poll | `01M3EE0W2AA1N7YMD80BC4VHTS` | text / UTF8 | 48 | 1 / 1 | PASS |
| CJK：简繁中文、日本語、한국어 | `01M3EE0W3TFAEKB6WJQG5KBD51` | text / UTF8 | 82 | 1 / 1 | PASS |
| emoji、ZWJ、肤色、组合字符、variation selector | `01M3EE0W5349CPYY4T7TPHYM7W` | text / UTF8 | 108 | 1 / 1 | PASS |
| HTML，含标签、实体、中文 | `01M3EE0WEWSTDDZXBVJCG2XXMB` | html / public.html | 72 | 1 / 1 | PASS |
| RTF，含 CJK/emoji | `01M3EE0WJ0H5Q7FK6CN48WE2YD` | **text** / public.rtf | 432 | 1 / 3 | PASS |
| PNG，16×16 | `01M3EE0WK7HQZAYKG4B1JRQZC0` | image / public.png | 358 | 1 / 1 | PASS |
| 根内 file URL | `01M3EE0WM9VXY7FSQH9T5SRKA7` | files / public.file-url | 132 | 1 / 1 | PASS |
| 四 items，相同 UTF8 UTI/文本 | `01M3EE0WNEP4T7T8T5DY95JY7P` | text / UTF8 | 49 | 4 / 4 | PASS |
| 四 items，后 3 个 custom marker payload | `01M3EE0WPJH2RZAMXAZ563Z4CQ` | text / UTF8 | 49 | 4 / 4 | PASS |
| 65,536-byte text，确实 spilled | `01M3EE0WQRR0GRTSWXJ6FH0M82` | text / UTF8 | 65,536 | 1 / 1 | PASS |
| 新进程重开后 follow-up capture | `01M3EE17P7V75Y59JGYFMSQSWW` | text / UTF8 | 82 | 1 / 1 | PASS |

RTF fixture 实际保存了 `public.rtf` 432 bytes、`public.utf16-external-plain-text` 112 bytes、UTF8 67 bytes；production mapper 选出的 primary 是 **text**，没有误报为 rtf primary。四-item custom fixture 的 items 1–3 使用 `com.macallyouneed.macclippy.e2e.fixture-index`，各 46 bytes 且 item index/内容不同；不是四种不同 custom UTI。多-item 用例是一条历史记录内的多个 pasteboard items，不是四条历史记录多选粘贴。

file fixture 的目标确实在隔离根 `corpus-fixtures/` 中，4,096 bytes、0600，逐字节和 SHA 校验通过；其 file-URL 表示是文件引用，未声称已导入目标内容或证明 sandbox bookmark/真实 Finder 接收。PNG 独立读取核验 16×16 与 358-byte SHA，不要求 OCR 完成。每个 representation 的完整 SHA、长度、itemIndex、UTI、decoded text 及独立 named-board 观测见 [captures.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/captures.json)。

本轮证明捕获、持久化和 raw representation 保存，**没有运行 OS paste、normal/plain replay 到真实接收 App、GUI 编辑或多选队列插入**。相关生产调用链及既有 unit assertions 已审查，但不得据此宣称 recipient interoperability。

**有序退出、不同进程重开、持久化和加密原始表示**

完成前 10 条 capture 后，先验证 PID/run/root/executable/lock，再发送 `terminate`；PID 66529 消失且 flock 释放，耗时 **0.223325458 s**。停止期间只读检查各 SQLite `quick_check=ok`，记录 schema/文件哈希；使用独立 CryptoKit helper 与当前一次性 key 直接打开 `.bin` AES-GCM sealed box，核验明文字节。

同一根、同一 key 重开为 **66584**。key 的一致性只在内存比较，未把 key 或 key 的摘要写入证据。搜索唯一 restart marker，返回精确的 65,536-byte record ID；随后逐条 `verify-record` 比对原来的 10 条 ID、primary kind、decoded text 及每个 raw representation 的 itemIndex/UTI/长度/SHA。全部相同。再捕获 follow-up item 并搜索命中它的唯一 ID。第二次有序关闭耗时 **0.175561375 s**，进程消失且锁释放。

| 直接解密的 blob | ciphertext bytes | cleartext bytes | 重启前后 |
|---|---:|---:|---|
| `01M3EE0WK69CA1EFDWVAV6MJD2.bin`，PNG primary | 386 | 358 | AES-GCM 验证成功，密文与明文 SHA 均不变 |
| `01M3EE0WQRPGP7QMZMVWSB7W8W.bin`，spilled text raw representation | 65,564 | 65,536 | AES-GCM 验证成功，密文与明文 SHA 均不变 |

PNG 明文 SHA：`934dbf8e2f5ec19e3da67ee5b31c5e6ad6e5d6f764e09f5b22d1060682d1de5b`；密文 SHA：`b0f66df3b38816ad22e88b963f52adc3dfba0c26da5d474d5153f7a9a44838db`。

长文本明文 SHA 如上 `e99b6302…c5b39`（完整值位于 socket 部分）；密文 SHA：`f30e0b73c39a83cd2ce1046e0cc239b2745ce2098757f3beee676c99df1c2bdc`。核验的是实际存储 raw representation 的加密文件，不只是 DB preview 或 FTS 文本。

证据：[decrypt-before-reopen.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/decrypt-before-reopen.json)、[decrypt-after-reopen.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/decrypt-after-reopen.json)、[storage-after-reopen.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/storage-after-reopen.json)。两份 decrypt 数组最终逐字段比较完全一致，保存密文也重新 hash 验证。

最终 App metrics：capture/OCR queue depth 与 bytes 均 0；capture persist failure/not-saved/dropped/overload 均 0；unrecovered=false。有效 cap 为 200,000 items、2,147,483,648 image bytes、4,294,967,296 total bytes。clipboard/search WAL 分别 57,712/37,112 bytes，pinboard/snippet WAL 为 0；`maintenanceQueueDepth` 明确 unavailable，未写成 0。主 App 没有采集 CPU/physical-footprint 时间序列，故该层资源 delta 为 **NOT MEASURED**。

**额外生产 transport TSan 与 20 MiB 存储边界**

Astra [socket_probe.swift](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/socket_probe.swift) 将冻结、未修改的 `MacClippyUnixSocketLineTransport.swift` 编入独立 `-O -sanitize=thread` executable。17 个断言场景通过，总墙钟约 **3.083166 s**，stderr=0：

- invalid fd 的必要 option 设置失败返回 false；closed peer 写入 8 次均安全失败，没有 SIGPIPE 终止。
- 65,536-byte fragmented read，记录 10 次 would-block；1,024/8,192 buffer 延迟 reader 收齐 body+newline，直接读取 sender `SO_SNDLOWAT=1`。
- 不读取的 peer：1 MiB write / 80 ms budget 在 **82.010625 ms** 返回 false；partial write 后 peer close 安全返回 false。
- 最大 read body=3 时 `abc\n` 接受、`abcd\n` 拒绝；poll EINTR 注入下 80 ms read budget 在 **82.251208 ms** 返回 nil。
- 所有自有 fd 显式 close，随后检查 EBADF。

它是实际 transport 的独立 TSan 检查，不是 full Package TSan，通过不能覆盖后者已记录的失败。原始证据：[socket-probe-tsan.stdout.jsonl](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/socket-probe-tsan.stdout.jsonl)、[运行结果](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/socket-probe-tsan-result.json)。

另用实际 Release Core 对 **20,971,520-byte（20 MiB）** 表示执行 spill/read/认证、错误 key、密文篡改和 `maxItems=0` 清理。明文 SHA `35ff889b68c49bd94784ecc140a6214fe716535459eca806992eea53d3f351db`，密文 20,971,548 bytes；错误 key 与篡改均 `openFailed`，当前 v2 roster 重新认证通过；最终 record/search rows=0、blob 不存在。该测试同时是新 P2 旧 v1 问题的当前格式正向对照。证据：[large_payload.swift](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/large_payload.swift)、[原始结果](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/large-payload.stdout.jsonl)。单次内部操作约 29.708 ms，不作为 p95/p99 性能结论。

**规模测试与实际性能样本**

先区分三个层次：已有 10k Runtime XCTest、本轮独立 100k **Core** mixed history、尚未运行的 100k **App Runtime ingestion / visible UI**。后两者不可互相替代。

已有 10k Runtime：核验 `generation-3/app-runtime-scale.log:4576–4583` 的真实终结事件，`testStructuredRuntimeSearchStaysPagedAtTenThousandRecords` **PASS，4.194 s**。测试通过 Runtime `appendTestRecord(.text)` 与 SearchStore 写入 10,000 条纯文本，查询 `type:text`、`scale type:text` 的 limit 16，以及唯一 marker 命中 1 条；断言每个宽松预算 <30 s。它不是 mixed corpus，不是 visible UI，也没有能据此计算的 p50/p95/p99 序列。G4 gate 复用了此结果，本轮没有假装重新执行。

独立 100k：Astra [scale100k.swift](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/scale100k.swift) 以 `-O` 链接冻结 E2E Release 的 `MacClippyCore.o` 和 `GRDB.o`，通过公开 `ClipboardStore.append(representations:)`、`SearchStore.upsert` 逐条写入，无直接 SQL seed。父 runner [run_scale100k.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run_scale100k.py) 设置 **190 s** deadline、**2 GiB physical footprint** 停止阈值，Swift 插入循环另有 **180 s** 总预算；实际正常完成，未触发停止条件。

| 数据集/行为 | 实测 |
|---|---|
| 独立 scale run | `scale-c881eadc-afcf-4c77-83f3-c18a8776ad0f`，PID 66916；新 0700 根、新 32-byte/0600 key；均已清理 |
| executable SHA | `35f96ab49db58fa59abccf299212988a8d1583674fa02a7359d6b93638e325c1` |
| records | **100,000**；text / html / rtf / image / files **各 20,000** |
| representations / search rows | **100,000 / 100,000**，每条一个表示；SQLite 只读复核 counts 与 `quick_check=ok` |
| fixture 的实际重量 | 20k image records 共用 **1 个 1×1 PNG blob**；20k files 共用 **1 个根内合成文件**。非大量独立图片/文件内容或完整多-UTI corpus |
| 插入 wall | **29.774675625 s**，逐条 Core API 写入/认证与 FTS 更新 |
| 总计 | Swift workload **29.938759458 s**；父进程测得 **30.169012625 s**（含资源采样尾段） |
| CPU | `getrusage` user+system **23.338113 CPU s**，约为该 workload wall 的 **77.95% 单核**；不是全机 CPU 使用率 |
| physical memory | 每约 0.5 s 采样，共 **60** 个有效样本；首次 **950,584** bytes，末次 **129,598,088**，峰值 **129,843,848**；末次减首次 **128,647,504 bytes = 122.688 MiB** |
| memory baseline 限定 | 首次在进程启动后约 0.00348 s、store 初始化前；不是已预热 idle-App baseline，不据此判断长期泄漏 |
| 磁盘 | 排除 key 的文件总计 **142,127,294 bytes**（约 135.54 MiB），关闭时两库 WAL 均为 0 |
| 进程 I/O | 末次 `process_io_bytes_written` **13,901,946,880**；首次计数 unavailable，因此不虚构精确写入 delta。该值是进程归因写入，不是物理磁盘实际落盘字节 |

100k 查询序列使用同一进程、刚写完的数据库，循环访问最后五条记录的唯一词，另读 limit-50 最新 metadata page 及认证 playback。每类 **101 个真实样本**，nearest-rank `ceil(p*n)-1`；属于热数据局部访问，不能外推为随机全库 workload 或 UI 延迟。

| 实测层/操作 | n | p50 ms | p95 ms | p99 ms |
|---|---:|---:|---:|---:|
| 100k Core，唯一词 FTS（命中 1） | 101 | 0.094792 | 0.117083 | 0.192875 |
| 100k Core，metadata 最新 50 条 | 101 | 0.208500 | 0.246541 | 0.257000 |
| 100k Core，认证 playback 表示读取 | 101 | 0.062417 | 0.080666 | 0.100084 |
| 主 E2E App，**仅 11 条历史**，socket search 往返 | 31 | 1.899125 | 2.223500 | 2.280708 |
| 同一 11 条 App 查询，server 报告执行时间 | 31 | 1.775750 | 2.094833 | 2.154292 |

公共词 `mixedhistory` 匹配 100k 条时，Core limit-50 查询测得 **111.696792 ms，n=1**；没有为单次测量计算 p95/p99。该结果也说明唯一词的极低耗时不能代表大范围 FTS 排序/匹配成本。

原始 101 条查询与 100 次插入进度、只读 DB counts 位于 [scale result.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/scale-c881eadc-afcf-4c77-83f3-c18a8776ad0f/result.json)、[stdout.jsonl](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/scale-c881eadc-afcf-4c77-83f3-c18a8776ad0f/stdout.jsonl)、[resource-samples.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/scale-c881eadc-afcf-4c77-83f3-c18a8776ad0f/resource-samples.json)；11 条 App 数据集的原始样本见 [query-samples.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/query-samples.json)。独立重算的 [performance-summary.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/performance-summary.json) 保留样本量、算法、min/max 与所有分位数。

| 目标 / 验收层 | 状态 |
|---|---|
| 实際大响应 payload 完整、两种 buffer、<5 s | **PASS**，约 0.26 s |
| 本轮有界 Core 100k mixed headroom，180/190 s 与 2 GiB 限制 | **PASS**，真实 Core 路径完成，数据集重量限制如上 |
| 100k App Runtime mixed-history production observer ingestion | **NOT RUN**。本轮选择可在明确预算内完成的公开 Core API harness；未进行可能耗时较长的 100k 逐次 App capture。未将 Core 写入声称为该项通过 |
| warm panel interactive p95 ≤100 ms | **NOT RUN**，禁止可见 GUI |
| 10k visible App search p95 ≤100 ms | **NOT RUN**；已有 Runtime XCTest 的 <30 s 断言不能证明该目标 |
| 100k visible App search p95 ≤200 ms | **NOT RUN**；Core 101 热查询样本不能证明该目标 |
| 24h/72h soak 或 memory leak 趋势 | **NOT RUN**；约 30 s scale 不是 soak |

上面三个 UI 性能阈值来自项目 [competitive-comparison.md](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/competitive-comparison.md:17) 与 [e2e-phase5.md](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/e2e-phase5.md:150)，是验收目标，不是当前测量。没有把计划目标记作 PASS。

**失败、既有 gate、未运行项**

首次 Astra orchestration trial `95830896-4327-46f5-b6b4-f8ecc69d4f3e` 因 reviewer 将 `/private/var/...` 与 App 返回的 `/var/...` 作字面比较而失败；不是产品崩溃。该错误也令原 finally cleanup 的 identity assertion 失败，故保留原 `FAIL_CLEANUP`，没有改写为通过。随后用 canonical path 验证自有 PID 66374，控制 socket 有序退出、锁释放、删除 exact named board/defaults 和 root/key，完整 [cleanup-recovery.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-95830896-4327-46f5-b6b4-f8ecc69d4f3e/cleanup-recovery.json) 保留过程。仅修 reviewer 路径比较后，用全新 root/run/key 完成上述 PASS run；没有改产品源码。

已有 raw gates 经哈希和 XCTest 终结事件核验：G4 Package 648=644 pass+4 skip，App 420=418 pass+2 skip，App TSan 同为418 pass+2 skip，focused socket 8 pass，filtered Package socket TSan 8 pass，strict lint 451 文件零新增违规，Shipping/E2E universal Release build succeeded。它们在本轮是**核验已有证据**，不是重新执行全套。Luna G4 E2E raw PASS 与本轮 Astra PASS 分开存放。

**Full Package TSan 不通过**：保留 G2 宿主限制记录，640 tests 中632 pass、4 skip、4 failed tests，94 failure assertions（1 unexpected），73 interceptor initialization errors，失败集中 crash-child sanitizer。没有无谓重跑该已知失败全套，也没有用 filtered socket 或 App TSan 覆盖成“全部 TSan PASS”。详细失败测试名、skip 原因、相关源代码与日志行号见源码报告及 [raw-gate-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/raw-gate-audit.json)。

| 未运行 / 未通过项 | 原因和剩余边界 |
|---|---|
| **macOS 14 baseline** | 用户没有该环境；minimum deployment target 只验证 metadata，明确 **NOT RUN** |
| x86_64 运行 | 本机 arm64；仅验证 universal 架构 |
| **GUI / real recipient interoperability** | 禁止可见 UI、general pasteboard 和 TextEdit/Safari/Terminal/Finder；未验证 OS paste、recipient 格式接收、剪贴板 restore 的真实系统效果 |
| **permissions / lifecycle UI** | 未改变或访问 TCC；真实 event tap/AX 提示、允许/拒绝、系统睡眠唤醒、UI 生命周期均未验收 |
| panel、preview loops、normal/plain paste、GUI cancellation | 仅源码/既有单测证据，无本轮 GUI 结果 |
| App 100k mixed ingestion / visible-search 目标 | 如上 **NOT RUN**，Core headroom 与小数据 App IPC 分开报告 |
| 10k observer start/stop opt-in | 本轮未运行；原 Package 该项 skipped |
| **24h / 72h soak** | 用户明确不运行；没有以短期样本或 earlier runner smoke 冒充 |
| Full Package TSan | **FAIL / host limitation**，不是 PASS |
| 签名、公证、下载后 Gatekeeper 首启 | 未执行发布、真实公证和下载流程 |

**清理与最终交接**

最终只读复核 **8 个 reviewer mkdtemp 根全部不存在**：主 run、首次失败 trial、100k scale、transport TSan、storage-edge fixture、offline scripts、20 MiB fixture、lint fixture。使用加密数据的测试均为独立随机 32-byte 密钥，0600，位于0700根中；密钥文件随根删除，没有将材料复制到 evidence。主 run 只保存 synthetic DB/密文/根内 fixture 的证据副本，复制时校验原文件与副本 SHA；初始/主 run 的 exact synthetic defaults domain 与 named board 均已移除。PID 66374、66529、66584、66916 最终只读检查均已不存在。

清理证据：[主 run cleanup.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/cleanup.json)、[最终跨测试清理审计](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/cleanup-final-audit.json)。冻结源文件、build inputs 和 App executable 前后哈希不变，已有工作树库存字节未变；只增加授权 evidence/harness 和两个中文报告，见 [preservation-final.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/preservation-final.json)。

需要 root/Luna 处理的开放项为 **P2：v1 roster 维护认证版本误判、P2：共享图片配额重复计费、P3：CI strict lint 缺口**。独立 socket 修复验收、synthetic 内容/真实进程重开及 Core headroom 已完成；最终发布结论仍为**不通过**，原因是这些开放 finding 和明确未满足的验收范围。没有修改产品/源/测试/构建脚本，也没有 commit、push、tag、PR、publish 或 release。
