**Generation 2 独立 E2E 执行报告（2026-09-25 PDT / 2026-09-26 UTC）**

**验收结论：FAIL，不能给出完整 E2E 接受结论。** 本轮独立离线驱动测试 37 通过、0 跳过；最终 Release E2E 进程完成 9 个安全合成捕获样例，但第 10 个、65,536 字节文本请求在控制通道发送阶段发生 `BrokenPipeError`。记录为 **E2E-G2-P1-001：E2E 控制传输验收阻塞**。依照任务中的 P0/P1 停止要求，已停止后续产品执行，未修复源码。重启、搜索、重放、规模性能与长时 soak 均不能从这次部分结果推定通过。

全文将“本轮实际运行”“独立复核既有最终日志及测试源码”“未运行”分开。既有单测通过不是本轮进程 E2E 通过；synthetic recipient 也不是外部应用互操作通过。TextEdit、Safari、Terminal、Finder、macOS 14、24h/72h soak 均为 **NOT RUN**。

**证据目录与冻结身份**

工作目录为 `/Users/mingjie/Documents/github/personal-projects/mac-clippy`。下文 `E` 的完整路径为：

`build/hardening-phase6-20260925/generation-2/astra-e2e/`

主要文件：[逐项原始记录](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-2/astra-e2e/runtime-smoke.jsonl)、[异常原文](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-2/astra-e2e/runtime-smoke.stderr.log)、[执行输入全文](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-2/astra-e2e/runtime-smoke.stdin.txt)、[P1 结构化记录](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-2/astra-e2e/p1-finding.json)。`runtime-smoke.stdin.txt` 是本轮原始执行输入，仅保存在证据目录，没有改动产品脚本或测试。

入口先读取 `/tmp/macclippy-phase6-control.json`，revision 47：generation=2；phase=`generation-2-source-frozen-astra-review-and-e2e`；`mutation_in_progress=false`；`source_fix_pending=false`。逐一重读 515 个 manifest 文件、校验大小和 SHA，并按排序后的 canonical JSON 计算摘要，得到：

`b41b7cdbed5b5eb81bfc3997460277be600ac4c6f467f30f742959bf6602c823`

结束时使用未修改 driver 的 `build_source_manifest` 重新枚举源码输入，仍为相同 SHA、515 项；控制状态未改变。证据为 `E/control-initial.json`、`E/frozen-manifest.json`、`E/identity-initial.json`、`E/source-manifest-final.json`、`E/identity-final.json`、`E/control-final.json`。没有重建或覆盖最终 Release 产物。

| 产物 | 独立核验结果 |
|---|---|
| Shipping | `generation-2/ReleaseShippingFinalDerivedData/Build/Products/Release/MacClippy.app`；bundle `com.macallyouneed.macclippy`；binary SHA `1b608645e9f255b59a6bed7cf5ea2602fde42ece361f85decbf7ac345e71d5b4`；x86_64 + arm64 |
| E2E | `generation-2/ReleaseE2EFinalDerivedData/Build/Products/Release/MacClippyE2E.app`；bundle `com.macallyouneed.macclippy.e2e`；Release；binary SHA `2fe98570d49e36227f428ed990891a1aa23aeb68d0f1cd0ad37b3104e7b50595`；x86_64 + arm64 |
| 内嵌来源 | E2E `MacClippyE2ESourceContentSHA256` 与冻结 SHA 相同；实际进程 ping 返回相同身份。Shipping 不包含该 E2E 专用 plist 字段，其来源依据最终构建前后 manifest 及 binary SHA |

见 `E/artifact-identity-independent.json`、`E/binary-isolation-static.json` 和 `E/inherited-raw/source-manifest-*-before.json` / `*-after.json`。没有运行 Shipping app 或安装版 PID 50253；未读取其进程状态、用户数据或凭据。

**已检查的真实入口与隔离边界**

实际阅读了 `docs/e2e-phase5.md` 全文、driver 实现及 `--help` / `request --help`，没有按命令名称推断安全性。阅读副本为 `E/e2e-phase5-reviewed.md`；帮助输出与命令参数见 `E/driver-help.stdout.log`、`E/request-help.stdout.log`、`E/initial-commands.json`。文档末尾引用旧 SHA 的 Phase 5 hidden smoke 与已丢失 raw 的 30 秒 soak，未纳入本代动态通过证据。

| 路由 | 静态核验及本轮处理 |
|---|---|
| 启动身份 | `MacClippyE2EBuildIdentity`、AppDelegate 生命周期、`project.yml` 的独立 bundle/编译条件；shipping binary 未发现所检查的 E2E root、控制 server、cancelable-paste 标志。字符串检查仅为辅助，不代表全部代码可达性证明 |
| 临时根与密钥 | `MacClippyE2EIsolation.swift` 验证 OS 临时目录的 `mce5-` 直接子目录、0700/owner UID、0600 marker、UUID、symlink、live-root 不重叠及 flock。`MacClippyE2EFileKeychain.swift` 使用根内独立 32-byte/0600 key，未访问真实 Keychain |
| Runtime 依赖 | `MacClippyAppDelegate+BackupRestore.swift:8` 显式注入 paths、file keychain、observer、injector、sentinel、run-specific defaults，关闭 snippet expansion。`MacClippyRuntimeStorageBootstrap.swift:18` 对 E2E 缺失存储依赖拒绝启动 |
| 捕获与查询 | `capture` → 每次运行唯一的 named NSPasteboard → production reader/observer → Runtime/store → authenticated payload proof；synthetic source app 固定。`search-db` 为 Runtime.history 路径，`verify-record` 为稳定 ID 的认证读取；均不要求可见 UI |
| 控制权限 | driver 核验私有 root、run ID、socket UID/mode；ping 再核验 PID、根、bundle、可执行路径、Release/source SHA。这里的认证是本机 owner-only 根/socket 与身份校验，不是单独网络 token 协议 |
| Synthetic recipient | injector 的两种 poster 均止于内存 recipient，targeted 分支要求 `getpid()`；不发真实 Cmd+V/OSAX。**本轮未执行 recipient paste** |
| 可见命令 | `MacClippyE2EControlPaste.swift:135` 的 selection preparation 无条件调用 `activateE2EForVisibleUI` 并等待 key panel。`paste-begin-cancelable` 也先走 UI search。`search-ui`、panel、preview 同样要求激活。因此全部 BLOCKED，未调用 |
| 权限与退出 | 启动跳过 privacy prompt、global hotkey 注册与 login item 操作，snippet event tap 不启动。退出只用当前 root/run/PID 的 `request_terminate`，无全局 PID signal fallback |

源码带行号摘录保存在 `E/reviewed-route-excerpts.txt`。没有访问 `NSPasteboard.general`，没有更改 TCC，没有打开、解锁或绕过锁屏；未启动任何外部互操作应用。

**P1 阻塞详情与执行边界**

2026-09-26 06:02:26.564 UTC 创建独立 root：

`/private/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/mce5-1cp_gv36`

run ID=`6544f102-0738-43c9-b527-7da07d135833`。隐藏启动的 E2E PID 为 **31397**，身份由原 driver 校验。根内 key 确认为 32 bytes、0600，只有合成 key 的 hash 和元数据入证据，key 原文未复制。

本轮执行的准确命令：

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B build/hardening-phase6-20260925/generation-2/astra-e2e/runtime-smoke.stdin.txt > build/hardening-phase6-20260925/generation-2/astra-e2e/runtime-smoke.stdout.log 2> build/hardening-phase6-20260925/generation-2/astra-e2e/runtime-smoke.stderr.log
```

执行输入直接调用原 driver 的 root/launch/control/terminate API。第 10 条 `text="L" * 65536`、format=text、itemCount=1、forcePoll=true；65,536 bytes 小于 fixture 的 1 MiB 与控制请求的 2 MiB 上限。`scripts/e2e/macclippy-phase5.py:540` 的 `client.sendall(payload)` 报 `BrokenPipeError: [Errno 32] Broken pipe`，随后转为 `E2E app control request failed (capture)`，命令 exit 1。`E/runtime-smoke.jsonl:14` 保存完整栈。

**观察到的是一次有效请求的传输失败；尚未证明存储层损坏，也没有服务端 errno 采样或第二次产品复现。** 可疑源码边界为 `MacClippyE2EControlServer.swift:249` listener 设置 `O_NONBLOCK`，accept 后未重置 client flags，`:368` 将任何 `recv <= 0` 都视为无效请求并关闭连接，没有区分暂时不可读/EINTR。分段到达的请求因此可能被过早关闭；该根因仍待修复阶段确认。

这阻断 65,536-byte spilled capture/restart gate；原 driver 的 `restart-check` 固定使用该大小，混合 corpus 的第 5 条也有长文本。**本轮未实际运行这些后续命令，不能写成它们已失败或已通过。** 未缩小 fixture、调换代码、重试到通过、绕过控制通道或直接 seed 数据库。

异常后 finally 通过私有控制通道关闭 PID 31397，06:02:30.996 UTC 记录退出；随后复制该 root 的数据库/WAL/SHM、合成 blob/file、marker、app/source identity 等。`E/root-copy-verification.json` 逐文件校验原件/副本 SHA 后，才用 `soak clean --root <上述根> --run-id 6544f102-0738-43c9-b527-7da07d135833` 清理独占临时根和测试 key，exit 0。准确清理参数及结果见 `E/cleanup-command.json`、`E/cleanup.stdout.log`。失败日志与原始现场仍在 `E/runtime-smoke-root-evidence/`。没有遗留本轮 E2E 进程或 soak。

**本轮捕获结果：9 PASS、1 FAIL，0 个测试框架 skip**

每个 PASS 均核对稳定 record ID、synthetic source、保存后解密的 primary UTI bytes/hash、item count，以及按 itemIndex/UTI 排序的完整表示列表；文本和 HTML 另与输入 UTF-8 hash 比较。ASCII 使用自然 observer polling，其余为明确标注的 forced production observer read。RTF 实际 primary kind 为 text，同时保留原 RTF；没有把 source format 等同 primary kind。

| 样例 | 状态 | 稳定 record ID | 主要字节与 item 证据 |
|---|---|---|---|
| ASCII text | PASS | `01M3E4XPD5ZJ43ZWFDZ64BX549` | UTF-8 25 bytes，1 item |
| CJK | PASS | `01M3E4XPE0FRQ20GZWAFS13SJQ` | UTF-8 31 bytes，中文/東京/後半 |
| Emoji/组合字符 | PASS | `01M3E4XPF8NARVMX9HQK9FKJ06` | UTF-8 49 bytes，ZWJ、肤色、surrogate、combining、VS |
| HTML | PASS | `01M3E4XPS14SQK9DP52JYK5D6N` | public.html 63 bytes，含 CJK/emoji |
| RTF | PASS | `01M3E4XPVTYQ8ZF4J4GT7C5XP9` | public.rtf 370 bytes；另有 UTF-8/UTF-16 表示 |
| Image | PASS | `01M3E4XPX2495D1VDPEJTSW1CJ` | PNG 283 bytes；decodedText=null |
| File | PASS | `01M3E4XPY5VKQ98GH009XQEZD2` | file URL 102 bytes；根内合成文件 4,096 bytes；decodedText=null |
| 重复 UTI multi-item | PASS | `01M3E4XPZ89F1J2SWNKPWY8EP1` | 4 items，index 0…3，均为相同 UTF-8 41 bytes/hash |
| 不同 item 内容 | PASS | `01M3E4XQ0DWNWQGC2J87A7P0K9` | index 0 文本50 bytes；index 1…3 为各自27-byte marker |
| 65,536-byte spilled text | FAIL | 未返回 ID | 控制传输异常，未获得 capture 成功证据 |

原始响应含全部 hash、UTI、item 顺序、解码文本和时间，见 `E/runtime-smoke.jsonl:5` 至 `:13`。multi-item 的 itemIndex 是一条 clipboard record 内的 item 顺序，不能冒充多个被选记录的队列顺序。

**七类场景矩阵**

以下“既有 PASS”限定于对冻结代源码及原始终态日志的独立复核，本轮没有重新执行对应 XCTest。所有引用日志均已完整复制至 `E/inherited-raw/`；方法名、状态、精确日志行号见 `E/inherited-scenario-tests.json`。NOT RUN/BLOCKED 是覆盖缺口，不计为通过；测试框架实际 skip 另列。

| 类别与具体路径 | 本轮状态 | 已复核证据、数量及缺口 |
|---|---|---|
| 1. text/CJK/emoji/HTML/RTF/image/file/multi-item 捕获 | **PASS（9 个有界样例）**；长文本 **FAIL（1）** | 上表及 raw response；不覆盖长文本 spill 成功 |
| 1. 进程 close/reopen → 同 ID 解密 → 搜索 | **NOT RUN** | P1 前止步；1 次计划 restart、9 条已保存记录的 reopen 校验及9次对应查询均未执行。finally 退出不算 restart |
| 1. rich/plain replay、ordered multi-record IDs、failure/cancel result | **BLOCKED / NOT RUN** | 普通/纯文本 paste 2 类、cancel 1 类需可见 panel；脚本计划的5个拒绝状态请求因提前异常均未执行。App unit 原始日志 `:6571` 的 `testCapturedMultiItemFormatsSurviveReopenSearchAndNormalPlainReplay` 通过，但它是在同一测试进程中关闭/重建 Runtime，再调用 `runtime.copy` 到 named board，不能标为真实进程重启或外部 paste。`:6583–6591` 覆盖 ordered merged/mixed/files-unsupported/malformed-RTF，均无 skip |
| 2. slow provider 时 recopy、generation churn、missing/delayed/oversized、bounded retry/no mixed versions | **PASS（既有单测复核）；本轮 E2E NOT RUN** | Package 的 ObserverRetry 7、SystemPasteboardReader 6、SystemPasteboardRetry 1、PasteboardLimit 2、ReadRetryState 7，共23项通过、0 skip。检查真实 lazy provider 的两个同 UTI item 分轮到达、原 generation、每 provider 一次读取、最终双 payload；不只依赖 mock 名称 |
| 3. snippet 跨 app/同 app focus、输入版本、鼠标、排队期间输入、Esc | **PASS（既有非特权 fake 复核）；真实交互 BLOCKED** | `SnippetExpanderContextTests` 13/0 skip；`MacClippySnippetInputCommitTests` 2/0 skip。SyntheticFocusContext、startForTesting、recording posters，未发系统事件。包含 A→B→A、selection 改变、CJK/emoji UTF-16 anchor 与真实 decoder synthetic event |
| 3. clipboard 新版本提交保护、close/reopen stale queue callback | **PASS（既有单测复核）；本轮 E2E NOT RUN** | PasteInjectorGeneration 3、PasteInjectorGate 6、App QueuePasteLifecycle 2 均通过、0 skip；App queue 用 run-specific named board 与记录型 process-target poster。该证据不覆盖真实用户焦点或桌面操作 |
| 4. 权限/lifecycle 非特权 fake | **PASS（既有单测复核）** | GateTests 中权限在提交前丢失的2项、DisplayGenerationPolicy 8项均通过、0 skip；只是 fake/policy 路径，后者不证明真实 lock/sleep/wake |
| 4. real permission revoke/restore、lock/sleep/wake、多显示器 | **BLOCKED** | 5个维度未执行；真实 event tap 的 App 测试实际 skip 1，未改变权限 |
| 5. good/old-format/missing-file/equal-length corruption/wrong-or-missing key | **PASS（既有单测复核）；本轮破坏性 E2E NOT RUN** | BackupValidation 7、Compatibility 6、HistoricalSchema 1、SettingsPolicy 6，无 skip。旧 fixture 确实构建 clipboard migration008 与 baseline search001–004，并执行 live-root install、fresh store reopen、PNG/spilled bytes、wrong/missing-key 保持旧 root/backup 不变。pinboards/snippets 为空的当前 schema，不能扩大旧格式覆盖 |
| 5. atomic failure / interrupt rollback | **PASS（既有非 TSan 复核）**；全 Package TSan **FAIL** | RestoreTransaction 4通过；ProcessCrash 6项中5通过、1 child-entry skip。逐安装/rollback/cleanup/staged-move boundary 证据只归属于未加 TSan 的既有运行；本轮未重复破坏性测试。历史 fixture 使用固定合成测试 key，不能称为本轮逐场景新 key 执行 |
| 6. 256-page 边界删除、共享附件、pin 保护 | **PASS（既有单测复核）；本轮 E2E NOT RUN** | `DeletionJournalTests` 7/0 skip，含257记录/256不同blob；Core retention 的513记录跨页、257候选变化重试、shared blob、pinned保护，在 Package 原始日志 `:288,:292,:304,:310` 通过。AttachmentRetentionSafety 3/0 skip。未执行新破坏性 scenario |
| 6. index repair 与 search/capture 并行 | **PASS（既有单测复核）；本轮 E2E NOT RUN** | RuntimeSearchRepair 4/0 skip，App raw `:6718–6724`；源码用 repair page barrier，页间向 named board 捕获并从 Runtime.history 查到新记录，另测 edit/delete fence、cancel及 restore drain。SearchRepairPage 2/0 skip |
| 7. 1k、10k、100k mixed-history 性能 | **NOT RUN（3个规模）** | P1 后未启动 corpus。原 Package 100k 是直接写入全文本 ClipboardStore/SearchStore 的单次查询；App 10k 也是文本 fixture。两者不是 mixed corpus，也不是 panel latency |
| 7. 1,000 panel/preview cycles | **BLOCKED** | 实际0/1,000 cycles；未激活 E2E GUI；offline timeout 测试只证明 driver 计算与断言 |
| 7. 24h/72h soak | **NOT RUN（2个时长）** | 两者实际覆盖均0小时；未启动长跑或新的30秒 smoke soak；离线模拟 clock 的 worker regression 不算 soak |
| 外部互操作 / 平台 | **NOT RUN** | TextEdit、Safari、Terminal、Finder 4种互操作未运行；macOS 14 按明确指令无环境，未运行 |

**原始 gate 数量核对**

`Executed N tests` 包含 skipped 项，不能将 N 写成“通过 N”。本轮重新解析各 `Test Case … passed/failed/skipped` 终态，结果在 `E/inherited-test-counts.json`。

| 既有最终 gate | 报告总数 | 实际 PASS | SKIP | 失败 | 原始证据（均在 E/inherited-raw） |
|---|---:|---:|---:|---|---|
| Package focused | 40 | 40 | 0 | 0 | `package-focused-after-swift6-fix.log` |
| Package full | 640 | 636 | 4 | 0 | `package-full-after-swift6-fix.log:1603` |
| Package scale opt-in | 2 | 2 | 0 | 0 | `package-scale-opt-in-after-swift6-fix.log` |
| App unit-only | 419 | 417 | 2 | 0 | `app-unit-after-swift6-fix.log:6956` |
| App RuntimeScale opt-in | 1 | 1 | 0 | 0 | `app-runtime-scale-opt-in-after-swift6-fix.log` |
| Package TSan full | 640 | 632 | 4 | **4个测试失败，94 failures，含1 unexpected** | `package-tsan.log:2526` |
| Package TSan excluding crash-child group | 634 | 631 | 3 | 0 | `package-tsan-without-crash-child.log:1977` |
| App TSan | 419 | 417 | 2 | 0 | `app-tsan.log:7012` |

Package 默认4个 skip 为 child-only worker、10,000 observer lifecycle cycles、100k scale、20 MiB payload scale；App 默认2个 skip 为 RuntimeScale 和 real input tap。单独 opt-in scale 通过不把默认 suite 的 skip 改写为通过。所检查的本代最终日志中，10,000 lifecycle stress 未见独立启用的通过证据，保持 NOT RUN。

**完整 Package TSan 仍然 FAIL。** crash-child suite 的四个父测试因子进程 sanitizer interceptor 太晚初始化而失败；原文 `ERROR: Interceptors are not working. This may be because ThreadSanitizer is loaded too late (e.g. via dlopen)`，首条在 `package-tsan.log:446`，共73条该 ERROR、涉及36个不同 child PID；94是失败断言/异常数量，不是94个独立测试。过滤掉 crash-child 的 Package TSan 及 App TSan 通过均不能消除它。没有再次执行这一已知不支持的 full crash-child TSan 启动。

**环境、样本与性能目标**

| 项目 | 记录 |
|---|---|
| macOS | 26.6.2，build 25G83；桌面锁定状态来自任务及控制文件，未操纵锁屏 |
| 硬件 | Mac16,6 / arm64 / Apple M4 Max / 16 logical CPUs / 68,719,476,736 bytes RAM（64 GiB） |
| 工具 | Xcode 26.4.1，build 17E202；独立 driver tests 用 `/usr/bin/python3` 3.9.6 |
| 实际 Release 身份 | 上述最终 E2E binary / frozen source SHA；运行 PID 31397 |
| 实际 corpus 形状 | 9记录：source text 5、HTML 1、RTF 1、image 1、file 1；primary text 6、HTML 1、image 1、files 1；7个单 item + 2个四 item；另外1条65,536-byte文本失败，不计入成功 corpus |
| retention | 实际 launch telemetry：maxItems=200000；maxImageBytes=2147483648；maxTotalBytes=4294967296 |
| 运行时长 | 4.440881708秒，为整个失败 smoke 的墙钟时间，包含 launch/helper/捕获/退出/证据复制，不是任何查询或 panel 延迟 |

原始环境命令和输出为 `E/initial-commands.json`、`E/macos.stdout.log`、`E/hardware.stdout.log`、`E/xcode.stdout.log`、`E/python.stdout.log`。9条原始 capture socket roundtrip 样本及 nearest-rank 汇总在 `E/smoke-measurements.json`：p50=23.990375 ms、p95=p99=339.907542 ms。这包括 fixture 构造、观察/入库/验证和 IPC，混合自然/forced read，样本量小；**只是捕获控制请求耗时，不用于下面任何性能门槛**。

| 验收指标 | 目标 | 本轮样本数 | 实测 p50/p95/p99 | 状态 |
|---|---|---:|---|---|
| hot-panel-ready | p95 ≤100 ms | 0 | 未测 | BLOCKED |
| 10k search | p95 ≤100 ms | 0 | 未测 | NOT RUN；visible UI另受锁屏阻塞 |
| 100k search | p95 ≤200 ms | 0 | 未测 | NOT RUN；visible UI另受锁屏阻塞 |
| 1k mixed-history search | 未提供额外目标 | 0 | 未测 | NOT RUN |

**没有收集到真实查询或 panel 延迟样本。** Package scale 的38.820秒套件耗时及 App RuntimeScale 的4.139秒套件耗时没有被用作查询 latency；其源码内单次宽松耗时断言也不能证明上述 p95 目标。

typed rusage helper 对准确 E2E PID/executable 取得1个基线（`E/runtime-smoke.jsonl:4`）：RSS=71,696,384 bytes；physical footprint=17,220,472 bytes；累计 CPU=95,961,166 ns；interrupt wakeups=12；process bytes written=53,248。CPU为Mach ticks按125/3换算。由于P1中止，没有终点配对样本，CPU使用率、峰值内存、写入增量/速率、wakeups速率均**未测**。queue depth/bytes 与即时 WAL metrics 尚未采样；复制保留的WAL文件是退出后的现场，不是写入量或运行时延迟证据。maintenance queue、whole-device writes 不以0替代不可用数据。

**尚未解除的验收阻塞与交回 root**

1. **E2E-G2-P1-001 OPEN**：有效65,536-byte请求的控制传输失败；本轮只有一次运行，root应保留上述原始异常并在后续授权修复阶段确认分段socket收发边界。源码保持冻结，本执行者没有修复权限，也没有实施修复。
2. GUI锁定使panel、ordinary/plain recipient paste、cancel、preview及真实外部应用互操作无法执行。不能用后台捕获或named-board unit copy替代。
3. 进程重启后稳定ID/格式校验、实际search samples、1k/10k/100k mixed workload以及24h/72h持续监测均未完成。
4. 完整Package TSan crash-child失败保持FAIL；macOS14无环境，保持NOT RUN。

允许写入的报告和证据已完成；所有产品源码、测试、project设置、脚本、CI及其他文档未修改。复核最终inventory仍为冻结SHA/515项。**向root交回状态：执行已因P1停止；当前generation不能通过完整E2E验收。**
