# Mac Clippy

[English](#english) · [中文](#中文)

A native macOS clipboard manager. Copy once — find it again in a keystroke.

原生 macOS 剪贴板管理器。复制过的内容，按一下快捷键就能找回。

---

## English

macOS keeps one clipboard item. The next copy overwrites it. Mac Clippy sits in
the menu bar and remembers what you copied — text, links, images, rich text,
and files — so you can search, pin, transform, and paste it again.

Open the dock with **⌘⇧V** (customizable) or the menu bar icon. Type to search.
Return pastes. It is built as a local Mac app: no account, no iCloud sync, no
clipboard server.

### Why it exists

- **Nothing useful gets overwritten.** History is captured as you copy.
- **Find it in seconds.** Search the body, the name you gave it, the source app,
  or text inside screenshots (OCR).
- **Keep the things you reuse.** Pinboards hold snippets, URLs, and assets that
  should not scroll away with history.
- **Paste the way you work.** Single paste, plain text, multi-select, or queue
  paste in order for forms.
- **Private by default.** Payloads stay on this Mac, encrypted, with conservative
  capture rules for passwords and excluded apps.

Universal Clipboard from a nearby iPhone can still land in history — that is
Apple Continuity writing to the Mac pasteboard, not an app sync. See
[Cross-device clipboard](#cross-device-clipboard).

### What you can do

| Area | What it does |
|---|---|
| **History** | Text, HTML, RTF, images, and files, with source-app badges and previews |
| **Search** | Words, CJK, `"quoted phrases"`, `clip*`, plus `type:`, `app:`, `name:`, `has:ocr` |
| **Pinboards** | Colored categories you can drop items onto and filter from the rail |
| **Snippets** | Named expansions with optional triggers |
| **Transforms** | Case, whitespace, pretty JSON, and similar text cleanup |
| **Preview** | Space for Quick Look-style preview; select OCR text on images |
| **Privacy** | Skip concealed, transient, and auto-generated pasteboard types; exclude apps |

### Get a build

Download the latest DMG from the
[nightly release](https://github.com/wangm12/mac-clippy/releases/tag/nightly)
or build one locally:

```sh
make dmg
```

Open `dist/MacClippy.dmg`, drag `MacClippy.app` to Applications, and launch it
from Finder. Clipboard capture works immediately. Automatic paste and snippet
expansion need Accessibility; without it you can still copy out and paste
manually.

Signing and first-launch Gatekeeper notes are in
[Signing and permissions](#signing-and-permissions).

### Search grammar

History and Pinboard understand:

- Bare words and CJK substrings
- Quoted phrases and prefix matches such as `clip*`
- Filters: `type:text`, `type:image`, `type:url`, `type:files`, `app:`, `name:`,
  `has:ocr`, and date filters

Snippets search name and trigger only. A lone `type:` or date filter explains
that those apply to History and Pinboard. A mixed query such as
`hello type:text` still matches snippet text for `hello`.

---

## 中文

系统剪贴板一次只能放一条，再复制就被覆盖。Mac Clippy 待在菜单栏里，把你复制过的
文字、链接、图片、富文本和文件记下来，方便搜索、钉住、变换，再贴回去。

默认快捷键是 **⌘⇧V**（可在设置里改），也可以点菜单栏图标。打开后直接打字搜索，
回车粘贴。这是本机应用：没有账号，不同步 iCloud，也不把剪贴板传到任何服务器。

### 它解决什么问题

- **有用的内容不会被下一条覆盖。** 复制即记录。
- **几秒内找到。** 可以搜正文、你起的名字、来源 App，或截图里的字（OCR）。
- **常用的单独放。** Pinboard 用来钉住片段、链接和素材，不会跟着历史被挤走。
- **按你的方式粘贴。** 单条、纯文本、多选，或按顺序 Queue paste 填表。
- **默认就偏隐私。** 内容只存在这台 Mac 上并加密；密码管理器和排除的 App
  默认不采集。

附近 iPhone 通过「通用剪贴板」拷到这台 Mac 的内容，仍可能进入历史。那是
Apple Continuity 写进系统剪贴板，不是 App 自己做同步。详见
[Cross-device clipboard](#cross-device-clipboard)。

### 你能做什么

| 能力 | 说明 |
|---|---|
| **历史** | 文本、HTML、RTF、图片、文件，带来源 App 图标和预览 |
| **搜索** | 关键词、中日韩、`"精确短语"`、`clip*`，以及 `type:` / `app:` / `name:` / `has:ocr` |
| **Pinboard** | 带颜色的分类，可拖入条目，也能从顶部筛 |
| **片段** | 可命名、可设触发词的 Snippet 展开 |
| **变换** | 大小写、空白、JSON 格式化等 |
| **预览** | 空格预览；图片可框选 OCR 文字 |
| **隐私** | 跳过隐蔽 / 临时 / 自动生成的剪贴板类型，并可排除 App |

### 获取安装包

从
[nightly release](https://github.com/wangm12/mac-clippy/releases/tag/nightly)
下载最新 DMG，或本地构建：

```sh
make dmg
```

打开 `dist/MacClippy.dmg`，把 `MacClippy.app` 拖进「应用程序」，再从 Finder
启动。采集剪贴板不需要额外权限。自动注入粘贴和片段展开需要「辅助功能」；
没有权限时，仍可复制出来再手动粘贴。

签名和首次打开 Gatekeeper 的说明见
[Signing and permissions](#signing-and-permissions)。

### 搜索语法

历史和 Pinboard 支持：

- 普通词和中日韩子串
- 引号短语、以及 `clip*` 这类前缀
- 过滤器：`type:text`、`type:image`、`type:url`、`type:files`、`app:`、
  `name:`、`has:ocr`，以及日期

片段只搜名称和触发词。单独写 `type:` 或日期过滤器时，会提示这些只作用于历史
和 Pinboard。像 `hello type:text` 这样的混合查询，片段仍会按 `hello` 匹配。

---

## Installation

Build a DMG from source:

```sh
make dmg
```

The result is written to:

```text
dist/MacClippy.dmg
```

Open the DMG, drag `MacClippy.app` to `Applications`, and launch it from
Finder. Clipboard capture works locally. Automatic paste injection and snippet
expansion require macOS Accessibility permission; without it, Mac Clippy keeps
the clipboard available for manual paste.

Signing, first-launch Gatekeeper, and why permissions used to reset on every
update are documented in [Signing and permissions](#signing-and-permissions).

## Privacy and storage

Clipboard data is stored locally in:

```text
~/Library/Application Support/MacClippy/
```

Clipboard payloads and image blobs are encrypted with a device key stored in
the macOS Keychain. Search metadata is kept separately to support fast search.
Conservative capture exclusions are enabled by default, and additional app and
text exclusions can be configured in Settings.

## Cross-device clipboard

Mac Clippy does not sync history through iCloud and has no iPhone app. A copy
made on a nearby iPhone can still appear in this Mac's history because
[Universal Clipboard](https://support.apple.com/en-us/102430) writes that item
onto the Mac pasteboard. Mac Clippy then records it like any other local copy.

That handoff is Apple Continuity, not an app network call. It works when:

- Mac Clippy is already running. A copy that lands before launch is not
  captured; `start()` ignores the pasteboard generation already present.
- Both devices use the same Apple Account, are about 10 meters apart, and have
  Handoff, Wi-Fi, and Bluetooth on.
- Capture is not paused, and the Mac frontmost app is not an excluded password
  manager.

To verify: leave Mac Clippy running, copy text on iPhone, paste with
Command-V on the Mac, then confirm a new history row. Repeat with an image.
If paste works but history does not, inspect the pasteboard types (for example
with [Pasteboard Viewer](https://github.com/sindresorhus/Pasteboard-Viewer))
before changing capture rules. Do not add `com.apple.is-remote-clipboard` to
ignored pasteboard types.

## Development

Requirements:

- macOS 14 or later
- Xcode 26 or later
- XcodeGen (`brew install xcodegen`)

Run these commands from the repository root:

```sh
# Generate the Xcode project from project.yml
make generate

# Build the Debug app
make build

# Run Swift package and app tests
make test

# Run SwiftLint with the checked-in no-new-violations baseline
make lint

# Build and launch the Debug app
make run

# Run the complete CI-style build and test flow
make ci
```

`MacClippyKit` uses Swift Package Manager and fetches GRDB.swift automatically.
Build products and package caches are written to `.build/` and are ignored by
Git.

## Signing and permissions

macOS TCC (Accessibility, Input Monitoring) is bound to the **code-signing
identity**, not the bundle ID or the fact that the app is still named Mac
Clippy. An unsigned or ad-hoc build is identified by a hash of that exact
binary. Rebuild or replace the app and the hash changes. System Settings can
still show the old row as enabled while the new copy is a different app, so
you have to remove the entry and add it again.

That is why every update used to require removing and re-adding permissions.

### What this repo does

This project uses a **stable self-signed certificate** (not an Apple Developer
Program certificate, and not notarization).

| Path | What you get |
|---|---|
| Unsigned / ad-hoc (`codesign -s -`) | App can run after a Gatekeeper bypass. Permissions reset on every update. |
| **Stable self-signed (this repo)** | Same identity on every `make dmg` and on GitHub Releases that import the same `.p12`. Permissions persist. First launch still needs a Gatekeeper bypass. |
| Apple Development | Free Xcode identity. Persists on **your** Mac only. Cannot notarize. Cannot be shared as the GitHub Release identity unless you export it. |
| Developer ID + notarization (`make release`) | Double-click works for other people. Permissions persist. Requires the $99 Apple Developer Program. |

Ad-hoc signing is not used as the default. It avoids the “app is damaged”
dialog but does **not** keep TCC grants.

The certificate is named `Mac Clippy` and uses team id `MCLIPPY001`. The
designated requirement becomes the certificate leaf, so later binaries signed
with the same cert keep the grant.

This is **not** notarized. Other people’s first launch is still blocked by
Gatekeeper. Self-signing never removes that.

Do not reuse this certificate for other apps. VoiceFlow has its own identity
(`VoiceFlow` / `VOICEFLOW1`).

### Create the certificate once

```sh
make signing-cert
```

macOS may ask for the login keychain password so `codesign` can trust the
cert. The private key is written to gitignored files:

```text
.build/signing/MacClippy.p12
.build/signing/MacClippy.p12.base64
.build/signing/password.txt
```

Never commit those files. If the identity already exists, the script exits
without creating a second one.

`make dmg` calls the same path when the `Mac Clippy` identity is missing, so
the first DMG build can also create it.

### Build and install a signed DMG

```sh
make dmg
```

Identity preference when `DEVELOPER_IDENTITY` is unset:

1. `Mac Clippy` self-signed (so local DMGs match GitHub Releases)
2. Developer ID Application
3. Apple Development

Override with `DEVELOPER_IDENTITY` and `DEVELOPMENT_TEAM`.

Install only one copy. Grant permissions to `/Applications/MacClippy.app`.
`make run` / Debug builds stay unsigned (`CODE_SIGNING_ALLOWED=NO`). Daily
Xcode or `make run` overlays will still reset TCC.

### First launch (Gatekeeper)

A downloaded or copied app gets `com.apple.quarantine`. Without notarization
macOS may say it cannot verify the developer, or (if unsigned) that the app
is damaged.

1. System Settings → Privacy & Security → Open Anyway
2. Or clear quarantine for this app only:

```sh
xattr -dr com.apple.quarantine /Applications/MacClippy.app
```

Do not turn Gatekeeper off globally.

### Switching from an unsigned copy

If Accessibility or Input Monitoring already look granted but the signed app
does not work, the old hash-based row is stale. Reset once, then grant again:

```sh
tccutil reset Accessibility com.macallyouneed.macclippy
tccutil reset ListenEvent com.macallyouneed.macclippy
```

Replace `/Applications/MacClippy.app` from a DMG signed with `Mac Clippy`,
open it, and grant access. Later updates signed with the same certificate
should keep the grant.

Settings will warn when the running copy is unsigned or ad-hoc, and tell you
to run `make dmg` and replace the app in `/Applications`.

### GitHub Releases

The Release workflow runs `make dmg` on every branch push (and can be run by
hand from **Actions → Release**). Ordinary pushes update the rolling `nightly`
prerelease. A `vX.Y.Z` tag still publishes a stable release. `dist/` is
gitignored; the runner builds a fresh DMG.

For those published updates to keep TCC, GitHub Actions must sign with the
**same** certificate:

```sh
make signing-cert
gh secret set MACOS_CERT_P12 < .build/signing/MacClippy.p12.base64
gh secret set MACOS_CERT_PASSWORD --body "$(cat .build/signing/password.txt)"
```

Push any branch to refresh `https://github.com/wangm12/mac-clippy/releases/tag/nightly`.

```sh
git tag v1.0.0
git push origin v1.0.0
```

A version tag creates `https://github.com/wangm12/mac-clippy/releases/tag/v1.0.0`
with `MacClippy.dmg`. Re-running the same tag replaces the asset.

Without those two secrets the workflow still publishes a DMG, but it is
unsigned and permissions will reset on every download.

On GitHub Actions the job will not mint a new certificate. A new cert every
run would silently break TCC for everyone.

### Optional Developer ID and notarization

Double-click-without-warnings for other users still needs the paid program:

```sh
DEVELOPER_IDENTITY="Developer ID Application: Your Name" \
DEVELOPMENT_TEAM="TEAM_ID" \
NOTARY_PROFILE="stored-keychain-profile" \
make release
```

That is archive → signed DMG → notarize / staple / Gatekeeper. It is separate
from the default self-signed `make dmg` path.

### Scripts

| Script | Role |
|---|---|
| `scripts/make-signing-cert.sh` | Create the `Mac Clippy` identity once; export `.p12` |
| `scripts/select-codesign-identity.sh` | Prefer self-signed, then Developer ID, then Apple Development |
| `scripts/resolve-dmg-signing.sh` | Create the cert locally if needed; print identity + team |
| `scripts/import-signing-cert.sh` | Import `MACOS_CERT_P12` on the Release runner |
| `scripts/select-codesign-identity-test.sh` | Fixture tests for identity preference |

`make test` and CI run the identity selector tests.

## Project layout

```text
MacClippy/             macOS application and dock UI
MacClippyKit/          Core storage, capture, search, paste, and platform code
MacClippyTests/        Application-level XCTest target
MacClippyUITests/      macOS UI XCTest smoke and interaction target
scripts/               Self-sign, DMG packaging, verification, and notarization
project.yml            XcodeGen project definition
```

## License

This project is currently distributed without a public license.
