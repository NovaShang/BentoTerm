# App Store listing v2 设计（2026-08-14）

> 原则：站、片、商店是**同一个论证的三种放法**。文案直接复用已定稿的句子系统
> （英文=官网，中文=v3-zh 原生重写），不另起炉灶。截图视觉语言沿用影片字卡
> （深底 #0b0d10、Geist、状态色点缀），让从视频/官网点过来的人认得出这是同一个产品。
> 双语上架：en-US + zh-Hans（app UI 目前是英文，商店页双语不受影响）。

## 1. 文案

### en-US

| 字段 | 内容 | 限长 |
|---|---|---|
| Name | `Bento Term` | 30 |
| Subtitle | `Watch & talk to your agents` | 30（27✓） |
| Promotional Text | `Every pane is tinted by what its agent is doing — blue working, amber waiting for you, green done. Hold to talk instead of typing. The work lives in tmux and never stops.` | 170（169✓） |
| Keywords | `terminal,ssh,tmux,agent,claude,ai,shell,cli,console,developer,code,mosh` | 100 |

**Description**（结构 = 落地页章节，全文 ~1600 字符）：

```
Your agents run for forty minutes at a time. Watching one is a waste of you — so you run
several, and the problem becomes keeping track of them all. Bento Term is a terminal
built for exactly that.

A WHOLE TEAM, ONE SCREEN
Every agent gets a pane, tinted by what it's doing: blue is working, amber is waiting
for you, green is done and you haven't looked yet. You read the room instead of
visiting each one. Parallel mode tiles everything; Focus mode gives one pane the whole
screen with the rest in a sidebar.

SAY IT, DON'T TYPE IT
Hold on a pane and talk. Speaking is about three times faster than typing, and Bento
reads the screen, so file names and technical words come out right — mixed
Chinese/English included. Slide up to send, down to cancel.

LEAVE THE DESK, NOT THE WORK
Everything runs in tmux on your machine — your Mac, a Linux server, or WSL — over
plain SSH, with nothing installed on the other end. Quit the app, close the laptop:
nothing stops. Attach from iPhone or iPad mid-run and answer from wherever you are.

EVERY DAY
· The file tree of every pane's working directory — tap a printed path and it opens,
  with syntax highlighting, even at :42. PDFs and images too.
· Panes move like windows: split, drag, drop — every move is a real tmux move.
· Pick a folder, pick an agent, and Bento opens the panes and starts them. No shell
  needed.
· Ten agents recognized out of the box — Claude Code, Codex, Gemini CLI and more —
  every profile editable, so a tool nobody has heard of yet is one profile away.

BUILT LIKE A TERMINAL
Native Swift, the same GPU renderer as Ghostty (libghostty), real tmux control mode
(-CC). No accounts. Your terminal output never leaves your machines. Free and open
source, Apache-2.0.

Requires a machine you can ssh into with tmux installed. macOS, Linux and WSL all work.
```

**What's New（0.1.1 首发）**：`First App Store release.`

### zh-Hans

| 字段 | 内容 |
|---|---|
| Name | `Bento Term` |
| Subtitle | `盯着 agent 干活，开口指挥`（12✓） |
| Promotional Text | `每个格子按 agent 状态着色——蓝色在干活，琥珀在等你，绿色已完成。按住说话代替打字。活儿在 tmux 里，人走了也不停。` |
| Keywords | `终端,terminal,ssh,tmux,agent,claude,ai,命令行,开发者,shell` |

**Description**（与英文同构，用 v3-zh 的原生句子）：

```
现在的 agent 一跑就是四十分钟。盯着一个跑，被浪费的是你——所以你开了好几个，
问题就变成怎么同时跟住它们。Bento Term 就是为这件事造的终端。

一屏看全队
每个 agent 一个格子，颜色标出它正在干什么：蓝色在干活，琥珀在等你回答，绿色是
干完了你还没看。你看的是全场，不用挨个巡视。Parallel 模式全部平铺；Focus 模式
一格放大，其余收进侧栏。

动口，不动手
在格子上按住，直接说。说话比打字快三倍，Bento 读得到屏幕，文件名、术语都
一字不差——中英混说也没问题。上滑发送，下滑取消。

人走，活不停
一切跑在你机器上的 tmux 里——你的 Mac、Linux 服务器或 WSL，纯 SSH 连接，
那头不装任何东西。退出 app、合上电脑：什么都不会停。跑到一半用 iPhone、iPad
接上，在哪都能把事答掉。

每天都用得上
· 每个格子带自己的文件树——agent 打印的路径点一下就打开，带语法高亮，:42 也认。
  PDF、图片同样能看。
· 格子像窗口一样挪：分屏、拖动、落位，每一步都是真实的 tmux 操作。
· 选个目录、选个 agent，Bento 开好格子把它们跑起来，一条命令都不用敲。
· 出厂认识十个 agent——Claude Code、Codex、Gemini CLI 等——每份配置都能改，
  再冷门的工具也只差一份配置。

按终端的标准造
原生 Swift，与 Ghostty 同一个 GPU 渲染内核（libghostty），真 tmux 控制模式
（-CC）。没有账号。终端输出永远不离开你的机器。免费开源，Apache-2.0。

需要一台能 ssh 上去、装有 tmux 的机器。macOS、Linux、WSL 都行。
```

## 2. 截图

**尺寸**：iPhone 6.9"（1320×2868，17 Pro Max 模拟器现成）+ iPad 13"（2064×2752，
M5 模拟器现成）。各出一套，en/zh 各一份说明字（同底图换字，成本≈0）。

**视觉模板**（HTML→Chrome 截图合成，同影片字卡管线）：深底 #0b0d10 + 顶部一句
大字说明（Geist/PingFang，关键词穿状态色）+ 居中设备无边框截屏（圆角+细描边），
下缘微渐隐。不放假 UI：底图全部来自真实运行的 app（bentoshots/desk 会话）。

| # | 底图（真实捕捉） | 说明字 en / zh |
|---|---|---|
| 1 | iPhone 会话列表：五格状态色齐全，一格琥珀 | Your whole team, one screen / 一屏看全队 |
| 2 | 琥珀格打开，确认框在屏，快捷键条可见 | Amber means it's waiting for you / 琥珀色，就是在等你 |
| 3 | 语音输入进行中，转写含代码名 | Say it, don't type it / 动口，不动手 |
| 4 | 同一会话（与 1 同布局）继续在跑 | Leave the desk, not the work / 人走，活不停 |
| 5 | 文件树 + Markdown/代码预览 | See the files, not just the output / 看得到文件，不只是输出 |
| 6 | 主题/字体或 ⌘P 面板（iPad 版换 Parallel 全景） | Small things, done properly / 小事，也认真做 |

iPad 套：1=Parallel 全景（最能打的图，放第一）、2=Focus、3=语音、4=文件预览、
5=琥珀确认。

**生产路径**：模拟器已配好（17 Pro Max + iPad 13"，SSH 到本机的 bentoshots 会话，
base-index=1）；`simctl io screenshot` 出底图 → HTML 模板合成 → 每张双语两输出。
真机状态栏更漂亮，但模拟器可自动化重摆——首发用模拟器底图。

## 3. 写入 ASC

文案八字段（2 locale × 4）走 API 直写（app id 6797682630，en-US localization 已在，
zh-Hans 的 appInfoLocalization + versionLocalization 需新建）；截图走
appScreenshotSets API 上传。遗留事项一并处理：appStoreReviewDetail 还缺
contactPhone（要用户提供，+86/+1 格式）；demo 主机信息进审核备注
（docs/app-review-notes.md 已有草稿）。

## 4. 待用户拍板

1. 副标题两案：en `Watch & talk to your agents` vs `The terminal for AI agents`；
   zh 「盯着 agent 干活，开口指挥」 vs 「agent 时代的终端」。设计按前者。
2. 截图第 3 张（语音）：iPhone 上的语音 UI 要真实捕捉一张，需要确认现在
   iOS 端语音入口的形态适不适合出镜。
3. contactPhone。
