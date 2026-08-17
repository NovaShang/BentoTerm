# 发布文案总台账（2026-08-16 更新）

> 所有平台的定稿文案，自包含，不再指向聊天记录。改动直接改这里。
> 信息层级铁律：先说主张三元素（**并行、语音、远程**）→ 效果（效率成倍）→
> 技术（native / libghostty / tmux -CC）→ 平台 → 无账号 + BYOK。
> 状态颜色（蓝/琥珀/绿）是实现细节，不进一句话文案。

## 状态

| 渠道 | 状态 |
|---|---|
| App Store | **已回复审核**（2026-08-16）：Resolution Center 附 1:55 实体机录屏 `film/out/review-recording.mp4` + 七项答复；备注已整合到 3069 字符（4000 上限）。文案中英双语、截图 16 张（iPhone×5 + iPad×3，双语）均已上传 COMPLETE。等审核结果 |
| Show HN | 已发（item 49312011）。首评被新号反垃圾误杀。拍板：**约一周后重发**，先养账号；卡美东周二–四早 8–10 点（北京 20–23 点） |
| LinkedIn | 已发 |
| 知乎 | 视频已发；专栏、回答待发 |
| Product Hunt | **已发**（producthunt.com/products/bento-term）。Maker 首评记得贴；评论区当天全回 |
| Bilibili / YouTube / TikTok / 视频号 / 朋友圈 | **已发** |
| 小红书 | 待传（creator.xiaohongshu.com，若也要 app 扫码则搁置） |
| 抖音 | **搁置**——网页端上传要 app 扫码认证，美国装不了 app；可选：国内朋友代发 |
| X | 新号 under review，养号中；解封后发 thread |
| 即刻 | 稿子就绪，待发 |
| V2EX | **受阻**——已转邀请制，无号。替代：Linux.do（注册开放，V2EX 流失用户聚集地，同一篇稿直接用）或朋友代发 |
| Reddit r/ClaudeAI | 待写；需先攒 comment karma |
| awesome PR | **全部提交**：awesome-tmux #334、awesome-mac #2587（四语）、awesome-claude-code 表单已填。等维护者处理 |
| 长尾 | Terminal Trove、AlternativeTo、Ghostty Discussions showcase、homebrew-cask 收录 PR、Console.dev/TLDR 投递、少数派投稿 |

## 视频素材对照

| 文件（film/out/） | 用途 |
|---|---|
| `landscape-en.mp4` 1920×1080 | YouTube、PH gallery（经 YouTube 链接） |
| `landscape-zh.mp4` | Bilibili |
| `portrait-zh.mp4` 1080×1920 | 微信视频号、抖音、小红书 |
| `portrait-en.mp4` | TikTok、YouTube Shorts、Reels |
| `v3.mp4` / `v3-zh.mp4` 2160×2160 | 方版母版（网站内嵌、信息流广告位） |
| `linkedin-cover.png` 2400×1254 | LinkedIn / X / 公众号题图 |
| `ph/g1–g4.png` + `ph/thumb-240.png` | PH gallery 与缩略图 |

---

## Show HN

**已用标题**：`Show HN: Bento Term – native tmux client with agent states and voice input`
**重发候选**（微调即可）：
- `Show HN: Bento Term – watch your AI agents' states, talk instead of typing`
- `Show HN: Bento Term – a terminal for running AI agents: states + voice`

**链接**：https://bentoai.dev/term/ （或 GitHub 仓库，二选一）

**首评**：

```
Hi HN! I run several Claude Code sessions side by side in tmux. Originally I just wanted a tmux client for my iPhone and iPad to replace iTerm2 — split panes plus voice input, so I could keep working while looking after my kid. Then I noticed I was getting more done on the iPad than at my 27-inch monitor, so I built the Mac version and it became my daily driver.

What it actually is: a native Swift client on top of tmux control mode (-CC). tmux stays the single source of truth — attach from any other terminal and you see the same layout. Rendering is libghostty (Ghostty's engine). Each pane's agent state (working / waiting for input / done / idle) is detected client-side from pane output and titles, per-agent profiles, nothing injected into your shell and nothing installed on the remote machine. Voice input is push-to-talk with vocabulary biased by on-screen text, so identifiers and file names transcribe correctly.

Honest limitations: state detection is pattern matching, so it can be wrong — the color is a hint, not a guarantee. Apple Silicon only for now. The iOS app is still in App Store review.

Free, Apache-2.0. I'd love to hear what breaks, especially from people with heavy tmux configs.
```

**预备答案**：①"又一个终端" → 不是终端内核，是 tmux -CC 客户端 + 状态层；②语音隐私 → 默认 Apple 端上识别，relay 可用自己的 key 绕过，终端输出永不上传；③Intel → 暂不支持，Apple Silicon only。

**纪律**：不拉票不发直链；首小时守评论区；沉了可邮件 hn@ycombinator.com 进 second-chance pool 或隔周重发。

---

## Product Hunt

- **Name**: `Bento Term`
- **Tagline**（≤60）：`The terminal for watching and talking to your AI agents`（55）
  三元素备选：`Run agents in parallel, by voice, from anywhere`（46）
- **Topics**: Developer Tools · Open Source · Mac · Artificial Intelligence · Productivity
- **Pricing**: Free
- **Link**: https://bentoai.dev/term/
- **Gallery**: g1–g4 按序；视频用 YouTube 链接（landscape-en 传 YouTube 后填入，需 Public）
- **Thumbnail**: ph/thumb-240.png

**Description**（498 字符）：

```
Run your agents in parallel, direct them by voice, and pick the work up from anywhere. Each habit makes the others stronger — together they multiply how much you get done.

Under the hood it's native Swift end to end, rendered on libghostty (Ghostty's GPU engine), speaking real tmux control mode over plain SSH. One session follows you across Mac, iPhone and iPad; your agents run on macOS, Linux or WSL.

No account required. Voice works out of the box, or bring your own API key. Free & open source, Apache-2.0.
```

**Maker 首评**：

```
Hi Product Hunt! I run several Claude Code sessions side by side in tmux. Originally I just wanted a tmux client for my iPhone and iPad — split panes plus voice input, so I could keep working while looking after my kid. Then I noticed I was getting more done on the iPad than at my 27-inch monitor, so I built the Mac version too. Three months later it's my daily driver.

The way of working is three things that reinforce each other: run agents in parallel, direct them by voice, and pick the work up from anywhere. Every agent gets a pane on one screen, so a glance tells you who needs attention. You answer by talking — the recognition reads the screen, so file names and identifiers come out right. And because everything lives in real tmux over SSH, the same session follows you from the Mac to your phone.

Under the hood: native Swift, libghostty rendering (Ghostty's engine), real tmux control mode. Nothing installed on your remote machine. No account, bring your own API key if you like. Free and Apache-2.0.

Would love your feedback — especially from anyone juggling long-running agents.
```

**时机**：立即发布会挤进当天剩余时段的榜；定时到下一个 00:01 PT（北京 15:00）从新一天起跑，周末竞品少。

---

## LinkedIn（已发，存档）

**中文版**：

```
我有个习惯：在 tmux 里同时跑好几个 Claude Code。

一开始我只是想做个手机和 iPad 上能用的 tmux 客户端，代替 iTerm2——要能分屏、能语音输入，带娃的时候也能干活。

结果用着用着发现，我在 iPad 上干活，效率居然比坐在 27 寸显示器前还高。最大的原因是语音：指挥 agent 本来就打不了几个字，说话快得多，而且识别能把文件名、代码里的标识符都认对，中英文混着说也没问题。剩下的靠颜色——每个 agent 一个格子，蓝的在干活，琥珀的在等我，绿的是干完了，扫一眼就知道该管谁。

于是我把 Mac 版也做了，现在天天用它干活。三个月下来，身边几个朋友也在用，感受都差不多：开一群 agent、看颜色、动口不动手，提效是实打实的。

这东西叫 Bento Term——便当盒的意思，一格一个 agent。

对技术感兴趣的看这段：端到端原生 Swift；渲染用 libghostty（就是 Ghostty 那个 GPU 引擎）；底下是真 tmux（-CC 控制模式），从别的终端 attach 看到的布局一模一样；语音是 Qwen 实时识别，按屏幕内容加权；agent 状态检测全在客户端，远端机器啥都不用装。

免费开源（Apache-2.0）。Mac 版能直接下，iPhone/iPad 版在 App Store 审核中。

如果你也每天开着好几个 agent，可以试试。用着有什么问题，直接来找我：bentoai.dev/term
```

**英文版**：

```
I have a habit of running several Claude Code sessions side by side in tmux.

Originally all I wanted was a tmux client for my phone and iPad to replace iTerm2. Split panes plus voice input, so I could keep working while looking after my kid.

Then I noticed I was getting more done on the iPad than at my 27-inch monitor. The main reason is voice. Directing agents doesn't take much typing anyway, and speaking is much faster. The recognition gets file names and code identifiers right, even when I mix Chinese and English in one sentence. The rest is the colors. Every agent gets its own pane: blue is working, amber is waiting for me, green is done. One glance tells me who needs attention.

So I built a Mac version too and made it my daily working environment. Three months in, my friends and I keep coming to the same conclusion: run a group of agents, read the colors, talk instead of type. It's a real productivity gain.

It's called Bento Term, named after the bento box. One agent per compartment.

Some engineering details: native Swift end to end. Rendering is libghostty, the same GPU engine as Ghostty. tmux control mode (-CC) is the single source of truth, so attaching from any other terminal shows exactly the same layout. Voice is Qwen realtime ASR, biased by what's on screen. Agent state detection runs entirely client side, with nothing installed on the remote machine.

Free and open source, Apache-2.0. Mac is available today. The iPhone and iPad app is in App Store review.

If you also juggle several agents in tmux, give it a try and tell me what breaks: bentoai.dev/term
```

标签：#AIAgents #DeveloperTools #OpenSource #BuildInPublic ｜ 题图：linkedin-cover.png

---

## X thread（6 条，首条配视频/题图）

```
1/ I run several Claude Code sessions side by side in tmux. They each run 30-40 min autonomously now. Watching one is a waste of me, so the real problem became: how do I keep track of all of them?

2/ I couldn't find a terminal built for this, so I made one. Bento Term: every agent gets a pane, tinted by state. Blue = working, amber = waiting for me, green = done. One glance tells me who needs attention.

3/ It started as a phone/iPad tmux client to replace iTerm2 — split panes + voice input so I could work while looking after my kid. Then I noticed I was getting more done on the iPad than at my 27" monitor.

4/ The reason is voice. Directing agents barely needs typing. Speaking is ~3x faster, and recognition is biased by on-screen text, so file names and identifiers come out right. Mixed Chinese/English works too.

5/ Under the hood: native Swift, libghostty rendering (Ghostty's engine), real tmux control mode (-CC) as the single source of truth. State detection is client-side. Nothing installed on your remote machine.

6/ Free and open source, Apache-2.0. Mac today, iPhone/iPad in App Store review. If you also juggle agents in tmux: bentoai.dev/term
```

---

## YouTube（landscape-en）

**标题**：`Bento Term — a terminal for watching and talking to your AI agents`

**描述**：

```
Parallel, voice, remote — one way of working.

Run a group of agents side by side on one screen. Direct them by talking instead of typing. And because everything lives in real tmux over SSH, the same session follows you from the Mac to iPhone and iPad.

Free & open source (Apache-2.0) · macOS 14+ · iPhone & iPad coming to the App Store
Website: https://bentoai.dev/term/
GitHub: https://github.com/NovaShang/BentoTerm
```

设为 **Public**（PH gallery 内嵌需要）。

## Bilibili（landscape-zh）

**标题**：`并行、语音、远程：我给 agent 时代做了个终端`
**简介**：`同时开一群 Claude Code，动口不动手地指挥，人走到哪工作跟到哪。免费开源，官网 bentoai.dev`
分区：科技 → 软件应用

## 微信视频号（portrait-zh）

`同时开一群 agent、说话指挥、走到哪接到哪——这是一种工作方式。免费开源，bentoai.dev`

## 抖音（portrait-zh）

同视频号文案 + 话题：#程序员 #AI编程 #开发者工具

## TikTok（portrait-en）

`Run agents in parallel. Direct them by voice. Take the work anywhere. Free & open source → bentoai.dev`
Tags: #coding #aitools #developer

---

## 即刻

```
给自己做的终端 Bento Term 今天正式发出来了。起因是想抱娃的时候也能盯着家里跑的一堆 Claude Code，就做了个带语音输入的 tmux 客户端——结果发现 iPad 上干活比 27 寸显示器还快。每个 agent 一个格子，颜色表示状态，扫一眼就知道该管谁，回答用说的。免费开源，Mac 版可用，iOS 在审。bentoai.dev/term
```

## V2EX 分享创造

**标题**：`做了一个跑多个 Claude Code 的终端，开源`

```
平时习惯在 tmux 里同时开好几个 Claude Code。agent 现在一跑就是半小时，盯着浪费时间，不盯又不知道它啥时候停下来问话。一开始只是想做个 iPhone/iPad 上的 tmux 客户端代替 iTerm2（要分屏和语音输入，抱娃的时候也能干活），用着用着发现 iPad 上效率比 27 寸显示器还高，就把 Mac 版也做了，现在是日常主力。

每个 agent 一个格子，按状态着色（干活/等回话/已完成），语音带屏幕上下文偏置，文件名和代码标识符认得对，中英混说可以。底层是真 tmux（-CC 控制模式），渲染用 libghostty，远端机器有 sshd 和 tmux 就行，不装任何东西。

免费开源 Apache-2.0：bentoai.dev/term ，GitHub：github.com/NovaShang/BentoTerm 。求拍砖，特别是 tmux 重度配置用户。
```

---

## 知乎专栏

**标题**：`我给自己做了个终端，用了三个月，感觉回不去了`

```
先交代背景：我平时写代码重度依赖 tmux，习惯是一个 session 里同时开好几个 Claude Code，一个格子干一件事。这个习惯本身没什么特别的，估计不少人都这么干。

麻烦在于现在的 agent 一跑就是半小时起步。你盯着它看吧，纯浪费时间；不盯吧，它啥时候停下来问你话你也不知道，就得隔一会儿切过去瞅一眼，跟上班打卡似的。更烦的是这套东西被拴在书房那台显示器上，我一离开工位就彻底抓瞎。

去年我小孩出生了，抱娃的时间大幅超过坐工位的时间。所以最开始我的需求特别朴素：想要一个 iPhone 和 iPad 上能用的 tmux 客户端，代替 iTerm2，要能分屏，最好能语音输入——这样抱着娃也能干活。市面上找了一圈没有合适的，行吧，程序员的老毛病，自己写。

写完用了一阵，发现一件我自己都没想到的事：我在 iPad 上的效率，比坐在 27 寸显示器前面还高。

想了想主要是语音的功劳。指挥 agent 这个事，本来就不怎么需要打字，你要做的就是"跑一下测试""这个方案可以，继续""diff 发我看看"这种话。说比打快太多了，而且我做了个屏幕上下文的词表偏置，文件名、代码里的类名都能认对，中英文混着说也行——这对中国程序员来说基本是刚需，我们说话就是这样的。

另一半功劳是状态颜色。每个 agent 的格子按状态着色，蓝的在干活，橙的在等我回话，绿的是干完了我还没看。不用挨个巡逻，扫一眼就知道该理谁。

后来干脆把 Mac 版也做了，现在是我的日常主力终端。周围几个朋友也在用，反馈都差不多：一旦习惯了同时开一群 agent、看颜色、动嘴不动手，就回不去了。

技术上几个选型，感兴趣的可以看看：

- 渲染直接用 libghostty，就是 Ghostty 那个 GPU 引擎，没自己造终端模拟器的轮子
- 底下是真 tmux，走 -CC 控制模式，app 不自己存状态。所以你从任何别的终端 attach，看到的布局跟 app 里一模一样。这个协议的坑比我想象的多得多，够单独写一篇了
- 语音用的 Qwen 的实时识别
- agent 状态检测全在客户端，靠 pane 输出和标题做规则匹配，不往 shell 里注入任何东西，远端机器也不用装东西，有 sshd 和 tmux 就行

叫 Bento Term，便当盒的意思，一格一个 agent。免费，开源（Apache-2.0），Mac 版可以直接用，iOS 版还在 App Store 审核。地址：bentoai.dev/term

如果你也有一堆 agent 要伺候，可以试试。哪里用着别扭，issue 或者评论区骂我都行。
```

**回答策略**：搜「同时运行多个 Claude Code / AI agent」「Mac 终端推荐」「tmux GUI 客户端」「iPad 写代码/生产力」类问题，挑高关注低质量回答的进；先经验后产品，链接放最后一段。
