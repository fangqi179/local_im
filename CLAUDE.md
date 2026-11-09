# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

LanChat：纯内网的 macOS 原生 IM（SwiftPM，Swift 6 工具链、Swift 5 语言模式，macOS 14+，无第三方依赖，链接系统 sqlite3）。项目文档、注释、提交说明均使用中文。

## 常用命令

```bash
swift build                                   # 调试构建
swift test                                    # 全部单元测试（回环 TCP，不走 Bonjour）
swift test --filter ChatNodeTests/testFileTransfer   # 跑单个测试
LANCHAT_BONJOUR_TEST=1 swift test             # 额外跑真实 Bonjour 发现测试（默认 skip）
./scripts/build-app.sh                        # 打包 build/LanChat.app（release + ad-hoc 签名）
VERSION=1.2.0 UNIVERSAL=1 ZIP=1 ./scripts/build-app.sh   # 与 CI 相同的 Universal 包 + zip
open -n build/LanChat.app --env LANCHAT_PROFILE=B        # 同机第二个实例（独立数据目录和下载目录）
open -n -W build/LanChat.app --env LANCHAT_DIAG=1 --stdout /dev/stdout  # 打印本机 MAC/ARP 诊断后退出
```

没有 lint 配置。Info.plist 由 `build-app.sh` 生成（含 `NSLocalNetworkUsageDescription`、`NSBonjourServices`）；直接 `swift run` 的裸二进制没有 bundle，本地网络权限和系统通知可能不可用，验证真实行为要用打包后的 .app。

## 架构

两个 target，边界清晰：

- **`LanChatCore`**（库，无 UI）：网络、协议、存储、本机设备信息。测试只覆盖这一层。
- **`LanChat`**（SwiftUI 可执行）：`AppModel` 是唯一的状态中枢（`@MainActor ObservableObject`），把 Core 的事件落库并驱动视图。

### 数据流

`ChatNode` 在私有串行队列 `lanchat.node` 上做所有网络工作，通过 `onEvent: (NodeEvent) -> Void` 回调**在主线程**派发事件；`AppModel.handle(_:)` 用 `MainActor.assumeIsolated` 接住并写入 `ChatStore`、更新 `@Published` 状态。UI 的发送动作反向调用 `node.sendText/sendFile`，结果再以 `outgoingDelivered` / `outgoingFailed` / `transferProgress` 事件回来。新增网络能力时，应在 `NodeEvent` 加 case，而不是让 Core 直接依赖 App 层。

### 协议（`Wire.swift` + `ChatNode.swift` + `E2E.swift`）

- **每次投递一条独立 TCP 连接**：记录 = 4 字节大端长度 + 内容。连接开头双方交换明文 `hello` 帧完成加密握手（`E2E`：Ed25519 身份签名 + 临时 X25519 + HKDF → 双向 ChaChaPoly，计数器 nonce），之后所有 `Header` 和文件分块都是 `SecureChannel` 加密记录（`Wire.secureFrame` / `readSecureHeader`）。文件在 file 帧后跟若干加密分块（每块明文 ≤ `Wire.chunkSize`）。text/file 以 `ack` 确认，`info` 帧请求/应答双方互换 `DeviceInfo`。
- **强制加密，不兼容 v2 明文协议**：首帧不是 hello 就断开。发送方身份以握手为准（`dispatch` 忽略帧内 `fromId`）；`sendText/sendFile` 必须传预期 `peerId`，握手时校验应答方设备 ID。
- **信任（TOFU）**：`ChatNode.pinned` 由 App 启动时从 `ChatStore.pinnedKeys()` 注入；首次见到 → `peerKeyLearned`（落库），公钥不一致 → 拒绝并 `peerKeyMismatch`（存为 `pending_key`），用户确认后 `AppModel.trustNewKey` 调 `node.pin`。新增连接类型时必须先走 `clientHandshake` / hello 校验，不能绕过。
- 接收端按 `msgId` 去重（`ChatStore.insert` 返回是否新插入），所以重传安全。
- 文件名经 `ChatNode.sanitize` 去掉路径，`uniqueURL` 避免覆盖（加 ` (1)` 后缀）。
- Bonjour 服务名是设备 UUID（避免重名冲突），显示名、主机名、MAC 放在 TXT 记录里；改名时重设 `listener.service`。修改 TXT 字段或 Header 字段要考虑新旧版本互通（字段多为可选，TXT 有 `ver`）。

### 在线状态

Bonjour 结果决定"可见"，但掉线后缓存可能残留。`outgoingFailed(unreachable: true)`（连接根本没建立）时 `AppModel.markUnreachable` 立即标离线，并每 5 秒 `probe` 一次，探测成功或收到对方消息即恢复。`unreachable` 要与本地原因（如读文件失败）区分，见 `testMissingFileIsNotUnreachable`。

### 设备身份校验

- `DeviceInfo.swift`（Core）：采集本机网卡/MAC/ARP 表（`LocalDevice`），`Diagnostics` 用于 `LANCHAT_DIAG`。
- `ChatNode.observe` 记录一次真实连接的实测信息（对端 IP、ARP 查到的 MAC、本机网卡、RTT）→ `peerObserved` 事件 → `ChatStore.updatePeerObservation` 持久化。
- `PeerIdentity.swift`（App）：比较加密公钥状态、自报 `DeviceInfo`、实测观测、Bonjour 广播、历史记录，得出 `IdentityVerdict`（侧栏盾牌）和逐项 `IdentityCheck`（`PeerInfoPanel` 展示）。密码学身份以公钥 + 用户核对安全码（`key_verified`）为准，MAC/ARP 只作辅助。

### 存储（`ChatStore.swift`）

直接用 sqlite3 C API（WAL）。表 `peers`、`messages`。schema 迁移方式是 init 里检查 `PRAGMA table_info(peers)` 后 `ALTER TABLE ADD COLUMN`——给表加列时把列追加到 `added` 列表，并在 `ChatStoreMigrationTests` 覆盖。启动时 `failInterrupted()` 把上次未完成的收发标为失败。

数据位置：`~/Library/Application Support/LanChat<-PROFILE>/`（`chat.sqlite`、`identity.json`、`identity.key` = Ed25519 私钥，0600），接收文件在 `~/Downloads/LanChat<-PROFILE>/`。

## 测试约定

`ChatNodeTests` 用 `discovery: false` 启动节点，从 `.listening(port:)` 事件拿端口，再用 `127.0.0.1:port` 直连，临时目录每个用例独立。新增网络行为的测试沿用这个 `startNode` 模式，不依赖 Bonjour。

## CI / 发布（`.github/workflows/build.yml`）

- 推送 main（非仅 `.md`/LICENSE 改动）会跑测试、构建 Universal 包，并**自动发布** Release，版本号 = 最新 `v*` 标签补丁号 +1。只想构建不发布时在提交说明里写 `[skip release]`。
- 升主/次版本：打 `vX.Y.0` 标签并与 main 一起推送，或手动 workflow_dispatch 填版本号。
- Release 附件固定名 `LanChat.zip`，README 的"下载最新版"链接依赖这个名字，不要改。
