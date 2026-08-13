# Bento Term 落地页设计 v2

> 2026-08-11 · **v1（2026-07，分叉前）作废**，理由见 §1。
> 落点：`bentoai.dev/term/`（仓库 `~/code/bento-web`，Cloudflare Pages，已有一版页面 + 一份 `style.css`）。
> 页面文案英文，中文是设计注解。与 app 内的欢迎屏共用同一套主张（`docs/onboarding-design.md` §⓪）。

---

## 0. 这一页的任务

**访客是谁**：已经在跑 agent 的开发者，从 HN / X / GitHub 点进来。他不缺终端，他缺的是一个能盯住五个 agent 的地方。

**他要在 15 秒内相信三件事**：① 这是个真终端（不是套壳）；② 它解决的是"同时supervise 一堆 agent"这个具体问题；③ 试它的成本是零。

**目标动作，按优先级**：
1. Download for Mac（主，重复三次：hero / 三条主张之后 / 页尾）
2. GitHub star（导航常驻，被动）
3. iOS——**等上架后直接给 App Store 链接**。在那之前不要做等待名单：需要后端、需要收邮箱，跟"无账号"的隐私叙事打架，收益也小。

---

## 1. v1 作废的理由

v1 是分叉前写的，除了域名过期，**有三条 claim 现在是假的**——落地页写假话的代价比别处都高：

| v1 的说法 | 现状 |
|---|---|
| "Jump between agent turns with one click" | **回合导航 2026-08-01 已删**。写了就是卖一个不存在的功能。 |
| iOS teaser："Scan-to-pair, end-to-end encrypted" | **配对和 relay 传输已整块删除**，现在是普通 SSH。 |
| "Hosted conveniences free while in beta; optional paid services may come later" | Term 的变现钩子（NAT 穿透/中转额度）随 relay 一起没了，**不在这个产品上做变现设计**。别留伏笔。 |

另外现网页上那句 **"No accounts, no server of ours"** 不够准：语音 ASR / voice→shell 确实会走 `relay.bentoai.dev`。准确的说法是**「你和你的机器之间没有我们」**——传输是纯 SSH，这句为真；语音单独说明。

结构上 v1 也不再对：它按功能罗列（states / voice / continuity / grid），而现在这三条是**一个论点的三个部分**，页面必须让人读出这层关系，否则又变成功能清单。

---

## 2. 结构总览

```
Nav                     logo · GitHub · Support · Privacy · [Get it]
Hero                    H1 + sub + 双 CTA + 产品图                  ← 页面的重心
Trust strip             一行冷静的事实
① A whole team, one screen
② Say it, don't type it
③ Leave the desk, not the work
Compounds               一行，把三条收成一个主张
Day to day              三个次要功能，每个带一块 shot（2026-08-13 新增）
Under the hood          给会扒的人看的技术页（这一版最大的新增）
Small things            六格功能网格
Privacy                 精确版
FAQ                     七问
Final CTA               下载
Footer
```

**为什么 hero 之后直接进三节，没有问题陈述**：一度有过一段（见下），删了。工具页的读者是来看东西的，hero 和截图已经说清是什么；再插一段抽象论述只会推迟产品出场。

---

## 3. 逐段定稿

### Nav

`Bento Term` · GitHub · Support · Privacy · **[Get it]**

### Hero

> **eyebrow**: Native for Mac, iPhone and iPad · Free & open source
>
> # A terminal for *watching* and *talking to* your agents
>
> Every pane shows what it's doing. Hold to talk to one instead of typing it.
>
> **[Download for Mac]**  ·  View on GitHub →

**H1 与 app 欢迎屏那句一字不差。**从官网装完打开 app，第一屏应该是确认「就是这个」，而不是第二遍推销。

**三条定稿规矩**（推翻了好几版才落下来的）：

1. **两个价值点，两个动词。**watching 和 talking 各自对应一个，H1 的结构就是产品的结构。第三件事（工作不停）是**支撑**不是主张——它解释的是「为什么关了窗口还在跑」，放副标题和 §③。
2. **不进 H1 的两个词：`tmux` 和 `many`。**tmux 放第一句会变成筛子——受众都用终端，但不一定用过 tmux，而恰恰是这批人最需要它；所以它降到 trust strip，并且写成「bundled, and fine if you've never used it」。`many / team / multi / parallel` 则是在夸规模，**俗的从来不是 "agents" 这个词，是对数量的炫耀**。
3. **音区是「一个开发者做的工具」，不是发布会。**这是个人非商业项目，受众是开发者，所以参照系是 ripgrep / fzf / Ghostty 的落地页：平铺直叙地说这是什么，一个承诺都不给。凡是「maximize your productivity」「in the agent era」这类句子一律不用——前者不可证伪，后者是趋势语言，会过期。

**媒体位 `[ASSET-hero]`：真实产品截图，不是 CSS 画的模拟。** 现网页那块 showcase 是纯 HTML/CSS 仿的——当时没有可拍的东西，现在有了。四个 pane、四种状态（琥珀那个是视线磁铁）、侧栏可见、深色主题、Retina。取景规矩沿用 `docs/hero-mac.png`：真仓库、真任务、无密钥。

**2026-08-13：H1 上方的胶囊 badge 删了。**那颗带脉冲绿点的圆角小标签（`✦ Free & open source`）是 AI 生成落地页最好认的一个记号，而且它写的两件事 trust strip 下面一屏就又说了一遍。现在标题直接开页，事实挪到按钮下方的一行等宽小字——底部 CTA 一直就是这个形式，所以它读起来是本页的固有习惯而不是又一个小控件；而且那正是已经决定要点的人会看的位置。`.hero` 顶部 padding 从 `clamp(48px,9vh,104px)` 提到 `clamp(88px,15vh,156px)` 补掉 badge 让出的约 63px，入场动画整体上移一档。

按钮下那行必须回答**"我能用吗"**，所以它同时说两个轴：

> Free and open source · Native on Mac, iPhone and iPad · Your agents run on macOS, Linux or WSL

**两个轴不能混。**app 是 Mac/iPhone/iPad 独占（没有 Windows 客户端，这点不含糊）；**agent 跑在哪台机器上跟这个无关**——任何能 ssh 进去、装了 tmux 的机器都行，Mac、Linux 服务器、Windows 上的 WSL 都一样。少了后半句，一个开发机是 Linux 或 WSL 的人看完 "Native on Mac, iPhone and iPad" 就走了。这一条在三个深度各说一次：hero 一行、§③ 的 bullet、FAQ「What do I need on the other end?」（那条现在明确写出 app 端和主机端可以不是同一类系统）。

**措辞的安全边界**：全篇一律用「anything with `sshd` and `tmux`」的框子来带出 WSL，不写成对 WSL 的专门支持——我们没有为 WSL 做任何事，它成立纯粹因为它就是一台普通的 Linux SSH 主机（用户得自己把 sshd 起起来）。这个框子在，句子就永远是真的。

### Trust strip

> Open source (Apache-2.0) · Signed & notarized · No accounts · Nothing between
> you and your own machine · Understands Claude Code, Codex, Gemini CLI + 7 more

（「Nothing between you and your own machine」替换 v1 的「no server of ours」——传输确实是纯 SSH，而语音走不走我们的中转在 §Privacy 里单说。）

### ~~The shift~~ —— 已删

这一页曾经在 hero 之后放一段「问题陈述」（"Agents can work for hours without you…"）。**删掉了**：hero 已经说了产品是什么，紧接着一段抽象论述只是在推迟产品本身。问题陈述是营销页的体例，而这一页的参照系是工具页——ripgrep / fzf / Ghostty 都没有这一节，它们直接展示东西。

（那段论证本身是对的，只是不该独占一屏：**单个 agent 能连续跑一小时 → 你的注意力是空的 → 才值得同时开几个**。要留的话，它属于 §① 的第一句，贴着一个具体功能说，而不是悬空一段。措辞红线仍然有效：不要写「agents got slower」。）

### ① A whole team, one screen

> Every agent gets a pane. While one writes code, you're reviewing another's —
> all of your attention on planning and judging, none of it on switching
> windows.
>
> - **You watch colors, not text.** Each pane is tinted by what its agent is
>   doing: working, waiting for you, done-and-unread, idle.
> - **Parallel and Focus.** Everything tiled, or one agent full-size with the
>   rest in a sidebar. Switching moves the panes themselves — nothing restarts,
>   and every device attached to the session follows.
> - **Nothing installed into your shell.** Detection is pure observation of
>   what the pane prints, so agents don't have to cooperate — and it's pattern
>   matching, so the color is a hint, not a guarantee.

`[ASSET-states]` 四条标题栏的近景 + 侧栏状态点，标注四种状态。

**「Nothing in your shell」这条的正面价值是"不用装任何东西"**——没有 init 行、没有 hook、不需要 agent 配合。对这个受众这是硬卖点：他们见过太多要求往 `.zshrc` 里加一行的工具。

**这条 bullet 曾经带着一句自曝**（"it's a hint, not a guarantee"），已删。理由：**落地页上主动写免责声明，是在替读者制造一个他本来没有的疑虑**——没有人是带着"我猜它的状态检测不准"来的。那句话该在的两个地方它都在：app 的 Agents 面板（用户正要开始依赖它）和本页 FAQ 的「How is state detected?」（他主动问了）。**同一句诚实，放对地方是加分，放错地方是自伤。**

### ② Say it, don't type it

> Hold right-click on any pane and talk. You speak about three times faster
> than you type, and the words go into that pane exactly as if you'd typed them.
>
> - **It reads the screen.** Recognition is biased by what's in front of you,
>   so file names, flags and jargon come out right — including mixed
>   Chinese/English.
> - **Slide while you hold.** Up sends immediately, down cancels.
> - **Three engines.** Apple on-device (never leaves the machine), Qwen
>   (recommended — best on mixed and non-English speech), OpenAI. Use ours, or
>   put in your own API key.

`[ASSET-voice]` 10–15 秒循环：按住 → 说一句中英混的 → 转写浮现 → 上滑发送。字号要大到 720px 下能读。

### ③ Leave the desk, not the work

> The work lives on the machine, not in this window. Quit the app, close the
> laptop, lose Wi-Fi — the agents keep going. Open your phone on the sofa and
> the same panes are there, still running.
>
> - **It's real tmux, not a wrapper around it.** Your `tmux ls` sessions are
>   Bento's sessions; your `~/.tmux.conf` loads; your prefix key is untouched.
> - **Nothing to install on the host.** Plain SSH to anything running `sshd`
>   and `tmux` — your Mac, a Linux box, a server in a cupboard.
> - **Already a tmux user?** Bento attaches to the server you already have.

`[ASSET-continuity]` 两帧对照或 10 秒循环：Mac 上 agent 在跑 → 退出 app → 手机上同一批 pane 还在跑。**手机那半必须是真拍的**——这是全页最容易被当成 PPT 的一张图，假一次全盘皆输。

### Compounds（一行，居中，页面唯一一处抒情）

> **Not three features — one way of working. And it compounds.**
>
> Parallel agents make faster input worth having. Faster input keeps parallel
> agents from piling up. Neither one resets when you stand up.

（这三句是"为什么是十倍"的全部论证。不写数字，让读者自己得出结论。）

### Day to day（2026-08-13 新增，三格，每格带一块 shot）

三条主张之上是论证，这一节是**日常手感**——放在 Compounds 之后，正好接住"那平时用起来是什么样"。刻意做得比 pillar 轻（卡片，不是左右分栏的大块），因为它们本来就是次要功能；但每格**必须带图**，否则和下面的六格文字网格没有区别。

> **See the files, not just the output** — Every pane carries its working directory, so its
> file tree is always one click away — any depth, search included. When an agent prints a
> path, click it; the file opens with syntax highlighting and a line gutter, even at `:42`,
> and even if a TUI truncated the line. PDFs, images and documents go to Quick Look. From an
> iPhone it's the same tree over the same SSH connection — read a file on your Mac or your
> server, and save it out.
>
> **Panes move like windows** — Split right or down, then drag a pane by its title bar to
> wherever it fits — including into another session. Or duplicate one and get a second pane in
> the same directory running the same thing. It isn't a view of a layout: every drop is a real
> tmux move, so a `tmux attach` from anywhere else agrees with what you see.
>
> **Never type a command again** — If you'd rather not, you don't have to. Pick a folder, pick
> an agent, pick a layout — Bento opens the panes and starts the agent in every one of them.
> Four Claude Codes in one repo is three clicks and no shell. Everything after that is one ⌘P
> away.

三条都核对过代码，措辞受这些事实约束：

- **文件树**：`FileTreeBrowserView` 按 cwd 生根、逐层 readdir（深度无限），iOS 走同一条 SSH 上的 SFTP（`CitadelSFTPFileSource`）。文本/代码/Markdown 走自己的渲染器（高亮 + 行号 + `path:42` 跳转），其余交 Quick Look——所以不能笼统写"预览任何文件"，写法要分这两类。"save it out" 对应 `FileShareButton`（iOS 是 `UIActivityViewController`），说"download"会让人以为有下载管理。
- **拖动**：`join-pane` 拒绝同窗口移动，实际走 `move-pane`；"real tmux move" 这句是这一段唯一值得说的差异点，别丢。
- **Duplicate**：是 `.duplicateCurrent` seed —— 同目录 **+ 同启动命令**，两个都要提，只说"同目录"就漏了一半。
- **向导**：name / workingDir / agent / layout 四项，layout 有 6 种（solo → 2×2）。"Four Claude Codes in one repo" 说的就是 `.quadTile`，是真的，不是修辞。

### Under the hood

**三条，不是六条。**初稿列了六项（控制模式、真相源、GPU 渲染、主线程、字符格平铺、自带 tmux），单条都成立，合起来太散——读者记不住六件事，只会得到"这人很努力"的印象。收成三条，每条对应一个别人做不到的层：**协议层 / 引擎层 / 规则层。**

> ## Built like a terminal, not a wrapper
>
> **tmux, in control mode** — Bento speaks tmux's `-CC` protocol instead of typing at it:
> layouts, panes and lifecycle arrive as notifications, and every change goes back as a
> command. Almost nothing is kept locally — tmux holds the state — so a plain `tmux attach`
> from any other terminal shows exactly what you were looking at.
>
> **libghostty does the rendering** — The same GPU-accelerated core as Ghostty, on the Mac and
> on iPhone and iPad — not a webview, and not a second implementation for mobile. Parsing and
> drawing run on separate threads, so a frame stalled on the GPU can't freeze your keyboard and
> heavy output doesn't cost you keystroke latency.
>
> **State detection is a config, not a black box** — Every agent is a profile: output patterns,
> title patterns, prompt boundaries, quick keys — editable, and extendable to a tool nobody has
> heard of. Want it deterministic rather than inferred? Have your agent's own hook print a
> marker and match on that.

每条都必须是**别人能验证的具体事实，一个形容词都没有**（"blazing fast"、"beautifully crafted" 之类一律不许出现）。

**排版：一整块面板，里面三列。**这一节返工了四次，最后一次才想明白前三次为什么都不行：

1. 三个带框卡片 → 散
2. 左标题 + 右三行 → 标题孤零零撑出一片空白
3. 三列裸文字 + 代码 → **用户的原话是「我觉得是 CSS 没加载出来」**

第三次的失败解释了前两次：**这一页的每一块内容都坐在一个有边框、有圆角、有渐变的面上**（终端窗口、`.media` 图框、六个功能格），唯独这一节是裸的文字——在这个语境里，少装饰不读作克制，读作样式挂了。

定稿：用页面自己的 `.media` 面，里面三列用 1px 竖线分隔，每列配一块**真东西**——控制模式的 `%begin`/`%layout-change`/`%end` 帧、三条队列的分工、一段 profile 的 `outputPatterns`。既解决"没得看"，也正好是这个受众想看的。

两个细节：标题**居中收成一行**；三列用 flex + `p { flex:1 }`，让三块代码**落在同一条基线**上，否则段落长短不同会让它们像楼梯一样往下错。

**第三条的 hook 说法要留意。**代码里**没有** OSC 133 / shell 集成那类内建 hook 支持，所以不能写成"我们支持 hooks"。能成立的说法是现在这句：检测是**用户可编辑的模式**，所以你可以让 agent 自己的 hook 打印一个标记，再配一条匹配它的规则——**不需要我们加任何代码，今天就能做**。这条同时不跟 §① 的「Nothing in your shell」打架：默认零配置，确定性是可选的。

### Small things, done properly（六格）

| | |
|---|---|
| **⌘P command palette** — every command and session, from anywhere. | **Your `~/.ssh/config`** — the hosts you already have, one click from the launcher. |
| **⌘F in the scrollback** — search runs in the engine, matches highlight in place. | **Bring your own theme** — import any iTerm2 `.itermcolors`; light, dark, or follow-system. |
| **Any monospaced font on your Mac** — enumerated from the system, not a list of four. | **Built for the phone** — keyboard avoidance on the real cursor, inline CJK compose, scroll inertia. |

（v1 的 "Jump between agent turns" 已删除，不再出现。）

**2026-08-13：路径预览和拖动 pane 从这里升到了 Day to day。**这两格原来在这个网格里各占一行文字，现在有了自己的图和完整说法，留在这里就是同一件事说两遍——补进来的两格（`~/.ssh/config`、⌘F）都是代码里确实有、且此前整页没提过的。

### Privacy

> ## Yours, on your machine
>
> No accounts — there's nothing to sign up for. Your terminal output never
> leaves your machine; the connection to it is plain SSH, with nothing of ours
> in between.
>
> Two features do reach out, and only when you use them: speech recognition and
> voice → shell go through Bento's relay (rate-limited) unless you put in your
> own API key. Telemetry is off by default and, when on, is a closed set of
> event names — never terminal content, commands, paths or hostnames.

### FAQ

- **Do I need to know tmux?** No — it's bundled and stays out of the way. If you
  do use tmux, Bento attaches to the sessions you already have.
- **Which agents does it understand?** Ten presets with live state detection —
  Claude Code, Codex, Gemini CLI, OpenCode, Cursor Agent, Copilot CLI, Amp,
  OpenClaw, Hermes, Antigravity — plus plain shells and any command you type.
- **Does it install anything on my server?** No. Anything with `sshd` and
  `tmux` works as it is.
- **Can I reach a machine behind NAT?** That's yours to arrange — Bento speaks
  plain SSH, so a VPN, Tailscale or a jump host in `~/.ssh/config` all work.
- **Intel Macs?** Not currently. Apple Silicon, macOS 14+.
- **What does it cost?** Nothing. Apache-2.0, and the app is the whole product.
- **iOS?** *(上架后：链接 App Store。上架前：一句 "In review." 不做等待名单。)*
- **Where do I report bugs?** GitHub issues — the tracker is public.

### Final CTA

> ## Your agents are already running. Go see them.
>
> **[Download for Mac]** — Free & open source · macOS 14+ · Apple Silicon

---

## 4. 素材清单

| 槽位 | 形式 | 要求 |
|---|---|---|
| `[ASSET-hero]` | 真实截图（首选）或 20–30s 静音循环 | 2×2 四个 pane、四种状态、侧栏可见、深色。**必须是真 app**，不再用 CSS 仿。 |
| `[ASSET-states]` | 标注版静态图 | 四条标题栏近景 + 侧栏状态点，四个标注。 |
| `[ASSET-voice]` | 10–15s 循环 | 按住 → 中英混说 → 转写 → 上滑发送。 |
| `[ASSET-continuity]` | 两帧对照或 10s 循环 | Mac 在跑 → 手机上同一批 pane。**手机那半必须真拍。** |
| `[ASSET-og]` | 1200×630 | 图标 + H1 + 四状态 pane 条，深色。 |
| `[ASSET-files]` | 8–12s 循环 | 输出里点一条路径 → 预览打开、跳到 `:42`；再从文件树点开一个 PDF。 |
| `[ASSET-drag]` | 8–12s 循环 | 抓住标题栏拖起一个 pane → 投放区亮起 → 落下，布局重排。 |
| `[ASSET-wizard]` | 8–12s 循环 | 选目录 → 选 agent → 选 2×2 → Launch，四个 pane 同时起来。 |

**取景硬规矩**（沿用现有 hero 截图那套）：真仓库、真任务、无密钥、无真实主机名。

**下一步是把页面上所有 CSS 假图换成真录屏。**为此每个图位都已经改成固定比例的容器，换的时候只动容器里那一层：

- 新增的三格用 `.shot`（`aspect-ratio:16/10`），里面直接放 `<video autoplay muted loop playsinline poster>`，CSS 已经写好 `object-fit:cover` 的绝对定位规则，**页面不会掉一个像素**。
- 三节 pillar 的图在 `.media` 里，hero 的在 `.showcase` 里，这两处换视频要先给容器一个显式比例，否则 CSS 仿图撤走时高度会塌。
- 编码：H.264 MP4 + VP9 WebM 两份，短边 ≥ 720，每段控制在 1–2 MB；`preload="none"` + `poster`，首屏那段除外。
- 手机上 `.craft-item` 会横过来（图占 44%），录屏的取景要保证在 44% 宽度下主体仍然认得出来——这是选镜头时的实际约束，不是后期能补的。

---

## 5. 实现

- **在 `~/code/bento-web/site/term/index.html` 上改，不重写。**那页的设计系统（自托管 Geist、深色、atmosphere 背景、`style.css` 411 行）是对的，要换的是**结构与文案**。
- 字体继续自托管，不许换 CDN——隐私页把"没有第三方追踪"写成了产品声明。
- 下载按钮打 `releases/latest/download/...` 永久链接，发版不用改页面。
- 统计只用 Cloudflare 自带的，不接第三方。
- 部署：`env -u XDG_CONFIG_HOME npx wrangler pages deploy site --project-name bentoai`。
- **自定义域还差一步**：`bentoai.dev` 要在 Cloudflare 面板手加 CNAME 指到 `bentoai.pages.dev`（wrangler 的 token 只有 zone read）。

---

## 6. 未决

1. **hero 用静态图还是循环视频。**视频转化更好但要真录、要压到能自动播的体积；静态图今天就能出。建议：先上静态图，视频作为第二版。
2. **中文版 `/term/cn`。**主张这一套翻译成中文不难，但语音那节的说服力在中文语境里更强（中英混说这个痛点英文读者无感）。做不做取决于你想先打哪个池子。
3. **`Read the architecture notes →` 落到哪。**目前 README 没有对应章节，要么补一节，要么这个链接先不放。
