# Bento — 为 AI 编程 agent 而生的终端

[English](README.md) | 简体中文

在自己的机器上跑一队编程 agent。谁在干活、谁在等你，一眼看清。用语音回答它们——走到哪都行。

<!-- hero：发布前放一张截图或短 GIF。
     建议构图：Parallel 窗口 4 个 agent pane 混合状态
     （工作中 / 等待输入 / 已完成），侧栏可见，语音浮层激活。
<p align="center"><img src="docs/hero-mac.png" width="720" alt="Bento 并行运行四个 agent"></p>
-->

现在写代码，是几个 agent 并行干活，你来评审、拍板、解卡点。传统终端对这种工作流很不友好：每个 pane 长得一模一样，你得挨个切过去问"好了没"，SSH 一断全盘皆输。Bento 是为这个工作流从头设计的 macOS 原生终端——名字取自便当盒：一格一个 agent，格格分明，端起来就走。iOS 版在路上，你的 agent 团队很快可以跟你出门。

## Agent 团队，一眼看清

- **每个 pane 都知道自己 agent 的状态**——工作中、等你输入、已完成、空闲——用统一的颜色 + 图标语言显示在 pane 标题栏和侧栏里。不用再轮流巡逻自己的终端。
- **开箱识别十家 agent：**Claude Code、Codex、Gemini CLI、OpenCode、Cursor Agent、Copilot CLI、Amp、OpenClaw、Hermes、Antigravity——普通 shell 和自定义命令当然也行。
- **同一个工作区，两种读法：**Parallel（全部平铺，状态尽收眼底）和 Focus（一个全屏，其余列表）。切换是无损的——只重排结构，绝不破坏。
- **在 agent 回合之间跳转**：标题栏箭头直达上一轮/下一轮输出，不用手搓滚动条。

## 说话，代替打字

- **在终端任何位置按住说话。**松手即注入转写文本；滑动可以原样发送、让更强的模型润色，或把大白话直接变成 shell 命令。
- **认得你屏幕的语音识别。**识别词表会根据屏幕上下文动态偏置，中英混说毫无压力。
- **零配置。**语音开箱即用（走 Bento relay）；想直连也可以自带 API key——Apple 本地、OpenAI、Qwen 三种引擎都支持。

## 比一切都活得久的会话

- 工作区放在**持久化 tmux 会话**里（tmux 已内置，无需安装）。退出 app，agent 继续干活。
- **已经在用 tmux？**Bento 直接接入你现有的 tmux 服务器——此刻的会话、窗口、pane 原样呈现，其他 tmux 客户端照常工作、完全同步。
- **SSH 快速连接**直接读你现有的 `~/.ssh/config`，纯 SSH 连接也是全功能。远程机器只需要跑着 `sshd`、装了 `tmux`——不需要 agent，不需要 daemon，什么都不用装。

## 会读自己输出的终端

- **⌘-点击任何文件路径**——哪怕被 TUI 折行、截断过——立刻打开富预览：语法高亮、渲染 Markdown、跳转到行。
- **⌘-点击 URL** 直接打开。
- **拖拽 pane** 分屏、停靠、互换（VS Code 式落点提示）；pane 和窗口还能跨会话移动。
- **浅色、深色、跟随系统**，终端配色主题内置。

## 安装

**要求：**macOS 14+，Apple Silicon。

1. 从[最新 release](https://github.com/NovaShang/bento/releases/latest) 下载 `BentoTerm-macos-arm64.zip`。
2. 解压，把 `BentoTerm.app` 拖进 `/Applications`。应用已签名并经过公证——打开不会有任何警告。
3. 首次启动会引导你创建第一个 agent 会话，没装的 agent 也提供一键安装命令。

Mac 应用完全自包含——tmux 已内置，不需要额外装任何东西。

要用远程机器，那台机器只需要跑着 `sshd`、装了 `tmux`。至于怎么让它从你这边连得上（NAT、VPN、Tailscale、跳板机），由你和你的 `~/.ssh/config` 决定；Bento 不提供 relay，也没有主机端组件。

## 隐私

- **无账号。**没有任何要注册的东西。
- **遥测默认关闭**，严格 opt-in——只有一组封闭的功能计数器，永远不含终端内容。
- **语音音频**经 Bento relay 转发给语音服务商（key 存在服务端）；用自己的 key 则直连服务商。除了你主动调用的功能，终端输出永远不离开你的机器。

## 技术选型与架构

| 层 | 选型 |
|---|---|
| 终端渲染 | [libghostty](https://ghostty.org)——每个 pane 都是真正的 GPU 加速终端 surface（GhosttyKit xcframework），不是 webview，也不是自己造的模拟器 |
| 多路复用 | tmux control mode（`-CC`），tmux 已内置，协议客户端是我们自己写的、测试覆盖严密的 [`swift-tmux`](swift-tmux/) |
| 应用层 | 端到端原生 Swift——macOS 用 AppKit/SwiftUI，iOS 用 UIKit/SwiftUI——都是共享核心 [`bento-terminal-core`](bento-terminal-core/) 之上的薄壳 |
| Agent 状态检测 | 纯客户端启发式：基于 pane 输出、标题、进程信息的逐 agent 画像——不需要 SDK 钩子，不需要 agent 配合 |
| SSH | macOS 直接用系统 OpenSSH，所以 `~/.ssh/config`、ControlMaster、跳板机开箱即用；远程主机只需要 `sshd` + `tmux` |
| 语音 | `SpeechEngine` 抽象层，下接 Apple 本地、OpenAI、Qwen 实时 ASR，带屏幕上下文词表偏置 |

两条贯穿一切的设计原则：

1. **tmux 是唯一事实源。**应用只渲染和编辑 tmux 状态，从不私藏副本。所以会话比应用活得久，任何其他 tmux 客户端看到的都和 Bento 一致。
2. **传输层保持愚蠢，客户端保持聪明。**纯本地 shell 或原生 SSH 就是全功能。Agent 检测和终端智能完全在客户端，永远不上服务端。

## 仓库结构

| 目录 | 内容 |
|---|---|
| `BentoTermiOS/` | iOS / iPadOS 应用 |
| `BentoTermMac/` | macOS 应用 |
| `bento-terminal-core/` | 共享 Swift 核心：渲染（libghostty）、agent 状态检测、语音、会话逻辑 |
| `swift-tmux/` | tmux control mode（`-CC`）协议客户端 |
| `docs/` | PRD、设计文档、bug tracker |

## 从源码构建

需要 Xcode 26+。GhosttyKit——打包成 xcframework 的 libghostty——会作为 Swift Package 二进制依赖自动拉取。构建阶段脚本会跑 `scripts/fetch-bundled-tmux.sh`，拉取 `scripts/bundled-tmux.version` 里钉住的预编译 tmux，内嵌到 `BentoTerm.app/Contents/MacOS/helpers/tmux`；该脚本需要 `gh` CLI，没有的话应用会退回系统 tmux。

```sh
git clone https://github.com/NovaShang/bento.git && cd bento
xcodebuild -project BentoTerm.xcodeproj -scheme BentoTermMac -configuration Release build
```

`BentoTermMac` scheme 是 macOS 应用；`BentoTermiOS` scheme 是 iOS。改过 `project.yml` 的话，用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 重新生成工程。

## 许可证

[Apache-2.0](LICENSE)
