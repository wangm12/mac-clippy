**RELEASE BLOCKED — generation-3 independent E2E. P0=0, P1=1, P2=1, P3=0 newly confirmed.**

The required stop was triggered by **E2E-G3-P1-001**: the isolated Release E2E process exited after an incomplete control request's client disconnected. A separate **E2E-G3-P2-001** truncates replies for a deliberately configured 1 KiB receive buffer. Product execution stopped; root must return remediation to **gpt-6-luna/max**. These IDs are shared with the source report and must not be counted twice.

There were **two fresh isolated app runs**, each with 10 successful capture fixtures and 18 verified representations. This does **not** establish a complete E2E pass. Controlled reopen, post-restart proof/search and a fresh follow-up capture/search were planned but **NOT RUN** after the P1. Luna's preserved passing smoke is separate evidence and is not substituted for this reviewer's incomplete run.

**Identity, environment and safety**

Control revision 49 and all 518 build inputs were independently checked before execution, including fresh git enumeration and per-file bytes. Source SHA:

`e128200af9fe73bd5c3e29e69dcd7605a13dae21bc889ad1deeaa3d810fe3e5e`

Only this app was launched:

`/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/ReleaseE2EDerivedData/Build/Products/Release/MacClippyE2E.app`

Executable SHA: `0037effa3eff297428327fdbed547eeb2c589b5c80e793a7c991b6fc7f89baf5`. Bundle ID `com.macallyouneed.macclippy.e2e`, configuration Release, embedded source digest equals the frozen manifest. Both actual process pings also matched root/run/PID/executable/configuration/source identity. Artifact audit: [artifact-independent-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/artifact-independent-audit.json); source audit: [identity-start.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/identity-start.json), [build-manifest-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/build-manifest-audit.json).

Host: macOS 26.6.2 build 25G83; Mac16,6 / Apple M4 Max / 16 logical CPUs / 68,719,476,736 RAM bytes; Xcode 26.4.1 build 17E202; Apple Swift 6.3.1; `/usr/bin/python3` 3.9.6. Exact environment commands/output: [environment-and-static-commands.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/environment-and-static-commands.json).

The production driver created a 0700 temporary root and unique UUID for each run. The E2E app used `com.macallyouneed.macclippy.e2e.<UUID>` named pasteboards and root-local 32-byte, 0600 disposable keys. Key material was never copied into evidence; only its hash/size/mode was recorded. The independent named-board reader validates the root marker/UID/run UUID before opening exactly that named board. No general pasteboard, installed app PID 50253, TCC, user clipboard/data, locked-desktop control, visible UI, or external recipient app was used.

**Exact execution inputs and evidence**

Working directory for all commands: `/Users/mingjie/Documents/github/personal-projects/mac-clippy`. All scripts below are reviewer evidence, not changes to product scripts/tests. The original driver was imported with bytecode writes disabled.

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B build/hardening-phase6-20260925/generation-3/astra-e2e/run-independent-e2e.py
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B build/hardening-phase6-20260925/generation-3/astra-e2e/run-independent-e2e-normal-buffer.py
```

The first command's stdout/stderr are `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/runtime.stdout.log` and `runtime.stderr.log`; its durable raw requests/responses/assertions are `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/runtime.jsonl`, `captures.json`, and `result.json`. The second command's stdout/stderr are `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/runtime-normal-buffer.stdout.log` and `runtime-normal-buffer.stderr.log`; its durable raw data are under `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/`. Exact input files are [run-independent-e2e.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run-independent-e2e.py) and [run-independent-e2e-normal-buffer.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run-independent-e2e-normal-buffer.py). Run2 uses the default receive buffer and additionally retains raw response bytes. It is a different experimental configuration; it does not overwrite or cancel run1's failure.

The read-only named-board helper was compiled with:

```sh
xcrun swiftc -module-cache-path build/hardening-phase6-20260925/generation-3/astra-e2e/module-cache build/hardening-phase6-20260925/generation-3/astra-e2e/named-board-proof.swift -o build/hardening-phase6-20260925/generation-3/astra-e2e/named-board-proof
```

Source/build log: [named-board-proof.swift](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/named-board-proof.swift), [named-board-proof-build.log](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/named-board-proof-build.log). It does not create `NSApplication` or open any window. It reads item-index/UTI/byte-count/SHA from the named board and requires a stable changeCount across the read.

**Actual capture and representation results**

For every one of the 20 total captures, the actual Release path was fixture→named NSPasteboard→production observer/mapper→Runtime persistence→authenticated `playbackSnapshot`/BlobStore proof. The reviewer checked stable unique recordID, synthetic source identity, item count, payload state, and every representation's `(itemIndex, UTI, byteCount, SHA256)` against an independent read of the named board. Direct text/HTML primary bytes also matched hashes calculated from the exact request; text/RTF decoded text matched the input. PNG/file records had `decodedText=null`. File data remained a reference; the root-local 4096-byte synthetic target's SHA/mode was checked separately, not claimed to be an imported file payload.

ASCII used natural observer polling. The other nine cases per run explicitly requested an immediate production observer read. RTF has primary kindtext and retains its native RTF plus UTF-8/UTF-16 representations; source format is not relabeled as stored primary kind. Repeated-UTI and custom-marker fixtures preserve four native items inside one record, not four selected clipboard records.

The second run's exact records are below; the first run has separate IDs/hashes in `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/captures.json`. Both runs passed all 10 capture assertions; all 18 representations per run had nonnull length/hash. Full proofs, including every hash, are in [captures.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/captures.json) and its paired named-board events in [runtime.jsonl](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/runtime.jsonl).

| Fixture | Record ID | Primary kind | Primary representation / bytes | Representations / native items / spilled |
|---|---|---|---|---|
| ascii-natural | `01M3EAP03W5YW2TQ3J2Y6KP0V5` | text | public.utf8-plain-text / 35 | 1 / 1 / 0 |
| cjk | `01M3EAP05KSRJERRG0ZM9QTQ5V` | text | public.utf8-plain-text / 42 | 1 / 1 / 0 |
| emoji | `01M3EAP06WSXJ86EKSHE5DZKY4` | text | public.utf8-plain-text / 53 | 1 / 1 / 0 |
| html | `01M3EAP0G27J2CNDSJPTEYFB9K` | html | public.html / 58 | 1 / 1 / 0 |
| rtf | `01M3EAP0K1QV6D0QVPJTVJGE5E` | text | public.rtf / 375 | 3 / 1 / 0 |
| image | `01M3EAP0M9TDWSWNB9NCB8RVKH` | image | public.png / 295 | 1 / 1 / 0 |
| file | `01M3EAP0NCRE9H6GN4MD588HHC` | files | public.file-url / 115 | 1 / 1 / 0 |
| repeated-uti-4-items | `01M3EAP0PG7ZTNG5ZNN7Q5YZDH` | text | public.utf8-plain-text / 42 | 4 / 4 / 0 |
| distinct-4-items | `01M3EAP0QN6KW3Z36HKYFYS7CQ` | text | public.utf8-plain-text / 45 | 4 / 4 / 0 |
| text65536 | `01M3EAP0RSMXA6NM5CT42EG43H` | text | public.utf8-plain-text / 65536 | 1 / 1 / 1 |


The 65,536-byte text is the full source text length, before JSON framing. A separate ping request was padded so the **entire newline-framed request was exactly 65,536 bytes**. Both distinctions are explicitly recorded; no fixture or spill threshold was reduced.

**Scenario-by-scenario execution**

| Scenario | Actual result | Evidence/limit |
|---|---|---|
| ASCII,CJK,emoji/ZWJ/combining/variation-selector,HTML,RTF,image,file,4-item repeated UTI,4-item distinct markers,long text | **PASS,10 per run** |20 captures,36 total representation comparisons. `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/runtime.jsonl:5` onward; `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/runtime.jsonl:5` onward. |
| Exact 65,536-byte framed request split at 29, 1024, 8192 bytes with 40/70/110 ms pauses | **PASS twice** | `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/runtime.jsonl:36`; `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/runtime.jsonl:37`. Full ping identity checked. This is actual accepted-socket behavior. |
| Same-process persisted long-record `verify-record` with delayed response reading | **PASS with normal buffer** | Run2 line 39: 66,183-byte complete response after 250 ms delay; raw decoded text and all representation proofs equal capture. This is not restart. |
| Small 1024-byte receiver buffer while draining a large response | **FAIL/P2** | Run1 result/line37; truncated JSON at server deadline. No full raw truncated buffer was retained by the first harness; production-helper reproduction provides exact bytes. |
| Invalid JSON and unknown command | **PASS, bounded rejection** | Run2 lines 41, 43 return `invalid-request`/`unknown-command`; no target-app paste involved. |
| Incomplete request with client still connected | **PASS, bounded timeout** | Run2 line 45 returns `invalid-request` after 10.004088542 s. |
| Incomplete request followed by immediate peer close | **FAIL/P1; actual process exit** | Run2 line 46→47. One failing trial; the planned repeat loop was never reached. |
| Controlled close/reopen, stableID/authenticated payload after restart | **NOT RUN** | Both runs stop before planned reopen. Run1's final shutdown is cleanup, not restart. |
| Post-restart database search; fresh follow-up capture/verify/search | **NOT RUN** | No independent `search-db` result was obtained. No directSQL seeding was used. |
| Ordinary versus explicit plain-text replay | **Existing non-UI test reviewed; no new execution** | See exact scope below; no real recipient insertion claim. |
| Provider churn/retry/cancel, queue/OCR/maintenance races, restore corruption/crash recovery, retention/index repair | **NOT RUN in this E2E pass** | Existing generation3 unit logs parsed; no new destructive or crash-child suite after P1. |
| Actual app/root/key cleanup | **PASS cleanup; P1 app exit remains a failure** | Owned PIDs absent, roots/keys absent, no key in copied evidence; details below. |
| macOS 14 | **NOT RUN — unavailable** | Deployment target/SDK text is not runtime coverage. |
| Real recipient apps, permission/lifecycle UI, visible panel/preview/1,000 cycles | **NOT RUN/BLOCKED** | Desktop locked by task/control record; no TextEdit/Safari/Terminal/Finder launch or synthetic UI claim. |
| 1k/10k/100k mixed benchmarks ; 24h/72h soak | **NOT RUN** | No long run or visible/interacting benchmark was started. |

**P1 evidence and source explanation**

PID 55199 at run2's authenticated identity exited after sending `{"command":` and closing its client socket. The following ping failed on an empty JSON response; the instance lock was released before cleanup. No shutdown request or external signal preceded this exit. [result.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/result.json) preserves the full exception and identity, and [independent-cleanup-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/independent-cleanup-audit.json) independently confirms PID/root/key absence.

The server at `/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyE2EControlServer.swift:334` ignores failure of `setsockopt(SO_NOSIGPIPE)`. Its read-error path at line 349 still sends `invalid-request` using production `MacClippyUnixSocketLineTransport.writeLine`. A separate child compiled with the unchanged transport source recorded `SO_NOSIGPIPE=-1, errno 22/EINVAL` on an already disconnected socket, then exit -13/SIGPIPE on send. **The actual app signal was not sampled**. SIGPIPE is the source-supported explanation, corroborated independently; actual app exit is directly observed. This is an E2E process robustness blocker, not proof of Shipping corruption.

Structured finding/stop record: [p1-stop-record.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/p1-stop-record.json). Source excerpts/hash copies: [finding-source-identity.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/finding-source-identity.json). No further app was launched after confirming the P1.

**Direct bounded transport probes**

A standalone helper compiled the actual production transport file directly, with only a socket fixture harness; it did not copy/reimplement transport logic, load the Shipping app, touch a pasteboard, or post events.

```sh
xcrun swiftc -module-cache-path build/hardening-phase6-20260925/generation-3/astra-e2e/module-cache -parse-as-library MacClippyKit/Sources/MacClippyPlatform/MacClippyUnixSocketLineTransport.swift build/hardening-phase6-20260925/generation-3/astra-e2e/socket-probe.swift -o build/hardening-phase6-20260925/generation-3/astra-e2e/socket-probe
/usr/bin/python3 -B build/hardening-phase6-20260925/generation-3/astra-e2e/run-socket-probes-v2.py
```

Exact source, commands and raw results: [socket-probe.swift](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/socket-probe.swift), [run-socket-probes-v2.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run-socket-probes-v2.py), [socket-probe-results-v2.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/socket-probe-results-v2.json). Additional option-return diagnostic: [socket-probe-option.swift](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/socket-probe-option.swift), [peer-closed-option-diagnostic.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/peer-closed-option-diagnostic.json). Twelve probe cases produced 10 expected bounded outcomes and two defects:

- 65,536-byte line across **three observed would-block boundaries**: exact bytes read.
- Three-byte exact limit accepted; fourth byte rejected; EOF returned nil; idle read returned nil in 0.082562875 s for an 80 ms deadline.
- Large write with no reader returned false in 0.080416125 s for an 80 ms deadline.
- Delayed readers with default 8192 or requested 2048/4096/8192 receive buffers each received 65,537 bytes including newline.
- Requested 1024 receive buffer, observed sender low-water 2048: only 8192 bytes/no newline, false at 0.702403375 s for a 700 ms deadline (**P2**).
- Write to an already closed peer: helper exited with SIGPIPE (**corroborates P1**).

Successful/error-return helper cases verified descriptor closure with `F_GETFD=-1/EBADF`. The signal-terminated child has no post-send cleanup assertion; process exit closes its descriptors. The initial probe runner stopped while trying to parse the signal-terminated child's empty stdout; its stderr is preserved at `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/socket-probe.stderr.log`. The v2 evidence harness records an absent helperJSON explicitly. No product fix or hidden passing replacement occurred.

**Ordinary/plain replay evidence boundary**

Reviewed `/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyTests/MacClippyRuntimeBatchRepresentations.swift:13` and its passing final raw result `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/app-unit-full.log:6585`. It captures through a real named-board reader/observer/Runtime, closes and recreates the Runtime **in the same test process**, searches the persistedID, then calls production `runtime.copy`. Ordinary replay verifies two items and ordered UTIs; text bytes are compared. Explicit plain replay verifies one item and the primary text. A neighboring seeded-record test additionally checks custom/HTML bytes and plain `.string`-only types. The preparer builds ordinary native items and explicitly maps `.text` to `.string`.

This is meaningful existing production-path test evidence, not a mirrored algorithm, but it is not an independently rerun Release scenario, a process restart, or a byte assertion for every rich representation at every replay stage. UTF-16 conversion types are explicitly excluded by the fixture's comparison helper. **No control response, synthetic recipient callback, or fake poster is reported as actual insertion into TextEdit or another recipient.**

**Raw gate counts and inherited evidence**

The source report and [raw-log-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/raw-log-audit.json) give exact absolute logs, hashes, terminal test names/line numbers. This reviewer did not rerun Package/App XCTest.

| Existing gate | Executed | Passed | Skipped | Failed tests |
|---|---:|---:|---:|---:|
| Package full |643|639|4|0|
| Socket focused |3|3|0|0|
| App unit |420|418|2|0|
| Thumbnail focused |8|8|0|0|
| App RuntimeScale opt-in |1|1|0|0|
| App TSan |420|418|2|0|
| Full Package TSan, generation2 |640|632|4|**4**|

Full Package TSan remains **FAIL**, with 94 failures/assertions including 1 unexpected and 73 interceptor errors. The filtered pass is not promoted. Default skips remain skips; a separate opt-in scale test is not mixed-history UI performance. Offline Python 37/OK and 8 packaging guard points were read, not rerun. Luna's `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/release-e2e-control-regression-final.json` and `restart-check-final.json` were read/hash-recorded and preserved, with their independent acceptance status explicitly not assumed.

**Cleanup and final boundary**

| Run | Root/run identity | End condition |
|---|---|---|
|1, PID 54683|`/private/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/mce5-37_sjo00`; `c4dcb95b-ae95-4a22-9a3c-cd0a257752f9`|Authenticated owned-socket termination after P2 in 0.174067125 s; lock released.|
|2, PID 55199|`/private/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/mce5-d431d05i`; `99d33aea-c60b-4a43-9ba5-0072f013ac66`|Unexpected exit during P1; no fallback signal or terminate request. Lock released before cleanup.|

After each app was absent/unlocked, the runner copied synthetic databases/blob/file/marker evidence **excluding the key**, verified copy hashes, then used the original driver's guarded `clean_root`. Exact file inventories/hashes: `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/root-copy-verification.json` and `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/root-copy-verification.json`. Neither root, key, copied key nor owned PID remained; independent read-only check: [independent-cleanup-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/independent-cleanup-audit.json). No soak was left running.

All observed timings above are functional socket/deadline or shutdown measurements on this host. There are **zero measured panel latency samples, zero search benchmark samples, and zero long-soak hours**; no MacClippy/competitor p95/p99 claim is made. Final source verification remains the frozen 518-file SHA; evidence and the two permitted reports are the only review outputs. **Hand back to root/Luna for remediation; restart/search/follow-up and the complete independent source review must be repeated after a new freeze.**
