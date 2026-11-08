# LanChat

纯内网的极简 macOS 原生 IM：只做**发现、对话、传文件**三件事。没有服务器、没有账号，所有记录只保存在本机。

## 功能

- **自动发现**：Bonjour（`_lanchat._tcp`），同一局域网内运行 LanChat 的设备自动出现在侧栏，显示在线/离线状态。对方异常掉线（崩溃、断网）时，Bonjour 缓存可能还会保留一段时间；只要向对方发送时连接建立失败，就立即把对方标为离线，之后每 5 秒探测一次，连得上或收到对方消息就恢复在线
- **设备信息与身份校验**：列表和聊天标题显示对方"主机名 · IP · MAC"，名字旁的盾牌表示身份校验结果（绿 = 已校验，橙 = 有不一致）。点工具栏 ⓘ 打开设备信息面板，内容包括：
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

GitHub Actions（`.github/workflows/build.yml`）在 macOS 云端构建：

- **推送到 main 或提交 PR**：跑测试并构建 Universal 版（Apple Silicon + Intel），zip 包在该次 Actions 运行页面的 Artifacts 里下载（保留 14 天）
- **发布正式版本**：任选一种方式，会创建 GitHub Release 并附上 `LanChat-<版本>.zip`
  - 打标签推送：`git tag v1.2.0 && git push origin v1.2.0`
  - 网页上：Actions → Build → Run workflow，填写版本号 `1.2.0`

本地也可以打同样的包：`VERSION=1.2.0 UNIVERSAL=1 ZIP=1 ./scripts/build-app.sh`

## 数据位置

| 内容 | 路径 |
| --- | --- |
| 聊天记录 | `~/Library/Application Support/LanChat/chat.sqlite` |
| 本机身份 | `~/Library/Application Support/LanChat/identity.json` |
| 接收的文件 | `~/Downloads/LanChat/` |

## 协议

每次投递单独建立一个 TCP 连接。帧 = 4 字节大端长度 + JSON 头：

```
文本: → {type:"text", msgId, fromId, fromName, fromHost, text}             ← {type:"ack", msgId}
文件: → {type:"file", msgId, fromId, fromName, fromHost, fileName, fileSize} + fileSize 字节原始数据
                                                                  ← {type:"ack", msgId}
信息: → {type:"info", ..., info: 本方 DeviceInfo}                 ← {type:"info", ..., info: 对方 DeviceInfo}
```

接收端按 `msgId` 去重，重传是安全的。接收的文件名会去掉路径部分；已存在同名文件时不会覆盖，而是加 ` (1)` 后缀。

## 代码结构

```
Sources/LanChatCore/   网络与存储，不依赖 UI
  ChatNode.swift       Bonjour 广播/发现，TCP 收发
  Wire.swift           帧协议
  ChatStore.swift      SQLite 存储
Sources/LanChat/       SwiftUI 应用
  AppModel.swift       状态与事件处理
  Views.swift          侧栏、聊天、文件卡片、设置
scripts/               .app 打包与图标生成
```

## 已知限制

- 身份校验基于网络层信息，能发现大多数"换了设备/信息对不上"的情况，但**不是密码学认证**：同一网段内有意伪造 MAC 和自报信息的设备无法被识别
- MAC 和 ARP 只在同一二层网段内有意义；跨路由器时 ARP 查到的是网关 MAC，会显示为不一致
- 新版 macOS 只允许已获"本地网络"权限的 App 读取当前 MAC 和 ARP 表；未授权时这两项显示为未知（硬件 MAC 不受影响）
- 登录用户名、全名、网卡地址会发送给局域网内的其他 LanChat 客户端

- 不加密，只适合在可信的内网中使用
- 不支持发送文件夹，请先压缩再发
- 只能发给在线的对方，没有离线消息队列
