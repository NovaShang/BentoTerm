# Bento Mac 客户端 · 产品设计文档 (v0.2)

> **⚠ 2026-07 结构变更 — 本文尚未整体重写。** macOS app **不再是菜单栏 app**:NSStatusItem、菜单栏图标与那个下拉菜单已整体删除。它现在是一个普通 Mac app —— Dock 图标、常规主菜单、常规窗口生命周期(关掉最后一个窗口 app 仍留在 Dock,点 Dock 图标或 ⌘N 重开一个)。relay / 配对整套功能将在后续阶段整体删除,过渡期内原本挂在下拉菜单里的配对入口**刻意保持不可达**。
> 因此下文凡以"菜单栏"为前提的内容都已过时:§3.1(整节)与§五(整节)已标注 superseded,§一、§二、§六~§十一 中的零星提法已就地更正。这两节需要作者做一次真正的重写,不是改几个词能修好的。

> 第二次整理。相较 v0.1 的**重大事实更新**(把文档对齐到已经落地的代码):
> - **v0.1 说"不做 Mac 端自己渲染终端"** → ✅ **已废弃**。Mac 已落地**原生 libghostty 平铺终端**(iTerm2 式 tmux 分屏:标题栏、zoom、拖拽分隔、Shell 菜单/快捷键)。
> - **relay 从"Go VPS + SSH 反向隧道"** → ✅ 实际是 **Cloudflare Workers + Durable Objects** 的 WSS 字节泵。
> - **账号体系从 OIDC(Nova Auth)** → ✅ 实际是**纯设备配对(6 位码 + Ed25519 TOFU)**,**MVP 无账号、无 OIDC**(见 [[project_no_oidc_in_mvp]])。
> - ~~**定位:菜单栏与原生终端"两者并列"**(co-equal),不是"菜单栏为主、终端为辅"。~~ → **已作废**(见顶部结构变更):菜单栏那一半不存在了,原生终端窗口是唯一界面。
> - **原生终端仅连本机**(local pty + `tmux -CC`);远程远控是 iOS 的职责,走 relay。
> - **多 pane/会话导航 = Tiles + 窗口/标签**,不做手机式 List。
>
> 与 iOS `prd.md` (v0.3) 的关系:**复用其核心概念**(Host/Session/Window/Pane、那堵墙、三状态机、handoff、page/viewport),但针对 Mac 的鼠标/键盘/可自由缩放窗口/多窗口重新落地交互。冲突处以本版为准。

---

## 一、产品定位

**一句话:** Bento Mac 是 vibe coder 在**本机**并行指挥多个 coding agent 的控制平面 + 原生终端。原生 Bento 终端用 iTerm2 式平铺直接管理并操作本机 tmux 会话/agent;同一套 tmux 状态通过 Cloudflare relay 暴露给 iOS,出门用手机零配置续上。

**核心承诺:**

1. **原生平铺终端**:基于 libghostty 的 GPU 终端,`tmux -CC` 控制模式 1:1 镜像 tmux 布局,平铺多 pane、拖拽分隔、zoom、每 pane 标题栏 —— 不依赖系统 Terminal/iTerm2。
2. **会话总览**:实时看到所有 tmux session / window / pane,点击直接在原生终端打开(或回退系统终端)。**TODO**:原来这块挂在菜单栏下拉里,菜单栏删掉后它落在哪个界面(主菜单项?窗口内侧栏?)尚未决定。
3. **Agent prep wizard**:选目录 → 选 agent(Claude Code / Codex / OpenCode…)→ 选布局 → 一键开好 tmux + 各自起 agent。
4. **零配置远程接入(给 iOS)**:Mac 跑 `bento-daemon`,扫码配对,iOS 端凭配对即可经 relay 远控**同一套本地 tmux**,无需懂端口转发/VPN。

**界面(2026-07 起只剩一个):**

| 界面 | 作用域 | 何时用 |
|---|---|---|
| **原生 Bento 终端**(libghostty 窗口) | 单个 tmux window 的平铺操作 | 实际敲命令、看 agent、调布局 |
| ~~**菜单栏控制面板**(`Bento.app` NSStatusItem)~~ | ~~全局:daemon 状态、会话清单、配对、wizard、设置~~ | **已删除**,见顶部结构变更 |

窗口沿用普通 Mac app 生命周期:关掉最后一个窗口 app 仍在 Dock 里,点 Dock 图标或 ⌘N 重开。原来只在下拉菜单里的全局能力(daemon 状态、会话清单、设置、wizard 入口)**TODO**:落点未定。

**目标用户:**

| 画像 | 现状 | Bento Mac 解法 |
|---|---|---|
| **A. Power user**(会 tmux/SSH) | iOS 单独够用 | 原生终端比 iTerm2+tmux 省配置;daemon 让手机能远控 |
| **B. Vibe coder 新手**(会 Claude Code GUI、不懂 tmux/网络) | 只会一个个开窗口 | **wizard + 原生终端是主入口** |
| **C. Headless dev**(云 GPU 跑 agent) | SSH 进去手动 tmux | 装 daemon + CLI,从 Mac/iOS 远控 |

**与竞品差异:**

| 维度 | iTerm2 + tmux | Warp | Cursor | **Bento Mac** |
|---|---|---|---|---|
| 终端会话持久化 | ✓(要会 tmux) | 部分 | ✗ | ✓(零配置) |
| 图形化平铺 pane | tmux -CC(仅 iTerm2) | ✓ | ✗ | ✓(原生 libghostty) |
| Agent prep wizard | ✗ | ✗ | ✗ | **独家** |
| 多 agent 并行调度视图 | ✗ | 弱 | 弱 | **独家** |
| 远程移动续控(同一 tmux) | ✗ | ✗ | ✗ | **独家(iOS 经 relay)** |

---

## 二、核心概念模型(复用 iOS,标注 Mac 差异)

### 2.1 术语(与 iOS `prd.md` §2.1 一致)

- **Host**:一台机器。Mac 客户端的 host **永远是本机**(localhost,local pty)。
- **Session / Window / Pane**:对应 tmux 的 session / window / pane,语义同 iOS。
- **Page**:当前显示内容,**尺寸唯一事实来自 tmux**。原生终端里 page = 当前 window 的整套 pane 布局。
- **Viewport**:屏幕可见区。**Mac 差异:viewport = 可自由缩放的 NSWindow 内容区**(不像 iOS 是固定设备尺寸)。

### 2.2 那堵墙(硬约束,与 iOS §2.3 相同)

**一个 tmux window 的几何被所有 client 共享。** 一个 PTY 跑的 TUI 只渲染到一个 cols×rows。所以:

- Mac 原生终端 = 本地 tmux 的一个 client;iOS 经 relay attach 同一 session = 另一个 client。
- 两个 client **不能同屏看同一 window 的不同尺寸** → 采用 **handoff**(§7)。

### 2.3 Mac 的 page/viewport:窗口即 page(默认跟随活动设备)

iOS 因设备尺寸固定 + 键盘弹出,引入了尺寸权威(prd.md 2.5)。**Mac 默认最简单的那一档:原生终端窗口可自由缩放,窗口尺寸直接驱动 tmux client 尺寸。** 三种策略在 Mac 上同样可选(Session Size 菜单),因为策略是会话级的服务器状态,不是设备偏好——iPad 上选的东西 Mac 必须能看见、能接管。

| 关系 | Mac 行为 |
|---|---|
| 改变窗口大小 | 防抖后 resize tmux client(`refresh-client -C`);**这是 Mac 唯一常规 resize 触发**,与 iOS 的严格白名单等价但更简单 |
| 改字号(Settings) | 改 page 像素尺寸 → 触发一次 resize |
| pane 平铺 | 每个 surface 按其 tmux cell 几何**精确**定尺(+1 cell 防 ghostty 少算一列,溢出裁剪),保证 TUI 不串行 |

> **被 iOS 接管时**:iPad 选了"以此设备为准"后,Mac 这边窗口若仍打开,就处于被动尺寸——菜单里显示"由 Shang iPad Air 设定",一次点击即可接管回来;iPad 离开(`%client-detached`)时归属自动释放。

### 2.4 多 pane / 多会话导航:Tiles + 窗口/标签(决策:不做 List)

- **Tiles(平铺)**:原生终端窗口里,当前 tmux window 的所有 pane 按真实布局 1:1 平铺。这是 Mac 的**唯一**多 pane 视图(大屏 + 鼠标天然适合空间布局;手机式 List 的扁平心智在 Mac 不需要)。
- **窗口切换**:一个 tmux session 的多个 window → 原生终端的**标签(tab)**或 ⌘1..9 / Shell 菜单切换(**目标态**,见 §9 待补)。
- **多 NSWindow**:⌘T 可开多个原生终端窗口(可 attach 不同 session)。
- **会话总览**:列出所有 session/window,点击在原生终端打开。**TODO**:菜单栏下拉删除后,这个总览的落点未定。

### 2.5 三状态机(复用 iOS §2.8)

每个 pane:**Working / Idle / Awaiting Input**,检测逻辑在 `bento-terminal-core` 共享(Hook→Title→输出正则→silence→兜底)。Mac 用途:

- 原生终端**每 pane 标题栏的状态点**(琥珀 = Awaiting)
- 会话清单的状态指示(落点同上,TODO)
- (未来)Mac 通知中心提醒"X 个 pane 等待输入"

---

## 三、界面

### 3.1 菜单栏控制面板(`Bento.app`)— ⛔ SUPERSEDED(2026-07)

> **整节作废。** 状态项、菜单栏图标与这个下拉菜单已删除;取代它的是普通 Mac app 形态(Dock 图标 + 常规主菜单 + 常规窗口生命周期)。下拉里的每一项(状态头、daemon ID、配对、wizard、会话清单、设置)现在**没有入口**;relay/配对整套即将删除,其余项的新落点未定。**本节需要作者重写,不是改词能修的。** 以下内容仅作历史参考:

`MenuBarExtra` 下拉(`MenuContent.swift`):

```
[● Connected · N devices]            (状态头,relay 在线/离线)
 daemon ab12cd34…                    (daemon ID)
 ───
 Pair new iPhone…                    → 配对窗口(QR + 6 位码)
 New agent session…                  → Agent wizard
 New terminal (Ghostty)…   ⌘T        → 开原生 Bento 终端
 Paired devices…                     → 设备管理
 ── Sessions · 点击打开 ──
   ▸ work-1 · 2m   👁                 → 子菜单:windows(pane 数/活跃点)+ 重命名/kill
   ▸ agent-3 · just now
 ───
 Settings… / Refresh / Quit
```

- 后台 5s 轮询刷新 session/window 清单(轮询在 `AppDelegate`,不在菜单视图里——菜单关闭时也要刷新)。
- daemon 随 app 启动而起,退出时 SIGTERM。

### 3.2 原生 Bento 终端(libghostty,已实现)

- **引擎**:libghostty(GhosttyKit C API,Metal GPU 渲染),`bento-terminal-core` 自写 surface(iOS/Mac 共用同一套 VM + tmux 控制模式)。
- **传输**:**本地 pty** + `tmux -CC`(决策:仅本地)。
- **平铺**:`GhosttyTiledPaneHost` 按 tmux cell 几何比例平铺;每个 pane 一个 `GhosttyTerminalSurface`;surface 精确定尺(cell-exact + 1 cell 防少列)。
- **已落地交互**:见 §4。

---

## 四、原生终端交互(Mac:鼠标 / 键盘 / 菜单)

### 4.1 平铺与聚焦

| 操作 | 行为 | 状态 |
|---|---|---|
| 点击某 pane | 设为 active(`select-pane`,高亮描边 + 标题栏激活) | ✅ 已实现 |
| 标题栏 ⛶ 最大化 / Shell 菜单 Toggle Zoom(⌘⇧↩) | tmux zoom:该 pane 占满 window,其它隐藏;再点还原 | ✅ 已实现 |
| 标题栏 ⋯ 菜单 | 该 pane:Split V/H、Zoom、Close | ✅ 已实现 |
| 拖拽 pane 间分隔 | 图形化调整 tmux 布局(`resize-pane`),拖动时绿色实时反馈线 | ✅ 已实现 |
| 窗口缩放 | 防抖 resize tmux client | ✅ 已实现 |

### 4.2 分屏 / 关闭 / 导航(Shell 菜单 + 快捷键,已实现)

通过 SwiftUI `.commands` 的 **Shell 菜单**(声明在主菜单里,经响应链 `BentoPaneAction` 派发到聚焦的 host):

| 菜单项 | 快捷键 | 行为 |
|---|---|---|
| New Terminal Window | ⌘T | 新开原生终端窗口 |
| Split Vertically | ⌘D | 左右分屏(`split-window -h`) |
| Split Horizontally | ⌘⇧D | 上下分屏(`split-window -v`) |
| Select Next / Previous Pane | ⌘] / ⌘[ | 切 active pane |
| Toggle Zoom | ⌘⇧↩ | 聚焦/还原 |
| Close Pane | ⌘W | 关闭 pane |

### 4.3 每 pane 标题栏(已实现,对应 iOS §3.5)

`[● 状态点] [pane 标题/命令………] [⛶] [⋯]`,背景与终端背景融合;非活跃 pane 弱化、隐藏右侧按钮。

### 4.4 键盘 / 文本输入

- 键盘事件全部经 `ghostty_surface_key`(由引擎编码:可打印字符走 text,回车/方向/功能键走转义序列,Ctrl 组合走控制字节),特殊键不再回显成私用区字形。
- **文本选择 / 复制粘贴**:目标态走系统级(⌘C/⌘V + 鼠标选区);MVP 现状见 §9 待补。

### 4.4b 语音输入(Mac 原生终端)— 已纳入范围(原"不做"决策已废弃)

- **触发手势**:在某个 pane 上**右键按住**(≥250ms)→ 选中该 pane 并进入"按住说话";与 iOS 的"按住录音"手势对应("右键位置 = 录音目标")。快速右键仍是原行为(Copy/Paste 菜单 / 鼠标上报转发)。
- **方向罗盘**(与 iOS 一致):按住时拖动方向决定动作 —— ↑ 插入并回车 · ↓ 取消 · ←/→ 用 LLM 把自然语言转成 shell 命令(→ 还自动回车)· 居中松开 = 仅插入。屏幕上浮出 transcript + 罗盘 overlay。
- **引擎 / 设置与 iOS 共享**:`bento-terminal-core` 内 `VoiceSession` + `AppleSpeechEngine`/`OpenAIRealtimeASRService`/`AudioCaptureService`/`LLMService` + `TerminalViewModel.handleVoiceResult` 两端共用;设置项(`speech_engine`/`speech_locale`/`openai_api_key`/`llm_*`)同键。Mac app 走 `AVCaptureDevice` 麦克风权限(非沙盒),Info.plist 带 Mic/Speech usage。
- 默认引擎 = Apple 端上识别(无需 key);OpenAI Realtime 走内置 relay(可填 BYOK)。

### 4.5 不做(Mac 原生终端)

- **List 视图**:不做(决策 §2.4)。
- **画布缩放 / 双指平移**:Mac 用窗口缩放代替,不引入 iOS 的手势模型。

---

## 五、菜单栏 + Agent Wizard — ⛔ SUPERSEDED(2026-07)

> **整节的前提(wizard 与配对/设备/设置都从菜单栏下拉进入)已不成立**:菜单栏没了,这些窗口目前**没有入口**;配对/设备管理属于即将整体删除的 relay 功能集,过渡期内刻意保持不可达。wizard 与设置本身仍要保留,但从哪里打开(主菜单?欢迎窗口?)未定。**本节需要作者重写。** 以下内容仅作历史参考:

### 5.1 Agent prep wizard(已实现,落点需调整)

`AgentWizardWindow.swift` 让用户配置:

- **session 名**、**工作目录**(NSOpenPanel)、**agent preset**(Claude Code / OpenCode / Codex / OpenClaw / Hermes / Antigravity / 纯 shell / 自定义命令)、**布局**(Solo / 左右 / 上下 / 三列 / 主+栈 / 2×2)。
- "启动" → `TmuxCLI.buildAgentScript` 生成 `tmux new-session / split-window / select-layout / attach` 脚本。

**目标态决策(与 v0.1 不同):wizard 应默认启动到原生 Bento 终端**(`BentoTerminalWindow`),而非系统 Terminal/iTerm2。
**现状(待补)**:wizard 当前 shell 到 `TerminalAppKind.preferred`(系统 Terminal/iTerm2/Ghostty/Warp),**还没接到原生终端**。见 §9。

### 5.2 设备管理 / 配对 / 设置(已实现)

- **配对窗口**:QR(`bento://pair?d=<daemonID>&c=<code>`)+ daemon ID + 6 位码(60s TTL,自动刷新);调 `bento pair`。
- **设备窗口**:列出已配对 iOS 设备(label / device-id),可 revoke。
- **设置**:开机自启(`SMAppService`)、"tmux 会话用哪个终端打开"(目标态应含"Bento 原生")、relay URL。

---

## 六、连接架构(已实现,事实更新)

### 6.1 三段式

```
   Mac 本机                         Cloudflare Relay                    iOS
┌──────────────┐   WSS(Ed25519     ┌───────────────────┐   WSS(设备   ┌─────────┐
│ bento-daemon │   host-key 挑战)   │  Worker + DaemonDO │   key 挑战)   │ Bento   │
│  • SSH server│◀═════════════════▶│  • 每 daemon 一个 DO │◀════════════▶│  iOS    │
│  • relay 客户端│   二进制帧字节泵     │  • 配对槽/限流       │              └─────────┘
│  • IPC socket │                   │  • ASR token mint   │
│  • tmux(本机)│                   └───────────────────┘
└──────┬───────┘
       │ Unix socket (~/.bento/daemon.sock)
   ┌───▼────┐   ┌──────────────┐
   │ bento  │   │  Bento.app   │
   │  CLI   │   │  Mac app     │
   └────────┘   └──────────────┘
```

### 6.2 daemon(Go,已实现)

- 启动:读 `~/.bento/config.json`(relay_url + daemon_id)、生成/读 Ed25519 host key、读 `authorized_keys`(每设备一行)、起内嵌 **SSH server** + **relay WSS 客户端** + **IPC unix socket**;写 pidfile;掉线指数退避重连。
- **SSH server**:Ed25519 公钥认证(匹配 paired 设备),仅 `session` channel,支持 pty-req / env / shell / window-change。
- **CLI(`bento`)**:`tunnel start/stop/status`、`status`、`pair`、`devices [revoke]`、`doctor`、`version`。**无 login/账号**。
- **状态文件**:`~/.bento/{config.json, ssh_host_ed25519_key, authorized_keys, daemon.pid, daemon.sock, daemon.log}`,权限 0600/0700。

### 6.3 relay(Cloudflare Workers,已实现)

- **Worker 路由**:`POST /v1/daemon/register`、`GET /v1/daemon/socket`(daemon 侧 WSS)、`POST /v1/pair`(iOS 提交码+设备公钥)、`GET /v1/tunnel`(iOS 侧 WSS)、`POST /v1/asr/mint`(铸 OpenAI Realtime 临时 token)、`GET /healthz`。
- **DaemonDO**(每 daemon 一个 Durable Object):持配对槽、TOFU 钉住的 host key / device key、暴力破解锁(5 次错码 → 60s)、stream 多路复用 ID。**只转发字节,不看 SSH 内容**。
- **认证模型**:**纯配对**。daemon 侧 Ed25519 host-key 挑战(TOFU);iOS 侧 6 位码配对 + Ed25519 device-key 挑战(TOFU)。**无账号、无 OIDC**。
- **限流**:RL_REGISTER 30/min、RL_PAIR 60/min、RL_MINT 20/min(每 IP)。
- **ASR**:`OPENAI_API_KEY` 作 Worker secret;为 iOS 语音铸临时 client_secret(~1min);Phase 2 再加 device-key 签名鉴权。

### 6.4 配对流程(已实现)

1. `bento pair`(GUI 入口原在菜单栏,现已无入口)→ daemon 经 relay 开 60s 配对窗口,得 6 位码。
2. iOS 扫码或手输码 + 上传 device 公钥 → relay 校验码/限流 → 转发给 daemon。
3. daemon 落 device 公钥到 `authorized_keys`,ACK 回 host fingerprint + daemon label。
4. 之后 iOS 经 `GET /v1/tunnel` 用 device key 挑战连入,daemon 起 SSH session。

---

## 七、与 iOS 的关系:同一套 tmux + handoff

- **同源**:iOS 远控的目标 = Mac **本机的同一套 tmux 会话**(Mac 原生终端看到的就是 iOS 看到的)。
- **handoff(对应 iOS §2.7)**:同一 session 同时被 Mac 原生终端 + iOS attach 时,后接入者 `attach -d` 顶掉前者的几何(进程不中断)。任意时刻一个 active client → 尺寸唯一 → 无冲突。
- **关键设计决策(目标态)**:**daemon 的 SSH session 应把 iOS attach 到本机 `tmux -CC`**,而不是裸 `$SHELL`,这样 iOS 与 Mac 原生终端完全共享 tmux 状态。
  **现状(待补,§9)**:daemon SSH server 当前直接 spawn `$SHELL`,**尚未接 tmux -CC**——这是闭合"iOS 远控本机 tmux"叙事的最关键缺口。

---

## 八、视觉 / 字体 / 配色

- **终端内**:复用内置主题(MVP 占位 xterm 16 色;`.itermcolors` 导入与 iOS 共享路线)。字体走 `bento-terminal-core` 的 `TerminalTheme`(字号在设置选)。
- **终端外 chrome(主菜单/wizard/窗口)**:遵循 `docs/design.md` 与 [[feedback_no_cli_cosplay]] —— 干净现代 GUI,深色锁定,5 色 icon 调色板,**无 purple**,不在非终端处玩 mono/CLI cosplay。

---

## 九、MVP 范围

### 已完成(对齐现状)

- ✅ `bento-daemon` + `bento` CLI(tunnel/pair/devices/doctor/status)
- ✅ Cloudflare relay(配对、WSS 字节泵、限流、ASR mint)
- ~~✅ 菜单栏:状态 / 会话清单 / 配对(QR+码)/ 设备管理 / 设置 / wizard 入口~~ → **2026-07 已删除**(见 §3.1)。这些窗口的代码大多还在,但没有入口。
- ✅ Agent wizard(目录/agent/布局 → tmux 脚本)
- ✅ **原生 libghostty 平铺终端**:平铺、点击聚焦、⛶ zoom、⋯ 菜单、拖拽分隔(实时反馈)、Shell 菜单 + 快捷键、每 pane 标题栏、三状态点、窗口缩放 resize、cell-exact 防串行
- ✅ tmux 解析器(system tmux ≥3.2 优先,bundled 回退,`BENTO_TMUX` override)

### 待补(关键缺口,需排期)

1. **daemon SSH → `tmux -CC`**:让 iOS 远控接到本机同一套 tmux(现状裸 shell)。**最高优先**——这是 §7 叙事的前提。
2. **wizard 落到原生终端**:wizard "启动" 默认开到 `BentoTerminalWindow`,而非系统 Terminal。设置里加"Bento 原生"为终端选项。
3. **会话清单点击 → 原生终端打开**:`TmuxCLI.attach` 现走系统终端;应支持在原生终端 attach 指定 session/window。(前置 TODO:菜单栏删除后会话清单本身落在哪。)
4. **tmux window 标签**:原生终端窗口内多 window 用 tab / ⌘1..9 切换(现仅多 NSWindow)。
5. **文本选择 / 复制粘贴**:原生 surface 的选区 + ⌘C/⌘V。

### 不做(v1 非目标)

- 手机式 List 视图(决策)
- 原生 Windows(仅 WSL;Windows 原生 tmux 无 control mode)
- 账号 / OIDC(MVP 配对足够;见 Phase 2)
- Agent 输出仪表盘 / token 计费视图
- Mac 自带 agent runtime(用户自装 Claude Code/Codex 等 CLI)

### Phase 2+(候选)

- relay 多区域 + 就近选择 + 优先带宽(付费层);ASR/LLM 额度(见 [[project_monetization_plan]])
- 账号体系(若需跨设备同步配对);device-key 签名的 ASR 鉴权
- Agent 模板市场;multi-Mac 编排;Web UI;自建 P2P 隧道(对大陆降延迟)

---

## 十、Open Questions / 待决策

1. **daemon→tmux -CC 的 attach 语义**:iOS 远控时,daemon 是 attach 到一个固定 session(如 `bento-mac`),还是让 iOS 选 session?建议:iOS 侧用现有 session picker,daemon 按请求 attach 指定 session。
2. **wizard 的"启动"目标**:默认原生终端,但保留"用系统终端"选项?还是彻底切原生?建议默认原生 + 设置可回退。
3. **handoff 提示**:Mac 原生终端被 iOS 顶掉几何时,Mac 这边要不要提示/暂停渲染?建议轻提示横幅,不强制断开。
4. **多 window 标签 vs 多窗口**:tab 优先还是多 NSWindow 优先?建议 tab 为主(贴近 iTerm2 心智),⌘T 仍可多窗口。
5. **发行**:Mac 直接 `.dmg` + notarize + Sparkle(跳过 App Store 审核摩擦)还是上架?建议先 `.dmg`。daemon/CLI 走 Homebrew + `install.sh`。
6. **现有 `.tmux.conf` 冲突**:是否仍提供"一键优化 tmux 配置"(v0.1 设想)?原生终端用 `-CC` 控制模式对用户 conf 依赖更小,可降级为可选项。

---

## 十一、v0.2 决策变更记录

### 对齐现实(覆盖 v0.1)

- ❌ "不做 Mac 端渲染终端" → ✅ **原生 libghostty 平铺终端已落地**(v0.2 时说它与菜单栏"并列";2026-07 菜单栏删除后它是**唯一**界面)
- ❌ relay = Go VPS + SSH 反向隧道 → ✅ **Cloudflare Workers + Durable Objects**(WSS 字节泵)
- ❌ OIDC(Nova Auth)账号 → ✅ **纯设备配对(6 位码 + Ed25519 TOFU),无账号**
- ❌ "继续依赖系统 Terminal/iTerm2" → ✅ 原生终端为主,系统终端为回退

### 新增关键决策

- ~~**两者并列**:菜单栏(控制面板)+ 原生终端(操作面),共享 `bento-terminal-core`~~ → **已作废**(2026-07 菜单栏删除,只剩原生终端)
- **原生终端仅连本机**(local pty + `tmux -CC`);远程是 iOS 经 relay 的职责
- **多 pane = Tiles + 窗口/标签**,不做 List;Mac 默认跟随活动设备(窗口即 page)
- **同一套 tmux**:iOS 远控 = 本机同一 tmux + handoff(需补 daemon→tmux -CC)
- **语音、List、画布手势**一律不做(Mac)

---

## 附录:关键缺口闭合顺序(建议)

| # | 缺口 | 为什么重要 | 估时 |
|---|---|---|---|
| 1 | daemon SSH → `tmux -CC` attach | 闭合"iOS 远控本机 tmux"核心叙事 | 中 |
| 2 | wizard / 会话点击 → 原生终端 | 让"两者并列"真正打通,不再跳系统终端 | 中 |
| 3 | tmux window 标签 | 多 window 在一个原生窗口内可达 | 中 |
| 4 | 文本选择 / 复制粘贴 | 终端基本盘 | 小-中 |
| 5 | handoff 提示 + 设置项完善 | 体验打磨 | 小 |
