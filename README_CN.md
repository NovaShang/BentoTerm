# Bento Term

[English](README.md) | 简体中文

[![Release](https://img.shields.io/github/v/release/NovaShang/BentoTerm)](https://github.com/NovaShang/BentoTerm/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

一个用来同时运行、监督多个 CLI 编程 agent 的终端。macOS、iPhone、iPad 原生
客户端，构建在 tmux 控制模式（`-CC`）之上，带客户端侧 agent 状态检测、
按住说话的语音输入，渲染用 libghostty。

<p align="center"><img src="docs/media/hero-parallel.webp" width="820" alt="五个 agent pane 平铺在一个窗口里，标题栏显示各自的状态"></p>

官网：[bentoai.dev/term/zh](https://bentoai.dev/term/zh/) · 安装：`brew install --cask NovaShang/tap/bento-term` · iPhone/iPad：App Store 审核中

## 它做什么

- **接管真实 tmux 会话**（控制模式）。tmux 内置打包，没装过也能用；本来就在用 tmux 的话，Bento 直接接上你现有的 server，其他 tmux 客户端全程同步——布局、pane、回滚都在 tmux 里，不在 app 里。
- **检测每个 pane 的 agent 状态**——工作中 / 等待输入 / 已完成未读 / 空闲——依据是 pane 输出、标题和进程信息，完全在客户端完成。状态以颜色显示在 pane 标题栏和侧栏。内置十份 CLI 配置（Claude Code、Codex、Gemini CLI、OpenCode、Cursor Agent、Copilot CLI、Amp、OpenClaw、Hermes、Antigravity）；每份配置的匹配规则都可编辑，也可以为任意工具新建配置。检测不需要 agent 配合，不向 shell 注入任何东西。
- **同一会话的两种布局：**Parallel 全部平铺；Focus 一格占满窗口、其余收进侧栏。切换重排的是真实 tmux pane，不维护独立的视图状态。
- **按住说话。**在 pane 上按住右键说话，转写落进该 pane 的输入。识别词表按屏幕上下文加权，可见回滚里的标识符、文件名都能正确转写，中英混说可用。引擎：Apple 端上（默认）、Qwen、OpenAI 实时——走 Bento 中转或用自己的 key 直连。也可以把自然语言翻译成 shell 命令。
- **文件树与预览。**每个 pane 暴露其工作目录的文件树。打印出的路径可点——TUI 折行或截断的也能解析——以语法高亮打开并跳转到行（`path:42`）。PDF、图片等走 Quick Look。iOS 上经同一条 SSH 连接使用同一棵树。
- **pane 管理即 tmux 操作。**分屏、跨位置/跨会话拖放、复制，每一步都执行真实的 tmux `split-window` / `move-pane`，从别处 `tmux attach` 看到的布局完全一致。
- **iOS/iPadOS 客户端**经 SSH 随时接上跑到一半的会话，状态检测一致。

## 架构

| 层 | 选择 |
|---|---|
| 终端渲染 | [libghostty](https://ghostty.org)——每个 pane 都是真实的 GPU 加速终端表面（GhosttyKit xcframework），不是 webview，也不是从零写的模拟器 |
| 复用 | tmux 控制模式（`-CC`），tmux 内置打包，[`BentoTmuxKit`](Modules/BentoTmuxKit/) 是我们自己写的严格、重测试的协议客户端 |
| 应用 | 端到端原生 Swift——macOS 用 AppKit/SwiftUI，iOS 用 UIKit/SwiftUI——都是共享 [`Modules/`](Modules/) 包上的薄壳 |
| Agent 状态检测 | 客户端侧对 pane 输出、标题、进程信息的启发式匹配——按 agent 配置，无 SDK 钩子 |
| SSH | macOS 直接用系统 OpenSSH，`~/.ssh/config`、ControlMaster、跳板机全部照常；远端只需要 `sshd` + `tmux` |
| 语音 | `SpeechEngine` 抽象覆盖 Apple 端上、OpenAI、Qwen 实时 ASR，带屏幕上下文词表加权 |

两条设计铁律贯穿一切：

1. **tmux 是唯一真理源。**app 只渲染和编辑 tmux 的状态，从不自己留一份。所以会话比 app 活得久，其他任何 tmux 客户端看到的都和 Bento 一致。
2. **传输要笨，客户端要聪明。**一切都跑在普通本地 shell 或原味 SSH 上。agent 检测和终端智能全部在客户端，永远不上服务端。远端机器不安装任何东西。

## 安装

要求：macOS 14+，Apple Silicon。

```sh
brew install --cask NovaShang/tap/bento-term
```

或从 [最新 release](https://github.com/NovaShang/BentoTerm/releases/latest) 下载 `BentoTerm-macos-arm64.zip`，解压把 `BentoTerm.app` 拖进 `/Applications`——已签名公证。

app 自带 tmux。远端机器只需要 `sshd` 和 `tmux`；连通性（NAT、VPN、Tailscale、
跳板机）由你的 `~/.ssh/config` 解决——没有中转服务，也没有主机侧组件。

## 隐私

- 没有账号。
- 终端输出不离开你的机器；连接是纯 SSH。
- 遥测默认关闭、opt-in——一组固定的事件名，不含终端内容、命令、路径或主机名。
- 语音音频经 Bento 中转发给识别服务（key 在服务端），或用自己的 key 直连。详见[隐私页](https://bentoai.dev/privacy/)。

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
