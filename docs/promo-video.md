# Bento Term 宣传视频

> v2 · 2026-08-13 · 主片约 60 秒，16:9。**整篇 VO 已合成锁定**（`film/audio/vo/full.mp3`，55.7s），
> 分镜与素材都对齐这条音轨剪。
> 文案纪律沿用落地页：不编数字（全片唯一的数字是可验证的 3×）、不用形容词吹、
> **不做假 UI**——生成镜头只给氛围（屏幕内容不可读、无 logo），可读的 UI 必须是真录屏。

---

## 0. 定调（不再变的部分）

**给谁看。**已经在跑 Claude Code / Codex 的开发者，从 X / HN 刷到。他们对"AI 改变一切"式宣传免疫，对**能看出是真的**的画面没有免疫力。说服力全押在真录屏上，VO 只负责把画面串成论证。

**讲什么。**核心论证：**agent 单次自主运行越来越长——四十分钟、一小时。盯着一个跑，被浪费的是你；所以开八个，问题变成同时跟住八个长跑的工人。**（⛔ 反向框架"agents 快人慢"已被否，不许回潮。）叙事顺序：并行（一变多→便当盒→颜色提醒）→ 语音（3×→操作 shell→指挥 agents→识别代码名）→ 远程（⌘Q→iPad→iPhone）→ 收束"一种工作方式"。

**冷开场用问题。**"一个 agent 深跑、你无事可做"是目标观众每天经历的画面，半秒认出自己，再给解法。开场两句反问**有 VO**（拍板：不省）。

**VO 的做法。**MiniMax speech-02-hd，音色 `English_magnetic_voiced_man`，**整篇一次请求合成**——分句合成会有十几次语气冷启动，整篇合成让模型在完整上下文里把握起伏；气口用 `<#x#>` 停顿标记控制（句间 0.6s、章节间 1.0s）。语体规则：合成音是平读者，只写陈述句说明文，戏剧性交给字卡和音乐。

---

## 1. 分镜（对齐 full.mp3 实测落点）

音轨各句落点用 silencedetect 实测。成片 = 音轨前垫约 1s 起播 + 尾板延长约 5s，共约 62s。

| 音轨时间 | VO | 画面 |
|---|---|---|
| 0–4.9 | Your agent is working. So what are you doing? | 满屏单 agent 深跑（Focus 全屏），无人操作，字卡压两句 |
| 4.9–6.9 | You could be running more of them. | **全片枢纽**：说到 "more" 时一变多。全片只用一条网格全屏素材：冷开场是后期**裁切放大中间格上部**，此刻数码拉远露出全网格（app 内 zoom/切模式动画不流畅，已否） |
| 6.9–12.2 | In Bento Term, all of your agents run in one window, like a bento box. | 转场落定后**摆便当盒**：拖一格到投放区归位 + 拽分隔线调匀——布局编辑的展示放这句，因为它就是比喻的字面演绎；镜头收在标准布局（与前后镜头连续） |
| 12.2–17.1 | You watch every one of them at once, instead of switching from task to task. | 全景继续静止——"不切换"用什么都不发生来演 |
| 17.1–20.7 | When one needs your attention, its color tells you. | 一格转琥珀（正好落在 "color"）→ 点进 → 按 1 → 转蓝 |
| 20.7–26.5 | Talking is about three times faster than typing. So voice is the main way you give input. | 按住右键，罗盘展开，波形跳动，镜头推近 |
| 26.5–31.9 | You can drive the shell by voice. More importantly, you can direct your agents. | 两拍：对空 shell 格说命令→执行；"More importantly" 切 agent 格说指令 |
| 31.9–38.4 | Bento hears the context, so technical terms, even names from your code, come out right. | 转写特写：中英混说句里 `BentoSessionKit`、`TerminalViewModel` 一字不差，名字就在屏幕输出里 |
| 38.4–41.5 | Your agents don’t stop when you leave the desk. | 网格还在跑 → 直接接 G1 合盖入黑（⌘Q 那拍已砍——拍板：没必要） |
| 41.5–44.9 | On the sofa, the iPad gives you the whole setup. | G2 沙发氛围 → 真 iPad 录屏：同一网格，进度更靠后 |
| 44.9–48.4 | On the road, your phone can finish anything. | G3 旅途氛围 → 真 iPhone 竖屏：列表→琥珀→点进→答掉 |
| 48.4–55.7 | Parallel, voice, remote. It’s one way of working. And the gains multiply. | 入黑，三词逐个出现（各点章节状态色）→ 合成一行 → 尾板：图标 + H1 + `brew install` + 域名 |

台词唯一真理源是 `film/timeline.js` 的 `vo` 表（`--full` 就从那里读）。已知瑕疵：该音色把 "parallel" 读得不准，已接受；终版若介意再用发音改写硬修。

---

## 2. 素材清单（同一天、同一个 desk 会话，按顺序 T1–T6）

> 素材单位是 **take**：顺序录完，iPad/iPhone 上出现的就是刚在 Mac 上看过的那几格、
> 且进度更靠后——"同一个会话"的说服力自动成立。时长预算 = 音轨章节实测 × 2 余量。

| Take | 覆盖音轨 | 内容 | 录多长 |
|---|---|---|---|
| **T1** Mac | 0–17.1s | Parallel 网格全屏静置录到底，**零操作零按键**；中间 bento-term 格保持满屏滚动的深跑（冷开场的特写就裁它） | ≥35s |
| **T2** Mac | 17.1–20.7s | 网格静置 → 琥珀出现（Claude 定时触发）→ 两拍 → 点进 → 按 1 → 转蓝 → 静 5s | ≥25s |
| **T2b** Mac | 6.9–12.2s | 布局编辑：Claude 先把 warloom 挪乱 → 镜头里拖回右下投放区 + 拽分隔线调匀 → 收在标准布局 | ≥20s |
| **T3** Mac 🎙 | 20.7–38.4s | ①空 shell 格（planner 格按 q 退 TUI）说 "git status"→执行；②agent 格说「跑一下 BentoSessionKit 的 tests，然后把 TerminalViewModel 的 diff 发我看一下，别 commit」→agent 开动。麦克风开 | ≥45s |
| ~~T4~~ | 38.4–41.5s | ⌘Q 拍已砍，该句画面 = 网格素材 + G1 合盖 | — |
| **T5** iPad | 41.5–44.9s | 横屏，desk 会话网格全景，静置为主 | ≥15s |
| **T6** iPhone | 44.9–48.4s | 竖屏：列表 → 琥珀出现（定时触发）→ 点进 → 答掉 → 回列表 | ≥30s |

（2026-08-13 实录后放宽：Mac 与 iPad/iPhone 素材内容**不要求对上**——同会话连续性有则更好，不作硬要求。实录成品放 `film/assets/clips-v2/`。）

生成镜头（已有，Hailuo 03 / 2K）：G1 合盖（取 3.2s 起的合盖后半段）、G2 沙发、G3 旅途。
收尾纯字卡，无素材。

**录制规格**：Mac 用 ⇧⌘5 录整屏（存 `~/Desktop/bentoterm-clips`，T3 开麦克风），勿扰、桌面清空、Dock 自动隐藏、深色外观、app 真全屏；iPad/iPhone 控制中心录屏，完录 AirDrop 进同一目录。

**流程协议**：每条 take 开录前在聊天里说「准备 T几」——Claude 把各格任务点火、布置琥珀延时（给 assistant 格发一条会弹确认框的指令，约开录后 20s 出现），回 GO 再录。

**舞台现状（2026-08-13 已搭好）**：`desk` 会话五格三列——左 planner 日程 TUI（`~/code/planner`，自带 venv + git 仓库）+ assistant，中 bento-term 大格，右 smartsld + warloom；四个 claude 以 `--permission-mode manual --strict-mcp-config --mcp-config '{"mcpServers":{}}'` 待命，pane 标题已去主机名，claude-code 已升级去横幅。⚠️ `~/code/personal-assistant` 的真实数据永不入镜，planner 是消毒副本。

---

## 3. 规格与声音

- 主片 2560×1440（或 4K），**60fps**（UI 滚动 30fps 会糊）；录屏源统一 2× 屏。
- 声音链：full.mp3 整条铺底（画面追声音，不反过来）+ 音乐对 VO sidechain 闪避 + 少量真实 SFX（键盘声、发送轻响，不加 whoosh）。T3 的真人中英混说要不要透出来，剪辑时听着定。
- 衍生：30 秒剪（冷开场 + 每章一镜 + 尾板）、9:16 竖版（T6 + 文字板）——都从主时间线抽，不单独写稿。

---

## 4. 未决

1. **成片装配方案。**web 舞台实时演一遍再录屏的方案已失信任；备选是素材齐后用 ffmpeg 对着 full.mp3 直切。素材录完再定，分镜与音轨不受影响。
2. **音乐。**你来选（Claude 不代选版权素材）；唯一一次情绪抬升放在 48.4s 三词收束处，冷开场刻意无音乐。
3. "parallel" 发音（见 §1，已接受，可再修）。

---

## 5. 工具与已踩的坑（维护备忘）

- `film/timeline.js` 镜头表+台词表（真理源）；`index.html` 动画稿预览台（按空格播，`?t=秒` 定点调试）；**预览必须用 `node film/serve.mjs`（:8899）**——`python3 -m http.server` 不支持 HTTP Range，视频一 seek 就永久卡死。
- `gen-vo.mjs`：`--full <voice>` 整篇一次合成；`--voices` / `--sample` 选音色。
- `gen-video.mjs`：模型 **MiniMax-H3**（2026-07-31 发布），提交走 v2（content 数组、ratio 必填、2K），**轮询必须走 v1** ——v2 的 query 无视 task_id，只回账号最新任务（曾致两镜头字节级相同）。
- MiniMax key 在 `../voltreality-keynote/.env.local`，运行时引用，**不复制不打印**。
- Playwright `recordVideo`（~25fps 尽力截流）已否决；如仍走录屏路线，用 macOS `screencapture -v`。
