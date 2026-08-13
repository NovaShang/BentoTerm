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
Hero                    H1 + 三元 sub + 双 CTA + 真实产品截图        ← 页面的重心
Trust strip             一行冷静的事实
The shift               为什么需要一个新终端（两句话）
① A whole team, one screen
② Say it, don't type it
③ Leave the desk, not the work
Compounds               一行，把三条收成一个主张
Under the hood          给会扒的人看的技术页（这一版最大的新增）
Small things            六格功能网格
Privacy                 精确版
FAQ                     七问
Final CTA               下载
Footer
```

**为什么 hero 之后立刻是「the shift」而不是直接进三条**：三条主张是**解法**，解法必须先有问题。而这个问题恰好是这个受众正在经历但还没命名的——命名它就是这一页最有价值的一秒。

---

## 3. 逐段定稿

### Nav

`Bento Term` · GitHub · Support · Privacy · **[Get it]**

### Hero

> **eyebrow**: Free & open source · macOS 14+ · Apple Silicon
>
> # A terminal for running a team of agents
>
> All at once, by voice, from anywhere. Built on tmux, so the work keeps
> running when you're not there.
>
> **[Download for Mac]**  ·  View on GitHub →

**H1 与 app 欢迎屏第一句一字不差**（`A terminal for running a team of agents — all at once, by voice, from anywhere.`，这里拆成 H1 + sub）。从官网装完打开 app，第一屏应该让他确认「就是这个」，而不是读到两套说辞。

**媒体位 `[ASSET-hero]`：真实产品截图，不是 CSS 画的模拟。** 现网页那块 showcase 是纯 HTML/CSS 仿的——当时没有可拍的东西，现在有了。四个 pane、四种状态（琥珀那个是视线磁铁）、侧栏可见、深色主题、Retina。取景规矩沿用 `docs/hero-mac.png`：真仓库、真任务、无密钥。

### Trust strip

> Open source (Apache-2.0) · Signed & notarized · No accounts · Nothing between
> you and your own machine · Understands Claude Code, Codex, Gemini CLI + 7 more

（「Nothing between you and your own machine」替换 v1 的「no server of ours」——传输确实是纯 SSH，而语音走不走我们的中转在 §Privacy 里单说。）

### The shift

> ## Your agents finish in seconds. Then they wait for you.
>
> The slow part of the loop isn't the model any more — it's finding the pane
> that needs an answer, typing that answer, and the fact that all of it stops
> when you get up. Bento is built to take those three out.

这段是全页的枢纽：它把「10× 效率」这个主张换成了一个**可检验的因果**——三个停顿，三条解法。后面三节就是它的展开，顺序一一对应。

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

**最后一条 bullet 的自曝是故意的。**这个受众对"AI 智能识别"这类说法的默认反应是不信；主动说清它是模式匹配、会认错，反而是唯一能让人相信前两条的写法。

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

### Under the hood

> ## Built like a terminal, not a wrapper
>
> - **It speaks tmux's control-mode protocol.** `%begin`/`%end` block framing,
>   command numbers, out-of-band notifications — parsed, not screen-scraped.
>   Layout changes and pane lifecycle are facts tmux tells us, never guesses.
> - **tmux is the source of truth.** Bento renders and edits tmux's state, never
>   a private copy. That's why sessions outlive the app and why other tmux
>   clients always agree with it.
> - **Every pane is a real GPU terminal.** Rendering is libghostty — not a
>   webview, not a re-implementation. Your TUIs, vim, ssh and 24-bit color all
>   just work.
> - **Output never touches the main thread.** Parsing and drawing run on
>   separate queues, because a frame that stalls on the GPU must not be able to
>   freeze your keyboard.
> - **Panes tile to the character grid.** A pane title bar is exactly one cell
>   tall and dividers land on the grid line, so nothing is ever a half-character
>   off.
>
> `Read the architecture notes →`

**这一节是给会往下扒的人写的，也是全页最能换来 star 的一段。**规矩：只写别人能验证的具体事实，一个形容词都不要（"blazing fast"、"beautifully crafted" 之类一律不许出现）。上面五条每一条都能在代码里指出来。

### Small things, done properly（六格）

| | |
|---|---|
| **⌘-click any path** — rich preview with highlighting and jump-to-line, even when a TUI truncated the path. | **⌘P command palette** — every command and session, from anywhere. |
| **Drag panes like VS Code** — drop zones, docking, and moves across sessions. | **Bring your own theme** — import any iTerm2 `.itermcolors`; light, dark, or follow-system. |
| **Any monospaced font on your Mac** — enumerated from the system, not a list of four. | **Voice → shell** — say what you want, a model writes the command, you press enter. |

（v1 的 "Jump between agent turns" 已删除，不再出现。）

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

**取景硬规矩**（沿用现有 hero 截图那套）：真仓库、真任务、无密钥、无真实主机名。

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
