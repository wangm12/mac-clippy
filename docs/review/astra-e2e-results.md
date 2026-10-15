# Phase 6 独立 E2E / 性能验收记录

版本：0.4，2026-09-25，control revision 11 交接快照。执行者：独立 Astra E2E/test lane。**本轮按 root 指令结束并交接，不是最终验收。** 只修改本报告和指定原始证据目录，未修改实现、测试、项目或发布配置；未 commit/push/tag/publish。

## 当前结论与交接

**发布判定：NOT READY。** control revision 11 报告尚有 **4 个未解决 P1、5 个 P2，0 个已报告 P0**：ASR-P1-001/002/003/004、ASR-P2-001/002/003/004/005。问题由独立源码审查者报告并由 root 登记，本执行者尚未进行修复后的独立复现/回归；全量测试通过不能抵消缺失覆盖。当前 Luna 正在修改受影响实现，执行侧已释放 lane。

已按控制文件释放 build/test/app lane。generation 1 的 Package 和 App 批次均正常结束，独立 CPU probe 正常退出。没有活动的自有 E2E app、benchmark、UI runner 或 soak。没有启动后续产品批次。revision 11 要求本轮结束，由 root 在下一稳定 source_generation 重新启动执行者；本报告及原始证据是交接入口。

| 严重度 / ID | 触发与后果 | 来源与状态 | 建议回归 |
| --- | --- | --- | --- |
| P1 / ASR-P1-001 | 真正旧 schema 的 format-1 backup 不含 `representation_refs_auth`；`MacClippyBackup+KeyValidation.swift:225` 无条件查询 migration 010 列，可能拒绝正确密钥的旧备份。原 legacy 测试仅降低 manifest 版本，未回退 schema。 | control revision 4，源码审查者证据 `/tmp/astra-source-review-findings-g1.json`；执行侧尚未独立复现，等待 Luna 修复及稳定冻结。 | 用历史 DDL/真实旧 schema、正确与错误密钥、缺失 blob、legacy spilled representations 分别验证只读认证、restore/reopen 和 fail-closed。 |
| P1 / ASR-P1-002 | `MacClippyPasteInjector+Injection.swift:115`：写板后 permission/focus callback 可引入新 generation，但随后仍可能 Delete/Paste；失败写入后的 cancellation 还可能把任意当前 generation 当作自己写入并覆盖较新 copy。 | control revision 6，源码审查者静态发现；执行侧动态复现尚未运行。 | 成功写入需显式携带 generation 到 commit/rollback；命名板回归应在 trust/context callback 和失败 write callback 注入外部写入，检查无错贴/误删/覆盖。 |
| P1 / ASR-P1-003 | `MacClippyE2EControlRequests.swift:189`：capture/verify-record 只接受 `.present` representation；默认语料 index 4 超过 32 KiB inline 阈值，会 spill，导致所有默认 scale corpus 在第五条失败。 | control revision 8，源码审查发现；执行侧尚未运行 corpus，不能将该问题误记成已复现运行失败。 | 使用有界、认证、带 lease 的 BlobStore 读取验证原始 bytes；保留 65,536 字符 fixture 和原生产 spill 阈值。 |
| P1 / ASR-P1-004 | `scripts/e2e/macclippy-phase5.py:2246`：`consume_extend_request` 在请求存在时没有实现；extension 逻辑位于 `consume_stop_request` 的 return 之后，无法执行。 | control revision 10/11；执行侧动态 worker extension 尚未运行。 | owner/run 校验、消费请求、72h cap；实际 detached worker 接受 extension 的回归，不能只测试写入请求文件。 |
| P2 / ASR-P2-001 | `PasteboardObserverLifecycle.swift:136`：重试使用初始 snapshot、但缩小 UTI 集合，可能丢掉前一轮已恢复的 representation。 | control revision 8；待修复与独立运行。 | 分轮到达的 A/B providers；multi-item/repeated UTI；最终完整 payload。 |
| P2 / ASR-P2-002 | `MacClippySnippetExpander+Input.swift:224`：trigger anchor 使用 200 ms 采样 caret；快速前文后接分号 trigger 可能被误取消。 | control revision 8；待修复与独立运行。 | fast preceding text + trigger，同时保持真正 focus/caret/input-generation 变更时 fail-closed。 |
| P2 / ASR-P2-003 | `MacClippyDockModel+QueueActions.swift:45`：旧 queued paste 的 progress/completion 在 generation/token guard 之前修改新打开 session 的进度。 | control revision 10/11；执行侧尚未运行新增回归。 | 延迟旧 callback，close/reopen 新 session 后释放旧 callback，断言新进度与剩余 ID 不被修改。 |
| P2 / ASR-P2-004 | `scripts/e2e/macclippy-phase5.py:1648`：preview 固定 120 s timeout 小于 1,000 次正常 130 ms close animation 的总时长。 | control revision 10/11；1,000 cycles 未运行。 | 有界工作量感知 timeout 或准确计数的分批；保留真实 animation/readiness 条件。 |
| P2 / ASR-P2-005 | `MacClippyRuntimeModels.swift:152`：representation details identity 仅用 UTI，丢失 itemIndex，重复 UTI 会产生重复 ForEach ID 和无法区分的状态。 | control revision 11；执行侧尚未运行新增回归。 | 从 Runtime 到 spilled details/UI 保留 item identity/ordinal，验证跨 item 同 UTI 的独立行与状态。 |

## 身份、环境和证据

证据根目录：`/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925`。每代源码及每次尝试分目录保留；没有复制 disposable device key。

| 项目 | 实测值 |
| --- | --- |
| base commit / branch | `79e987a982f15f9193392c9af98b66465efd5ee2` / `codex/core-reliability-hardening` |
| generation 1 源码摘要 | `24cdd86ab8febb30814a72670f85ab3534fe41fca2c311a4a8e604edec1e0b18`；506 个 tracked/untracked 构建输入 |
| dispatch Release app | `/tmp/macclippy-phase5-e2e-release-structural-final/Build/Products/Release/MacClippyE2E.app` |
| dispatch executable SHA-256 | `948efb789b582e8c0a8c8cd4f46075538c58d22de7792f8a852f17e13f2b1ea8` |
| 内嵌身份 | `com.macallyouneed.macclippy.e2e` / `Release`；Info.plist 的源码摘要与冻结 manifest 一致 |
| macOS | 26.6.2，build 25G83 |
| Xcode / Swift | Xcode 26.4.1，17E202；Apple Swift 6.3.1，arm64 |
| 硬件 | Mac16,6；16 CPU；68,719,476,736 bytes（64 GiB） |
| pinned tools | XcodeGen 2.45.4；SwiftLint 0.63.2 |
| 桌面 | control revision 3/4：locked。没有尝试解锁或绕过锁屏。 |

原始身份：`generation-1/dispatch-identity-environment.json`、`generation-1/source-manifest-dispatch.json`。每个批次包含 `command.json`、前后源码验证、前后 control 快照、最长每 10 秒的 control 观测、stdout/stderr 和 `result.json`。`phase6_batch.py` 是证据目录中的独立执行包装器，不改变产品源码。源码检查逐文件比较 SHA-256；E2E 启动仍须通过原 runner 的完整 manifest 重算和内嵌摘要检查。

`agent_message` bridge 最初报告 tunnel-client 离线；control revision 3 明确改由普通 commentary/final 的 JSONL `agent_message` 传递给 root。已遵循该规定，通信故障没有被计作产品或宿主测试失败。

## 已执行批次

所有命令 cwd 都是 `/Users/mingjie/Documents/github/personal-projects/mac-clippy`。本代源码前后验证无差异；没有生成/改写 Xcode 项目。

| 批次 / 配置 | 状态 | 实际结果与范围 | 原始证据 |
| --- | --- | --- | --- |
| Package 全量 / Debug | PASS | 627 tests，4 skipped，0 failures；测试约 6.830 s，命令含构建约 7.892 s。跳过项不能算通过。 | `generation-1/package-full-01/` |
| App unit 全量 / Debug | PASS | 414 tests，2 skipped，0 failures；测试约 16.569 s，命令含构建约 50.368 s。只选 `MacClippyTests`。 | `generation-1/app-full-01/`、`generation-1/app-full-01.xcresult` |

精确命令（包装器参数和全部 argv 亦保存在各 `command.json`）：

```sh
swift test --package-path MacClippyKit

xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy \
  -configuration Debug -destination platform=macOS,arch=arm64 \
  -derivedDataPath build/hardening-phase6-20260925/generation-1/DerivedData-App \
  -resultBundlePath build/hardening-phase6-20260925/generation-1/app-full-01.xcresult \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
  -only-testing:MacClippyTests -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
```

Package 默认跳过两个 scale、10,000-cycle lifecycle stress 和 child-only crash worker 入口；父测试会以私有请求实际启动该 child 入口。App 默认跳过 RuntimeScale 和 real-input-tap。实际 opt-in 执行尚未发生，不能用默认 suite 的成功替代。各批次的 `test-cases.json` 分别提取了 627 和 414 条 testcase 状态/耗时，与总数一致。

generation 1 初始两个测试批次没有在结束时另行保存 Package 测试可执行文件哈希；不补录已可能被 Luna 重建的共享 `.build` 并冒称原二进制。独立 App DerivedData 和 xcresult 保留完整。后续包装器已增加执行完成时保存 product/test executable/dylib 哈希；benchmark 则必须再次通过源码 manifest、内嵌摘要、实际 PID/executable 的完整关联检查。

## 验收矩阵（当前快照）

| 场景 | 状态 | 当前证据和缺口 |
| --- | --- | --- |
| 1. 隔离生产 capture → restart → search → normal/plain paste，多种格式与 item identity | NOT RUN | 本代 Release E2E 尚未启动。Package/App 的 representation 回归通过，但不能代替整个链路。 |
| 2. TextEdit / Safari / Terminal / Finder 实际接收 | BLOCKED | 桌面 locked，且尚未由 root 通过正常 UI 暂停 installed app capture。未碰 `.general` 或任何用户文档/窗口。 |
| 3. generation churn、延迟/缺失 provider、超限、重试、混代、overload | PASS（回归层） | Package 的真实命名 pasteboard provider 与 App backpressure 测试执行；不代表真实第三方 provider 的全覆盖。 |
| 4. snippets 跨应用/field、输入序列、Esc/stop/close/reopen | PASS（模拟上下文回归）；BLOCKED（真实应用） | context cancellation、accepted commit 和 deferred input 的测试回调路径执行；没有真实目标插入或删除证据。 |
| 5. 实际权限 revoke/restore、sleep/wake、lock/unlock、显示器变化 | NOT RUN | 未更改 privacy、锁屏、显示器；模拟通知/信任回调不能计作实际系统事件。 |
| 6. backup / restore / I/O faults / child death | PASS（现有回归）；FAIL（旧 schema 覆盖缺陷待修复） | 已读 crash launcher、worker verifier：独立子进程死亡后在新进程恢复，随后实际打开数据库、验证 ID、body、representation/blob 解密、search、pinboard/snippet。不是仅 manifest 存在检查。ASR-P1-001 未解决。断电耐久性 NOT RUN。 |
| 7. >256 deletion、共享附件、pin、migration、reconciliation/search repair | PASS（现有回归）；NOT RUN（独立长时 UI 验证） | 全量 Package/App 覆盖相关真实 store/runtime 路径；尚无独立 UI stall 分布。 |
| 8. 1k/10k/100k mixed corpus、1,000 panel/preview cycles、Release 性能/资源 | NOT RUN | 尚未生成本代 corpus 或执行独立计时。100/100/200 ms 均是目标，不是测量结果。 |
| 9. Package/App/RuntimeScale/TSan/Swift 6 Release | PASS（前两项）；NOT RUN（其余） | 上表记录实际全量执行；opt-in、TSan 和 Swift 6 Release 待稳定 generation。macOS 14 实机执行按用户指示为 NOT RUN。 |
| 10. durable mixed-load soak，24h / 72h | NOT RUN | 本执行者尚未启动 smoke 或长跑。最终长跑必须等 root 宣布源码与短测试修复完成。Phase5 的短 smoke 不归入本代独立证据。 |

## 已独立检查的隔离与生产边界

- `MacClippyE2EIsolation.makePasteInjector` 同时提供 `postEvents` 和 `postEventsToProcess`；后者仅接受 `getpid()`，两者都落到命名板的内部 recipient。fake trust 不会授权真实 OS keystroke。仍需执行显式 PID 回归及本代 E2E route 断言。
- `MacClippyUITests` 指定 `.e2e` bundle，要求 marked root/run；`project.yml` 将依赖指向 `MacClippyE2E`。本次 App suite 只选 unit target，未启动 UI test。
- App XCTest host 在启动时跳过生产 Runtime 启动；使用明确 paths 的 Runtime 默认使用 in-memory key backend。已检查关键生产/测试 paste 路径的命名板与假事件回调。没有对 installed app 进行生命周期或存储操作。
- E2E PNG 以完整 SHA-256 digest 填充像素；corpus runner 要求 unique record ID 数量等于请求数量，并分别记录 `sourceFormatDistribution` 与 `primaryContentKindDistribution`。RTF 可由 AppKit 合成 text primary，保存原 RTF bytes 的断言仍保留；尚待本代 corpus 实测。
- `PathsDatabase` independent reader lease 覆盖读连接生命周期；`closeForReplacement` 拒绝新 reader 并等既有 reader 退出。Blob lease registry 按 canonical root 共享，release 只调用后续回查回调，不自行 unlink。完整 source review 由另一 Astra 持有，本报告不把阅读本身写成运行通过。
- provider 200 ms deadline 阻止后续同步调用/重试；无法强制打断已进入的同步 AppKit provider。已有真实命名板测试覆盖 late valid result、generation churn 与 cancellation；不宣称硬实时上限。

## 独立 ARM 资源计数器审计

**PASS。** control revision 7 明确授权在产品 mutation 期间单独运行不依赖 App/Package 的 probe。精确命令：`python3 build/hardening-phase6-20260925/metric_sanity.py`；该脚本将原 sampler 和独立 C child 以 `clang -std=c11 -O2 -Wall -Wextra -Werror` 编译到证据目录。没有修改 sampler，也没有启动产品 Runtime。仅查询自有 PID 31919 和精确 executable path；child 正常退出 0。

证据：`generation-1/metric-sanity-data/` 中的原始计数、两个 build JSON、command、control 前后快照及 `result.json`；独立 probe 源码为 `metric_sanity.c` / `metric_sanity.py`。

| 核验 | 实际观察 |
| --- | --- |
| CPU timebase | `mach_timebase_info = 125/3`；sampler CPU 增量 **2.011163292 s** |
| 独立参照 | `getrusage = 2.011149 s`；`CLOCK_PROCESS_CPUTIME_ID = 2.011153 s` |
| 一致性 | sampler / getrusage = **1.000007106**；与两秒有界忙计算一致 |
| RSS / physical footprint | 工作后 RSS **35,045,376 B**；physical footprint **34,636,112 B**，是不同字段，未互相替代 |
| interrupt wakeups | 50 次 1 ms 定时等待后计数 **0 → 50** |
| package idle wakeups | **0 → 0**；只报告采样值，未推断整机无唤醒 |
| process writes | 基线 `null / unknown-zero-or-unavailable`；写入并 fsync 8 MiB 后 **8,388,608 B / available** |
| source 身份 | sampler 前后 SHA-256 均为 `73d6d03dc2cd105ecd8ea4a88acba3e29bf6125e05b7cc2dd01f6abb3d610749` |

上述数据仅验证计量单位和可用性，不是 MacClippy 性能测量。整机写入和 maintenance queue depth 仍 unavailable。

后续 DB-only 适配器已准备在证据目录 `db_only_probe.py`，**尚未执行**。它调用现有 authenticated control API、原 `run_corpus` 和原 query contracts，保留每类查询的 limit 16/512 原始分布、实际数据库保留条数与资源数据；不会放宽 visible-readiness 或将 DB latency 冒充交互性能。

另已向 root 请求隔离 API 的具体缺失能力：按稳定 `recordID` 验证重启后的图片和有序原生 `(itemIndex, uti, payloadState, byteCount, SHA256)`；paste recipient 也需保留原生 items，不能只凭文本包含 query 证明 image/files paste。generation 1 的 `verify-record` / paste 均依赖 preview query，内部 recipient 只提取文本；这些缺口未被现有 API 证明，不列为 PASS。control revision 11 已将该范围交给 Luna，下一执行者须重新检查冻结后的 API。

## 下一冻结代次的执行交接

1. 读取 `/tmp/macclippy-phase6-control.json`，必须是新的稳定 source_generation，且 `source_fix_pending=false`、`mutation_in_progress=false`；先检查全部已登记修复、新增测试与隔离路径，再执行批次。
2. 使用证据目录中的 `phase6_batch.py`。它每 10 秒读取 control，逐文件核验冻结 manifest，保存前后证据及 exact argv；新代次自动使用 `generation-N` 目录。每个 `--name` 是独立 attempt，已有目录不覆盖。Luna 或 root 仍拥有源码；执行者不得修复实现/弱化测试。
3. 重跑相关缺陷回归、Package/App 全量、actual opt-in PackageScale/RuntimeScale/lifecycle stress、Package/App TSan、Swift 6 Release；App unit 始终 `-only-testing:MacClippyTests`。RuntimeScale 同时传 `MACCLIPPY_RUN_SCALE_TESTS=1` 与 `TEST_RUNNER_MACCLIPPY_RUN_SCALE_TESTS=1`，并核对零 skip。
4. 核对 shipping Release 不含 E2E 控制端点/DEBUG 测试入口，保留工具固定版本。使用 root 指定的新 source-bound E2E executable，不得沿用 generation 1 app。
5. `db_only_probe.py` 是待执行的独立适配器，须先依据最终 driver/API 校验。它使用原始 1k/10k/100k 混合语料、seed 20260925、全部 query contracts 和生产 capture/Runtime search；按每类 30 次、limit 16/512 保存原始/汇总。额外以 mode=ro 查询隔离 `clipboard_records` 实际行数。不能替代 visible interactive 结果。先短批次，再昂贵 100k。
6. 新的按 recordID 验证与原生 recipient 能力应覆盖 text/CJK/emoji/HTML/RTF/image/files、多 item/repeated UTI、spill、重启后的有序字节哈希。验证 14485/53930 图片实际独立身份。正常/plain paste 要检查确实插入与实际原生内容；内部 recipient 仍不能充当 TextEdit/Safari/Terminal/Finder。
7. 桌面仍 locked 时不执行 GUI；真实 `.general` 必须由 root 正常 UI 暂停 installed capture 并负责恢复。保持 installed app 的历史、Keychain、preferences 不变。macOS 14 实际执行按用户指示继续 NOT RUN，不申请环境。
8. source reviewer 另登记 `SearchStore+RepairPages.swift:62` 为待测性能风险：LIMIT 限制异常输出，不限制 healthy rows 扫描，且 Runtime 持锁。需要 100k 实测/有界性复核，尚未确认延迟失败，不能盲目 PASS。
9. 先短 UI tests 并按 root/run 关闭自有实例，再验证 detached soak smoke、extension、mixed workload 的实际结果/错误断言与 raw 保存。未经 root 宣布短测及源码修复完成，不启动最终 24h/72h；任何实现更改重新计时。smoke、空等时间、sleep gaps 不计完成 soak。

保留文件：`phase6_batch.py`、`db_only_probe.py`、`metric_sanity.c`、`metric_sanity.py`；`generation-1` 中的两个完整测试日志、App xcresult/DerivedData、逐项 testcase JSON、dispatch identity/source manifest、CPU 原始数据、`lane-release.json`、control revision 8/11 快照。没有活动探针或自有 E2E root 需要终止，也没有 disposable key 被复制到证据。
