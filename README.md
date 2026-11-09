# LanChat

[![最新版本](https://img.shields.io/github/v/release/fangqi179/local_im?label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC)](https://github.com/fangqi179/local_im/releases/latest)
[![构建](https://github.com/fangqi179/local_im/actions/workflows/build.yml/badge.svg)](https://github.com/fangqi179/local_im/actions/workflows/build.yml)

纯内网的极简 macOS 原生 IM：只做**发现、对话、传文件**三件事。没有服务器、没有账号，所有记录只保存在本机。

## 下载

- **[⬇️ 下载最新版 LanChat.zip](https://github.com/fangqi179/local_im/releases/latest/download/LanChat.zip)**（macOS 14+，Apple Silicon 与 Intel 通用）
- [所有版本与更新记录](https://github.com/fangqi179/local_im/releases)

解压后把 `LanChat.app` 拖到「应用程序」。App 未经 Apple 公证，首次打开会被拦截：到「系统设置 → 隐私与安全性」底部点**仍要打开**，或执行 `xattr -dr com.apple.quarantine /Applications/LanChat.app`。系统询问是否允许查找本地网络上的设备时点**允许**。

## 功能

- **自动发现**：Bonjour（`_lanchat._tcp`），同一局域网内运行 LanChat 的设备自动出现在侧栏，显示在线/离线状态。对方异常掉线（崩溃、断网）时，Bonjour 缓存可能还会保留一段时间；只要向对方发送时连接建立失败，就立即把对方标为离线，之后每 5 秒探测一次，连得上或收到对方消息就恢复在线
- **端到端加密**：所有消息、文件和设备信息都经过端到端加密（CryptoKit：Ed25519 身份签名 + 每连接临时 X25519 + ChaCha20-Poly1305，具备前向保密），不再支持与旧版本的明文通信。首次连接时记住对方公钥；之后对方公钥若发生变化（重装、换机或有人冒充），会立即拒绝通信并提示，须在设备信息面板中确认"信任新密钥"后才能恢复。双方可在设备信息面板中核对"安全码"（40 位数字，两台设备上应完全一致），核对后标记为已验证
- **设备信息与身份校验**：列表和聊天标题显示对方"主机名 · IP · MAC"，名字旁的盾牌表示身份状态（绿色实心 = 已核对安全码，灰色描边 = 已加密、MAC 一致但未核对，橙 = 有不一致，红 = 加密密钥变更已阻断）。点工具栏 ⓘ 打开设备信息面板，内容包括：
  - **对方自报**（`info` 握手交换）：电脑名、主机名、登录用户与全名、机型、架构、系统版本、LanChat 版本、监听端口、启动时间；每块网卡的名称/类型、当前 MAC、硬件 MAC、IPv4/掩码、广播地址、IPv6
  - **本机实测**：连接的对方 IP 与端口、**本机 ARP 表中对方的 MAC**、本机经由的网卡和地址、往返延迟
  - **Bonjour 广播**：服务名、域、收到广播的网卡、TXT 记录原文
  - **校验**：ARP 实测 MAC 是否属于对方自报的网卡；连接 IP 是否属于对方自报的地址；应答方设备 ID 是否与广播一致；广播 MAC 是否与握手一致；MAC 是否与历史记录完全不同（可能是冒用）
- **主机名与 IP**：侧栏和聊天标题同时显示对方的主机名（LocalHostName，通过 Bonjour TXT 记录和消息头传递）和 IP（发现后主动解析，并随每次真实连接更新，优先显示 IPv4）；离线联系人显示最后一次已知的地址
- **对话**：点对点 TCP 直连，每条消息都要收到对方确认；发送失败的消息显示红色感叹号，点击即可重发
- **传文件**：点回形针或直接拖文件进窗口，可一次发多个，收发两端都显示进度，任意大小文件分块流式传输
- **本地记录**：SQLite 存储；未读计数、Dock 角标、系统通知
- **设置**：修改显示名称；打开聊天记录和已接收文件所在的文件夹

## 构建

需要 macOS 14+ 和 Xcode / Swift 6。

```bash
./scripts/build-app.sh          # 生成 build/LanChat.app（ad-hoc 签名）
open build/LanChat.app
```

首次启动时 macOS 会询问"是否允许 LanChat 查找本地网络上的设备"，必须点**允许**，否则发现不了任何设备。防火墙询问是否接受传入连接时也要点允许。

要给其他 Mac 用，直接把 `LanChat.app` 拷过去即可。由于是 ad-hoc 签名，在其他 Mac 上第一次打开要右键 → 打开（或在"系统设置 → 隐私与安全性"里允许）。

## 开发

```bash
swift test                              # 单元测试（回环连接收发消息/文件、存储）
LANCHAT_BONJOUR_TEST=1 swift test       # 额外跑真实 Bonjour 发现测试
open -n -W build/LanChat.app --env LANCHAT_DIAG=1 --stdout /dev/stdout   # 输出本机 MAC / ARP 诊断信息
open -n build/LanChat.app --env LANCHAT_PROFILE=B   # 在同一台机器上开第二个实例做测试
```

## 自动构建与发布

GitHub Actions（`.github/workflows/build.yml`）在 macOS 云端完成测试、构建 Universal 版（Apple Silicon + Intel）并发布：

- **推送到 main 自动发布**：每次推送都会跑测试、构建，并发布新的 Release，版本号在上一个版本上把补丁号加 1（v1.0.1 → v1.0.2）。测试失败则不发布
  - 只改 `.md` 文件或 LICENSE 时不触发
  - 提交说明里带 `[skip release]` 时只构建、不发布
- **升级主/次版本号**：给提交打标签后和 main 一起推送，如 `git tag v1.1.0 && git push origin main v1.1.0`；之后的推送从 v1.1.1 继续递增。也可以在网页 Actions → Build → Run workflow 里填写版本号
- **PR**：只跑测试和构建，zip 在该次运行页面的 Artifacts 里下载

Release 附件固定命名为 `LanChat.zip`，所以上面"下载最新版"的链接始终指向最新版本。

本地也可以打同样的包：`VERSION=1.2.0 UNIVERSAL=1 ZIP=1 ./scripts/build-app.sh`

## 数据位置

| 内容 | 路径 |
| --- | --- |
| 聊天记录 | `~/Library/Application Support/LanChat/chat.sqlite` |
| 本机身份 | `~/Library/Application Support/LanChat/identity.json` |
| 本机加密私钥 | `~/Library/Application Support/LanChat/identity.key`（权限 0600；删除后所有联系人会看到"密钥已变更"） |
| 接收的文件 | `~/Downloads/LanChat/` |

## 协议

协议版本 3（Bonjour TXT `ver=3`）。每次投递单独建立一个 TCP 连接。记录 = 4 字节大端长度 + 内容。

连接建立后先做加密握手（明文 JSON）：

```
→ {type:"hello", fromId, fromName, fromHost, hello:{deviceId, identityKey, ephemeralKey, signature}}
← {type:"hello", ..., hello:{...}}   // 应答方签名覆盖双方 hello，防止替换临时公钥
```

身份密钥为 Ed25519，临时密钥为 X25519；共享密钥经 HKDF-SHA256（salt = 握手记录哈希）派生出两个方向各自的 ChaCha20-Poly1305 密钥，nonce 为递增计数器。之后每条记录都是密文（内容 = 密文 + 16 字节 tag）：

```
文本: → {type:"text", msgId, fromName, fromHost, text}             ← {type:"ack", msgId}
文件: → {type:"file", msgId, fromName, fromHost, fileName, fileSize} + 若干加密分块（每块明文 ≤ 256KB，合计 fileSize 字节）
                                                          ← {type:"ack", msgId}
信息: → {type:"info", ..., info: 本方 DeviceInfo}         ← {type:"info", ..., info: 对方 DeviceInfo}
```

发送方身份以握手为准，不采信加密帧里的 `fromId`。发起方要求应答方的设备 ID 与预期一致，双方都检查公钥是否与记住的一致（首次见到则记住，即 TOFU）。首帧不是 hello 的连接（旧版明文协议）直接断开。

接收端按 `msgId` 去重，重传是安全的。接收的文件名会去掉路径部分；已存在同名文件时不会覆盖，而是加 ` (1)` 后缀。

## 代码结构

```
Sources/LanChatCore/   网络与存储，不依赖 UI
  ChatNode.swift       Bonjour 广播/发现，TCP 收发，握手与信任检查
  E2E.swift            端到端加密：身份密钥、握手、加密通道、安全码
  Wire.swift           帧协议
  ChatStore.swift      SQLite 存储
Sources/LanChat/       SwiftUI 应用
  AppModel.swift       状态与事件处理
  Views.swift          侧栏、聊天、文件卡片、设置
scripts/               .app 打包与图标生成
```

## 已知限制

- 公钥采用"首次见到即信任"（TOFU）：如果第一次连接时就有人冒充对方，只有核对安全码才能发现。重要联系人建议当面或电话核对一次
- MAC/ARP 等网络层校验只作辅助参考，不是密码学认证；真正的身份确认以加密密钥和安全码为准
- MAC 和 ARP 只在同一二层网段内有意义；跨路由器时 ARP 查到的是网关 MAC，会显示为不一致
- 新版 macOS 只允许已获"本地网络"权限的 App 读取当前 MAC 和 ARP 表；未授权时这两项显示为未知（硬件 MAC 不受影响）
- 登录用户名、全名、网卡地址会发送给局域网内的其他 LanChat 客户端

- 加密只保护传输过程：本机的聊天记录（SQLite）和已接收的文件以明文保存在磁盘上；Bonjour 广播（显示名、主机名、MAC）、hello 帧中的显示名、谁在和谁通信、消息大小等元数据不加密
- 不兼容旧版本（协议 v2 及以前）：双方都需要升级才能通信
- 不支持发送文件夹，请先压缩再发
- 只能发给在线的对方，没有离线消息队列
