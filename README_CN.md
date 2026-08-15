# Bento Term — 盯着 agent 干活，开口就能指挥的终端

[English](README.md) | 简体中文

[![Release](https://img.shields.io/github/v/release/NovaShang/BentoTerm)](https://github.com/NovaShang/BentoTerm/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20iPhone%20·%20iPad-lightgrey)

<p align="center"><img src="docs/media/hero-parallel.webp" width="820" alt="Bento Term 并行运行五个 agent，每个格子按状态着色"></p>

现在的 agent 一跑就是四十分钟。盯着一个跑，被浪费的是你——所以你开了好几个，
问题就变成怎么同时跟住它们。Bento Term 就是为这件事造的终端：每个 agent 一个
格子，颜色标出它正在干什么，所有格子装在同一个窗口里，像一盒便当。

**[bentoai.dev/term/zh](https://bentoai.dev/term/zh/)** · `brew install --cask NovaShang/tap/bento-term` · iPhone / iPad 版即将上架 App Store

## 一屏看全队

- **每个格子都知道自己 agent 的状态**——🔵 工作中、🟠 等你回答、🟢 已完成未读、⚪ 空闲——统一的颜色 + 图标语言，标题栏和侧栏一致。你看的是全场，不用挨个巡视。
- **开箱识别十家 agent：**Claude Code、Codex、Gemini CLI、OpenCode、Cursor Agent、Copilot CLI、Amp、OpenClaw、Hermes、Antigravity——普通 shell 和你敲的任何命令当然也行。每份配置都能改，再冷门的工具也只差一份配置。
- **同一个工作区，两种读法：**Parallel（全部平铺）和 Focus（一格放大，其余列表）。切换动的是真实的 pane——只重排结构，绝不破坏。
- **不碰你的 shell。**不注入初始化，也不需要 agent 配合——状态来自 pane 本来就在打印的内容，在你的设备上检测。

## 动口，不动手

- **在格子上按住右键，直接说。**说话比打字快三倍。松手落稿，上滑发送，下滑取消——也可以把一句大白话直接变成 shell 命令。
- **识别读得到屏幕。**词表按屏幕上下文加权，文件名、术语、连代码里的标识符都一字不差——中英混说也没问题。
- **三个引擎，零配置。**Apple 端上识别、Qwen、OpenAI——默认走 Bento 中转开箱即用，填自己的 key 就直连。

## 人走，活不停

- 活儿在你机器上的**真 tmux 会话**里，不在 app 里。退出 app、合上电脑、断了 Wi-Fi——什么都不会停。
- **本来就在用 tmux？**Bento 用控制模式（`-CC`）直接接管你现有的会话，其他 tmux 客户端全程保持同步。没用过 tmux？内置打包，平时不打扰你。
- **有 `sshd` 和 `tmux` 就行：**你的 Mac、Linux 服务器、Windows 上的 WSL。用你现成的 `~/.ssh/config` 走纯 SSH，那一头不装我们任何东西。
- **手机上还是这几个格子。**iPhone / iPad 原生 app 随时接上跑到一半的会话——同样的状态色，答掉琥珀那格，手机揣回兜里。

## 每天都会用到的东西

- **看得到文件，不只是输出。**每个格子带自己工作目录的文件树——多深都行，还带搜索。agent 打印的路径点一下就打开，带语法高亮和行号，`:42` 也认，被 TUI 截断的行也认。PDF、图片走 Quick Look。
- **格子像窗口一样挪。**向右或向下分屏，抓住标题栏拖进任何投放区——包括另一个会话。每次落下都是真实的 tmux 移动。
- **一条命令都不用敲。**选个目录、选个 agent、选个布局——Bento 开好格子把它们跑起来。之后的一切，<kbd>⌘P</kbd> 一下就到。
- **⌘F 搜回滚**（搜索跑在终端引擎里，命中原地高亮）、任何 iTerm2 配色、你装的任何等宽字体、浅色/深色/跟随系统。

## 安装

**要求：**macOS 14+，Apple Silicon。

```sh
brew install --cask NovaShang/tap/bento-term
```

或从 [最新 release](https://github.com/NovaShang/BentoTerm/releases/latest) 下载 `BentoTerm-macos-arm64.zip`，解压把 `BentoTerm.app` 拖进 `/Applications`——已签名公证，打开无警告。

app 完全自带：tmux 内置打包，首次启动引导你建第一个 agent 会话，缺哪个 agent
还有一键安装。远端机器只需要 `sshd` 和 `tmux`；怎么连通（NAT、VPN、Tailscale、
跳板机）归你的 `~/.ssh/config` 管——Bento 不带中转服务，也没有主机侧组件。

## 隐私

- **没有账号。**压根没有可注册的东西。
- **终端输出永远不离开你的机器。**连接是纯 SSH，中间没有我们的任何环节。
- **遥测默认关闭**、严格 opt-in——一组固定的事件名，永远不含终端内容、命令、路径或主机名。
- **语音音频**默认经 Bento 中转发给识别服务（key 在服务端），填自己的 key 就直连。详见[隐私页](https://bentoai.dev/privacy/)。

## 引擎盖之下

| 层 | 选择 |
|---|---|
| 终端渲染 | [libghostty](https://ghostty.org)——每个 pane 都是真实的 GPU 加速终端表面（GhosttyKit xcframework），不是 webview，也不是从零写的模拟器 |
| 复用 | tmux 控制模式（`-CC`），tmux 内置打包，[`BentoTmuxKit`](Modules/BentoTmuxKit/) 是我们自己写的严格、重测试的协议客户端 |
| 应用 | 端到端原生 Swift——macOS 用 AppKit/SwiftUI，iOS 用 UIKit/SwiftUI——都是共享 [`Modules/`](Modules/) 包上的薄壳 |
| Agent 状态检测 | 客户端侧对 pane 输出、标题、进程信息的启发式匹配——按 agent 配置，无 SDK 钩子，不需要 agent 配合 |
| SSH | macOS 直接用系统 OpenSSH，`~/.ssh/config`、ControlMaster、跳板机全部照常；远端只需要 `sshd` + `tmux` |
| 语音 | `SpeechEngine` 抽象覆盖 Apple 端上、OpenAI、Qwen 实时 ASR，带屏幕上下文词表加权 |

两条设计铁律贯穿一切：

1. **tmux 是唯一真理源。**app 只渲染和编辑 tmux 的状态，从不自己留一份。所以会话比 app 活得久，其他任何 tmux 客户端看到的都和 Bento 一致。
2. **传输要笨，客户端要聪明。**一切都跑在普通本地 shell 或原味 SSH 上。agent 检测和终端智能全部在客户端，永远不上服务端。

## 仓库结构

| 目录 | 是什么 |
|---|---|
| `BentoTermMac/` | macOS app——AppKit/SwiftUI 壳 |
| `BentoTermiOS/` | iOS / iPadOS app——UIKit/SwiftUI 壳 |
| `Modules/BentoTmuxKit/` | tmux 控制模式（`-CC`）协议客户端 |
| `Modules/BentoGhosttyKit/` | libghostty 之上的终端表面 |
| `Modules/BentoAgentKit/` | agent 检测规则与 pane 状态 |
| `Modules/BentoSessionKit/` | 会话、窗口、pane 逻辑 |
| `Modules/BentoVoiceKit/` | 语音引擎与语音控制器 |
| `Modules/BentoFilePreviewKit/` | 路径解析与富文件预览 |
| `Modules/BentoUISharedKit/` | 双平台共享 UI |
| `Modules/BentoFoundationKit/` | 日志与底层共享工具 |
| `Modules/GhosttyKit/` | libghostty 二进制 xcframework target |
| `docs/` | PRD、设计文档、bug 台账 |

## 从源码构建

需要 Xcode 26+。GhosttyKit——打包成 xcframework 的 libghostty——作为 Swift Package binary target 自动拉取。构建阶段脚本 `scripts/fetch-bundled-tmux.sh` 会按 `scripts/bundled-tmux.version` 钉住的版本拉预编译 tmux 并嵌入 `BentoTerm.app/Contents/MacOS/helpers/tmux`；它需要 `gh` CLI，没有的话 app 回退到系统 tmux。

```sh
git clone https://github.com/NovaShang/BentoTerm.git && cd BentoTerm
xcodebuild -project BentoTerm.xcodeproj -scheme BentoTermMac -configuration Release build
```

`BentoTermMac` scheme 是 macOS app；`BentoTermiOS` scheme 是 iOS。改了 `project.yml` 要用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 重新生成工程。

## 许可

[Apache-2.0](LICENSE)
