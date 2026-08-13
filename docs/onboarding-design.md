# Bento Term Onboarding 设计 v2

> 2026-08-10 · **v1.1（2026-07-07）整篇作废**。它的目标画像是「会用 AI，不会用终端」，那个受众已在
> 2026-07-27 的分叉里搬去 Bento Agents（`~/code/bento-acp`）。本仓库的受众下限是「会用或愿意学会用 shell」。
> 相关：`Modules/BentoUISharedKit/.../BentoSettingsSections.swift`（被本设计取代）、`docs/launcher-design.md`。
>
> 文档里的界面文案一律用英文写（app 目前无本地化，所有既有 string 都是英文）；中文是设计注解。

---

## 0. 判据

**Onboarding = 把这个用户本来就一定会进设置改的东西，提前到第一分钟摆在他面前；每一页同时讲清这一块他必须理解的事。**

一页该不该存在，只问两句，满足其一即可：

1. 一个专业用户装完一个新终端，第一件事会不会去改这个？（配色、字体、语音引擎、会话名）
2. 不讲清楚的话，他会不会**用错、看错、或者根本不知道有这个能力**？（tmux 的持久性、状态色的含义、⌘P、语音的触发方式）

第 2 条是 v1 缺的那半边，也是这一版的重头：**说明不是配菜。**在 tmux 那一页，说明就是全部——那一页几乎没有设置可调，它存在的唯一理由是布道。

---

## 1. 五个 panel，两个宿主

**一份 SwiftUI 实现，同时长在 onboarding 和设置里。** 每个 panel 是 `BentoUISharedKit` 里的一个 View，Mac 和 iOS 共用：

```swift
public enum PanelContext { case onboarding, settings }

public struct AppearancePanel: View { public init(context: PanelContext) }
public struct SpeechPanel:     View { public init(context: PanelContext) }
public struct TmuxPanel:       View { public init(context: PanelContext) }
public struct AgentsPanel:     View { public init(context: PanelContext) }
public struct FinishPanel:     View { public init(context: PanelContext) }
```

每个 panel 内部固定三种块，`context` 只影响**展开状态**，不影响内容：

| 块 | onboarding | settings |
|---|---|---|
| **说明** `ExplainBlock` | 展开 | 收进 `How this works` 折叠区，文案一字不改 |
| **暴露选项** | 展开 | 展开 |
| **隐藏选项** `AdvancedBlock` | 折叠（标题 `Advanced`） | 折叠（同一个标题） |

**由此设置页的分区 = onboarding 的五页，同名、同图标、同顺序。** 用户在引导里改过的东西，回头去设置里找，在同一个盒子里；引导本身就是设置页的第一次走查。Mac 设置窗改成五个 tab，iOS 设置列表改成五行下钻。`BentoSettingsForm` 的六段扁平结构被这五个 panel 取代。

平台差异用 panel 内部的 `#if` 处理（触发手势、⌘P 的等价入口、本机 vs 远端 tmux），**不允许分叉出两套 panel**。

---

## 2. 五页

```
⓪ Welcome      产品主张             三条断言，一种工作方式；不配置任何东西
① Appearance   看着舒服             设置：配色 / 明暗 / 字体 / 字号
② Speech       说话给 agent         设置：引擎 / 语言 · 说明：怎么触发
③ tmux         关了还在 / 两种摆法   ★ 纯说明页，引导态下没有任何设置
④ Agents       我们替你看着它们      说明：状态色 · 只读列表
⑤ Finish       出口                 说明：⌘P / 手机 · 设置：遥测
```

## ⓪ Welcome

**它不配置任何东西，这正是它的职责。**后面五页都在请用户做选择；刚装完一个终端的人，有权在被问「选什么字体」之前先知道这个产品在主张什么。

**一个论点的三个部分，不是三个功能。**论点：慢的早已不是 agent，是人还会停下的三个地方——切换、打字、离开。三条断言各拆掉一个：

> *Agents are fast. Your terminal isn't. This one is built to keep up.*
>
> **A whole team, one screen** — While one agent writes code, you're reviewing another's. All of your attention goes to planning and judging — none of it to switching windows.
>
> **Say it, don't type it** — Hold to talk to any pane — you speak about three times faster than you type. Bento reads the screen, so names and jargon come out right.
>
> **Leave the desk, not the work** — The work lives on the machine, not in a window. From the sofa or the train, your phone shows the same panes — still running.
>
> *Not three features — one way of working. And it compounds.*

**打动人靠具体，不靠倍数。**这个受众见到自造的乘数（10×）会当场折价，所以向往感全部压在「之后是什么样」的具体画面上：一个 agent 在写码、你在审另一个的；说话比打字快三倍；沙发上手机里还是同一批格子。tagline 直接点破论点——慢的早就不是 agent，是终端。收尾那句用 **compounds** 承载规模感：三条各自成立且互相放大，这个词工程师可以对着上面三条自己验证，比任何数字都可信。

页面结构：app 图标 + 名字 + tagline，三条断言各配一个着色图标，整块垂直居中，底下一句收尾。主按钮是 `Get Started` 而不是 `Next`——它说的是按下去开始什么，不只是后面还有一页。

实现在 `WelcomeManifestoView`（两端共用），**图标由 app 传进来**（macOS 是 NSImage、iOS 是 UIImage，都不该进这个包）。

## ⓪′ Connect（仅 iOS）

**iOS 独有的一页，排在 Welcome 之后、五页之前。**Mac 上 setup 是可选的锦上添花——app 一打开就能用；iOS 上**没有主机就什么都做不了**，所以新用户看到的流程必须包含这一步。

排第二而不是最后，两个理由：① 后面每一页（会话活着、agent 在主机上）讲的都是他此刻已经能看见的东西；② **挡路的那一步必须排在「Later」变得诱人之前**——放最后的话，中途退出的人会得到一个装了等于没装的 app。

> **Your agents need a machine to run on.**
> They run there, not on this phone — anything you can `ssh` into works: your Mac, a Linux box, a VM in a rack.
> Nothing to install on it. It needs `sshd` and `tmux`, which it almost certainly already has.
> If reaching it means a VPN, Tailscale or a jump host, set that up first — Bento connects the same way `ssh` does.
>
> `[+ Add a Host]`

**它不拦着 Next。**用户可能想先看完再加，或者手边没有凭据。困在一个填不出来的表单上，比让他走过去更糟。加完的主机在下面列出来打勾。

实现：`HostSetupPage`（iOS app 内，不进共享包——SSH 主机存储本来就只有 iOS 有），复用现成的 `HostEditView(mode: .add)`。首启触发挂在 `HostListView`：`firstRunCompleted_v1` 未置位且一台主机都没有时自动弹，`BENTO_FORCE_FIRST_RUN=1` 强制。

---

导航：`Later` / `Back` / `Next`（第一页是 `Get Started`），最后一页 `Done`。任何一页可直接关窗，**改过的设置立即生效并保留**（全部是 `@AppStorage` / store，本来就即时写入）。帮助菜单 → `Run Setup Again`。没有 "skip the tour"——没有 tour 可跳。

---

## ① Appearance

### 暴露的选项

| 选项 | 控件 | 默认 | 备注 |
|---|---|---|---|
| **Appearance** | 三段控件 `Follow System / Light / Dark` | Follow System | 决定下面出现几个主题槽 |
| **Color theme** | 下拉 | System | **Follow System 时出现两个下拉**（Dark theme / Light theme），钉死明暗时只出现对应那一个 |
| **Font** | 下拉，列出**这台机器上全部等宽字体** | Maple Mono NF CN | 数量不确定（用户随时会装新字体） |
| **Size** | 步进器 8–24 | Mac 12 · iOS 10 | 松手才提交（现有代码已经这么做，原因是拖动中重建 surface 在 iOS 上崩过） |

**这一页三个都用下拉，语音那页三个引擎却用卡片——同一条判断，结论相反：**主题和字体的数量都是不确定的（导入主题、装字体），而且旁边就杵着一块实时预览；**预览已经把「一眼看全」这件事做掉了，再画一套色板缩略等于做第二个预览。**语音那三个是固定的、代价截然不同的三选一，且没有任何东西能替它做预览。

字体列表的实现（真实工程量，不是换个控件）：

- macOS `NSFontManager.availableFontFamilies` 过滤 `.fixedPitch`；iOS `UIFont.familyNames` 过滤 `traitMonoSpace`。
- 存**真实 family name**，不再存 `maple-nf-cn` 这类 token。`ThemeStore.ghosttyFontFamily` 的 `default: return fontFamilyToken` 分支已经支持直接透传，老 token 的 `case` 全部保留即完成迁移，不需要写迁移代码。
- iOS chrome 侧 `BentoTheme.swift` 另有一份自己的 token switch，同步改，否则终端换了字体而周边 UI 没换。
- 打包的 Maple Mono NF CN 已注册进 CoreText，本身就会出现在枚举结果里；置顶为默认，其余按字母序。

### 隐藏的选项（`Advanced`）

- `Import iTerm2 Theme…`（`.itermcolors`，已实现）
- 已导入的自定义主题列表（可删）

### 预览

**一块真的 ghostty surface**，不是 SwiftUI 画的假终端。理由是你说的那条，而且是决定性的：假预览要自己再实现一套主题解析与上色，而**真 surface 的换主题/换字体路径已经写好了**（`applyTheme` + `.terminalThemeChanged` / `.terminalFontChanged`，所有活着的 pane 都靠它），预览白拿。

实现约束（写进代码注释，否则会踩）：

- **没有 pty、没有 shell。**`TerminalSurface.feed(_:)` 直接把一段写死的字节喂进去即可（`GhosttyTerminalSurface` 两个平台都实现了这个协议）。预览不需要进程。
- **换字号会重建 surface**（`applyTheme` 里字号变化走 recreate 分支）。所以预览必须**自己持有那段 canned 字节，在重建后重新喂一遍**——否则调字号时预览会变空白。
- 一个宿主窗口只创建一个预览 surface，随窗口销毁 teardown 一次，绝不因为改设置而反复建/拆（`project_terminal_surface_findings` 里的 teardown 崩溃就出在反复拆上）。
- **只做一个预览框**，显示当前生效的那套。Follow System 下想看另一套，用户自己去系统里切明暗——为了预览另一半而在页面上并排两个终端，不值。

预览内容用 **agent 输出**，不用 `git status`：这是我们的气质所在，顺带把第 ④ 页的状态色提前露一次。

```
┌──────────────────────────────────────────────┐
│ ● claude · ~/code/bento-term            2m14s│ ← pane 标题栏，蓝色 = working
│                                              │
│ ⏺ Read src/parser.swift (412 lines)          │
│ ⏺ Bash(swift test --filter Parser)           │
│   ⎿ Test Suite 'ParserTests' passed          │
│      Executed 18 tests, 0 failures           │ ← 绿
│                                              │
│ ⏺ I found the bug: the escape sequence is    │
│   consumed twice when the buffer wraps.      │
│ ▏                                            │ ← cursor 色
└──────────────────────────────────────────────┘
```

标题栏是真画的，且必须满足那条硬不变式：**高度 = 恰好一个字符格**（`project_tiled_layout_constraint`）。

### 说明的内容

**没有。这一页不带说明块。**

两条判据一条都不满足：配色和字体是纯口味，用不着「本来就会去改吗」的论证；也没有任何看不见的能力需要点破——预览就是全部的解释。原来那句 "Changes apply immediately to every open window" 是废话，用户改一下就看见了，删掉。

**`ExplainBlock` 是可选的**，有话说才有。这一页就是那个反例。

**不做中英混排示例。**真正在意 CJK 对齐的人是少数，做了还得决定要不要对其他语种的人隐藏，不值。

---

## ② Speech

### 暴露的选项

| 选项 | 控件 | 默认 |
|---|---|---|
| **Engine** | **三行可选卡，纵向**，不是下拉 | 中文系统 → Qwen；其余 → Apple |
| **Language** | 下拉（19 项，只能用下拉） | Auto |
| **Microphone** | 权限按钮，三态 | — |

每行 = 名字 + 一句「这个适合干什么」，Qwen 多一个 `Recommended` 徽章。**一眼看全三个，用户才会真的做选择**——这是这一页的设计核心，因为默认值在这里代价很高，而中文用户很可能一路 Next 过去。

**纵向而不是横向并排**：iPhone 上三张卡横排必然要另做一套布局，而这五个 panel 的全部价值就是一份实现两端共用。纵向三行在 Mac 上一样成立，还多出横排放不下的那句说明。

```
┌────────────────────────────────────────────────────────────┐
│ ○  Apple                                                   │
│    Never leaves this device. A little less accurate.       │
├────────────────────────────────────────────────────────────┤
│ ●  Qwen  [Recommended]                          ← selected │
│    Best on mixed and non-English speech, and it can read   │
│    what's on screen to get names and jargon right.         │
├────────────────────────────────────────────────────────────┤
│ ○  OpenAI                                                  │
│    A solid middle ground.                                  │
└────────────────────────────────────────────────────────────┘
```

**徽章只有一个，而且它是个推荐。**第一版给的是 `On-device` / `Realtime` / `Realtime` 三个分类标签：既没告诉人该选哪个，三个里还有两个一模一样。每行的文案也改成说**这个引擎适合干什么**——Apple 的价值是不出这台设备（代价是准确率略低），Qwen 的价值是混说/非英语，外加能读屏幕上的文字来认人名和术语（`asr_auto_context`，本来就只有它有），OpenAI 是中性的中间项。

中文系统下 Qwen 仍然**预选**，但三行都在眼前——是替他推荐，不是替他决定。（这取代了 v1 那个「要不要切 Qwen」的一次性弹问。）

**麦克风权限按钮**（`Try it` 已去掉，这个按钮是这一页唯一的动作，不能省——不给按钮，用户就只能等第一次按住说话时被系统弹窗打断）：

| 权限状态 | 显示 |
|---|---|
| 未决定 | `[Allow microphone]` —— 按下前先一句人话，再弹系统窗 |
| 已授权 | `✓ Microphone enabled`（不可点） |
| 被拒 | `⚠ Microphone denied` + `[Open System Settings]`（iOS：`[Open Settings]`） |

### 隐藏的选项（`Advanced`）

- **Your own API key** —— 跟着所选引擎变（`DashScope API key` / `OpenAI API key`）。折叠区顶部一句：
  > Leave blank to use Bento's servers (rate-limited). Fill it in to talk to your own account directly.
- `Bias from on-screen text`（默认开）
- `Custom vocabulary`（人名、术语，一行一个）
- **Voice → shell command**：开关 + endpoint / model / key（现 `SettingsLLMSection` 整段收进来）

### 说明的内容

这一页的说明要做两件事，**先立场，后手法**——只讲手法（「按住右键说话」）会被当成一个可有可无的小功能划过去。

**A · 我们推荐你主要用说的**

> **Bento is built to be talked to.** Typing is still there and always will be, but voice is
> the input we designed around — you speak about three times faster than you type, and when
> three panes are running, dictating into the one that needs you beats switching to it first.
>
> （原稿写「一段指令五秒说完、打一分钟」——没人五秒能说完一段，改成可验证的三倍：语速约 150 wpm，写作性打字约 50 wpm。）

**B · 怎么用**

> **Hold to record. Let go to send.**
> · Mac — hold **right-click** anywhere on a pane.
> · iPhone / iPad — **press and hold** anywhere on a pane.
> Before you let go: slide **up** to send immediately, slide **down** to cancel.
> What you said goes into that pane exactly as if you had typed it.
>
> Audio is used for transcription only — nothing is written to disk.

两端**是同一个交互**，区别只在按住的方式（Mac 右键按住 / iOS 直接按住），别的一字不差。配一张三格静态小图（按住 → 上滑 / 下滑 → 松开），两端共用，手势那格按平台换。

结尾一句挂上 `Advanced` 里那个开关，否则「对着 shell 说人话」这个能力没人知道：

> Talking to a shell instead of an agent? Turn on **Voice → shell command** below and Bento
> will turn what you said into the command.

---

## ③ tmux ★

**这一页几乎没有设置。**它存在的理由是：很多专业开发者从没用过 tmux，而 Bento 的行为都建立在它之上——不说一句，用户会把「关掉窗口 agent 还在跑」当成 bug，把 Parallel / Focus 当成两种随便切的视图皮肤。

**但说一句就够，不要讲课。**这一页的文字总共三行，技术细节（server / session / window / pane 三层、`break-pane` 搬 pane、多客户端 attach）**一个都不出现在页面上**——它们搬到一个 `Learn more about tmux` 链接后面。想懂的人会点，不想懂的人不该被拦住。

用户明确否掉的：tmux 路径 override。逻辑就是 `TmuxResolver` 现在做的事，**不给旋钮**——有合格的系统 tmux（≥ 3.2）就用他的，没有就用自带的。

### 暴露的选项

**一个都没有。**原来有一个「默认会话名」文本框——它命名的是「点 Dock 图标、且没有上次会话可恢复」时建的那个会话，一件发生一次、之后再也不产生意义的事。`default_session_name` 在代码里保留 `bento` 这个默认值，只是不再拿出来问人。

这一页因此在引导态下完全没有表单（Advanced 本来就只在设置里出现），布局也随之变了：**没有控件时不渲染一个空表单**，否则说明会被顶在窗口上沿、下面空一大片。

### 隐藏的选项（`Advanced`）

- `New session opens in` — Tab / Window / Follow system（默认 Follow system，即跟随 macOS 的 "Prefer tabs"）（iOS 无此项）
- **当前用的是哪个 tmux** —— `Using your tmux 3.5a (/opt/homebrew/bin/tmux).` 之类的一行事实。放这里因为它一切正常时不需要被读；出问题时它自己会跳到外面（见下）。

### 说明的内容 —— 三行，一张图，一个链接

> **Your agents run in tmux, so they keep working when Bento is not running.**
> ┈ 图 ┈
> Switching between the two moves the panes themselves — nothing restarts.
> Drag a pane by its title bar to rearrange them.
> Already use tmux? Bento attaches to the sessions you already have.
>
> `Learn more about tmux →`

**一句一行，不写成段落。**这是一个 app 的头一分钟，连成一段的正文正是会被跳过的那种东西——五页的说明块都按这个改了。

「关掉 Bento」改成「Bento 没在跑」：前者听起来像关个窗口，而这句话要说的是**整个 app 退出了它也还在**。最后那句是给已经在用 tmux 的人的——他们的第一个问题不是「这是什么」，是「会不会另起一套」。

一张小图，只画 Parallel ⇄ Focus，因为这是三行字里唯一说不清楚的东西。**格子叫 agent 1/2/3，不叫 api/docs/web**：这一页讲的是并行跑 agent，用文件名当窗口名会把它读成一个分屏编辑器。**Focus 的切换器是左边一竖列，不是顶部标签**——那才是这个模式在 app 里真实的样子（`WindowSidebar`），画错的控件比不画更糟。

```
   Parallel                        Focus
   ┌─────────┬─────────┐           ┌────┬──────────────┐
   │ agent 1 │ agent 2 │     ⇄     │ a1 │              │
   ├─────────┴─────────┤           │ a2 │   agent 1    │
   │      agent 3      │           │ a3 │              │
   └───────────────────┘           └────┴──────────────┘
```

**被移到链接后面的东西**（不是删掉——它们是对的，只是不该拦在第一分钟）：三层模型与 Bento UI 的对应、切换模式是真的搬 pane 因而无损可逆、一个会话可以有多个客户端、`tmux ls` / `~/.tmux.conf` / prefix 不受影响。链接指向 **tmux 官方 wiki**（`github.com/tmux/tmux/wiki`），不是我们自己写的一页：链接后面的东西就是 tmux 本身，真东西在那儿摆着还把人往我们的转述上引，是不对的所有权。

### 唯一会跳出来的例外

`TmuxResolver` 解析到「自带 tmux，但系统里有一个在跑的旧版 server」时，**那行状态从 Advanced 里跳出来变成页面上的告警**：

> ⚠️ `Your tmux is 3.1c — too old for control mode (3.2+ required), so Bento uses its own 3.5a.`
> `Different versions are different servers, so Bento won't see sessions your tmux started.` `[How to upgrade]`

这是整个 onboarding 里**唯一会静默毁掉第一印象**的情况：用户只会看到「Bento 打不开我的会话」而毫无线索。除它之外，tmux 的一切都不该出现在这一页的正文里。

### iOS

三行字一字不改（**布道跟平台无关**）。差别只有：那行「用的是哪个 tmux」变成连上主机后才有，`New session opens in` 不存在。

---

## ④ Agents

### 暴露的选项

**一个都没有。**这一页只有一份只读列表和一段说明——和第 ③ 页一样，它靠判据第 2 条立住，不靠设置。

**没有「默认 agent」这个概念。**新建会话时那个命令框永远可编辑、永远预填上次用过的（§3 第 3 条），这已经覆盖了「默认 agent」想解决的一切；再加一个设置项就是替用户先选一次，而他每次开会话本来就要选。这条同时删掉了本设计原本唯一的新增 `UserDefaults` key——**现在一个新 key 都不加。**

```
Found on this Mac
  Claude Code     claude          /opt/homebrew/bin/claude
  Codex           codex           ~/.local/bin/codex
  Cursor Agent    cursor-agent    ~/.local/bin/cursor-agent
```

**我们不装 agent。**一个都没检测到时不报警、不推荐安装，只写：

> No known agents found. You can still type any command when you start a session.

### 隐藏的选项（`Advanced`）

- `Re-scan` —— 只有这一个。

原来还列了一条 `Add a command…`（把自定义 agent 命令存进新建会话的下拉），跟着「默认 agent」一起删：它存在的理由就是喂那个选择器，而现在新建会话时直接打命令即可，不需要先去设置里登记一遍。

### 说明的内容

> Bento watches what each pane prints and tints the whole pane to match:
>
> 🔵 **Working** · 🟡 **Waiting for you** · 🟢 **Done, unread** · ⚪ **Idle**
>
> You watch colors, not text. Nothing is installed into your shell and the agent doesn't
> need to cooperate — which also means it's pattern matching, and it will occasionally be
> wrong. The color is a hint, not a guarantee.

四个色块用 `PaneState+Colors` 那一份颜色，和第 ① 页预览里的标题栏是同一个来源。

**说的是「整个 pane」不是「标题栏」**：状态色确实是一层铺满整个 pane 的半透明 wash（`PaneState.tintAlpha`，idle = 0 所以只有需要注意的状态才染），标题栏的色带只是它最浓的那一条边。写成「给标题栏上色」会把这个功能说小——它的意义正是隔着一段距离一眼扫到。

**最后半句必须留着。**这个产品已经因为「给没验证的事打绿勾」被否过一次（v1 checklist 里那条注释就是当时留下的），同理。

### 前提：检测必须先修

不修的话这一页在新机器上是空的，见 §3。

---

## ⑤ Finish

### 暴露的选项

| 选项 | 控件 | 默认 |
|---|---|---|
| **Share anonymous usage statistics** | 开关 | 关 |

### 隐藏的选项（`Advanced`）

- `What gets counted` —— 事件名全表（现 `SettingsPrivacySection` 已有）

### 说明的内容

**⌘P（用户明确要求，也是以后所有功能的落点）**

> **⌘P opens the command palette.** New session, jump to a pane, connect to an SSH host,
> open settings — it's all in there, and it's where new features will show up.

配一张两三行的实拍窄图，不要用文字描述界面。iOS 上换成对应入口。

**从手机连过来**

> Install Bento Term on your phone and connect over **SSH**. Same session, same agents,
> still running — your Mac doesn't have to be doing anything but staying awake.
> This Mac needs Remote Login on (System Settings → General → Sharing), and your phone
> needs to be able to reach it — same network, Tailscale, or a jump host.
> `[App Store]`

不要架构图，不要「主机 vs 遥控器」的比喻——给能照着做的事实。

**隐私**

沿用 `SettingsPrivacySection` 现有措辞（不含终端内容、命令、路径、主机名；随机 ID，关掉即删；直发自己的端点，无第三方 SDK）。

---

## 3. 前置修复：agent 检测（已复现根因）

检测走 `zsh -lc`。zsh 只在**交互式** shell 里读 `~/.zshrc`；`-c` 是非交互，`.zshrc` 里的 `export PATH=…` 全看不见。而 pane 里的 shell 是挂在 pty 上的 `$SHELL -l`——**是交互式的**，会读 `.zshrc`。两者必然不一致：

```
zsh -lc  'command -v fakeagent'  → NOT-FOUND        ← 检测器看到的
zsh -lic 'command -v fakeagent'  → …/bin/fakeagent  ← pane 实际看到的
```

（用 `HOME` 指向一个只在 `.zshrc` 里改 PATH 的假家目录，实测。）v1 那套向导**自己推荐的安装方式最容易撞上**：Claude Code 官方 `install.sh` 装进 `~/.local/bin` 并把 PATH 写进 shell rc，装完点 Re-check 仍然是灰的。同一个原因还会漏掉把 `claude` 包成 shell function/alias 的人。

**修法**

1. 用 pane 会用的那套 shell 语义探测：`$SHELL -lic 'command -v X'`，2 秒超时、丢弃输出。**检测的定义就是「pane 里跑不跑得起来」，那就必须用 pane 的 shell 问。**
2. 已知安装位置直查兜底，不起 shell：`~/.local/bin`、`~/.claude/local`、`/opt/homebrew/bin`、`/usr/local/bin`、`~/.bun/bin`、npm global prefix。
3. **检测结果只用于展示和预填，永远不是 gate。** 新建会话时那个 agent 命令永远是可编辑的输入框。

顺带修同一条路径上的老 bug：`TerminalViewModel.startSession(.createAgent)` 在 pty 就绪前就写 `setupScript`，`-c` 目录被静默丢掉，agent 在 app 的 cwd 而不是选的文件夹里启动。**「选目录 + 选 agent」是明确保留的简化，坏的正是它。**

---

## 4. 落地状态（2026-08-11 实现）

### 删 ✅
1. `FirstRunWindow` 的五步内容（welcome / checklist / workspace / voice / done）；壳与 `firstRunCompleted_v1`、`BENTO_FORCE_FIRST_RUN`、`BENTO_FIRST_RUN_STEP` 保留复用。
2. `ArchitectureDiagramView`（手机↔Mac 那张图）及 iOS 侧引用；`HowBentoWorksView`（概念页）。**`StateLegendCard` 从同一个文件里救回来**——它是第一次变琥珀时的一次性 tip，跟那张图无关，现在住在 `StateLegendCard.swift`。
3. agent 一键安装器（`runInstall`）。`AgentPreset.install` 目录本身留着，已无调用方。
4. 默认项目目录 `~/Bento Projects/My First Project` 与 `launchFirstWorkspace()`。
5. `BentoSettingsForm` + 六个 `SettingsXxxSection`（`SettingsAboutSection` 除外，仍是独立 section）。`SettingsKey` 原样保留——它是 panel 写进去的那份契约，也是这次搬 UI 没动任何存量数据的原因。

### 建 ✅
6. `Modules/BentoUISharedKit/Sources/BentoUISharedKit/Panels/`：`PanelKit`（`PanelContext` / `PanelPage` / `ExplainBlock` / `AdvancedBlock` / 文案样式）+ 五个 panel。
7. `GhosttyThemePreview`（在 **BentoGhosttyKit**，不在 UISharedKit——surface 属于引擎层，由 app 组合）：真 surface、无 pty、`feed` 写死的 agent 输出、`applyTheme` 后重喂。
8. `ParallelFocusFigure` / `VoiceGestureFigure` / `PaneStateLegend`（`PanelFigures.swift`，SwiftUI 画，两端共用）。
9. `MonospacedFonts`：CoreText 枚举全部等宽 family + `normalized(_:available:)` 做 token→family 迁移；iOS `BentoTheme.terminalFont` 同步认 family（新增 `namedFont(family:size:)`，因为 `UIFont(name:)` 要的是 PostScript 名而存的是 family）。
10. 宿主：Mac `FirstRunWindow` 五页（`Later / Back / Next / Done`）+ `MacSetupPanel`；Mac 设置窗 = 五个 tab；iOS `SetupFlowView` + `IOSSetupPanel`，设置页改五行下钻。
11. `TmuxResolver.facts()` + 「系统里有一个在跑的旧版 server」探测（`serverIsRunning(tmuxAt:)`）——原来只判版本，判不出「他真的在用」。
12. App 菜单 Settings… 下方的 `Run Setup Again…`。

### 修 ✅
13. Agent 探测：`InstalledAgents.scan()`（`$SHELL -lic`、一次 shell 问全部命令、2 秒超时、已知路径兜底）。命名让开了 `AgentStatusRules` 里已有的 `AgentDetector`（那个判的是 pane 的运行状态）。

### 还没做
- **`startSession(.createAgent)` 的 pty 抢跑竞态**（§3 末尾那条）——同一条路径上的老 bug，这次没碰。
- **⌘P 那张实拍图**（第 ⑤ 页现在只有文字）。

### 新增的 UserDefaults key：**零**

五页读写的全部是已经存在的那些：`terminal_font_size`、`terminal_font_family`、`appearance_mode`、`dark_theme_id`、`light_theme_id`、`speech_engine`、`speech_locale`、`openai_api_key`、`dashscope_api_key`、`asr_auto_context`、`asr_vocab`、`llm_*`、`telemetry_enabled`、`default_session_name`、`mac_new_session_placement`、`auto_hide_toolbar_fullscreen`、`haptics_enabled`、`path_preview_enabled`。

两个一度写进设计、又被砍掉的：

- ~~`tmux_path_override`~~ —— 有合格的系统 tmux 就用系统的，没有就用自带的，不给旋钮。
- ~~`default_agent_command`~~ —— 没有「默认 agent」这个概念；新建会话时的命令框可编辑且记住上次，已经够了。

**一个会看得见的行为变化**：`terminal_font_family` 没存过值时，旧代码里设置界面显示 Maple Mono NF CN 而引擎用的是 ghostty 自己的默认字体——界面在说谎。现在 panel 第一次出现时把 `Maple Mono NF CN` 写实，于是从没动过字体的老用户升级后终端字体会真的变成 Maple。iOS 的 chrome 一直就按 Maple 渲染，这次是让终端和它对齐。

---

## 5. 未决

1. **⌘P 那张实拍图**怎么产出与维护（界面一改就过期）；要不要改成一个真的、可点的迷你 palette。第 ⑤ 页现在只有文字。
2. ~~**iOS 的 onboarding 触发时机**~~ **已定（2026-08-11）**：**首启就弹，并且流程里包含「加第一台主机」这一步**（见 §⓪ 后面那节）。理由是 iOS 上没有主机则整个 app 无事可做，那么新用户看到的流程就必须包含这一步。
3. **预览卡的取景**：现在是一段固定的 agent 输出。深色主题下好看，浅色主题下几种 ANSI 色的对比度还没逐个核过。
