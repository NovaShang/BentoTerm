# 移动端 Terminal App · 产品设计文档 (v0.3)

> 第三次整理。相较 v0.2 的**重大架构反转**:
> - **废弃可缩放/可平移的画布(canvas)** → 改为浏览器式的 **page/viewport** 模型(user-scalable = false)
> - **废弃语音/键盘"模式系统"(🎤/⌨️ 切换)** → 改为统一手势,键盘由双击召唤
> - **废弃 grouped session** → 多 client 直接共享同一 window,用 **尺寸权威(2.5)**管理(不强制断联其它 client)
> - **引入 Tiles / List 两种视图**,都能下钻到单 pane focus
> - **快捷键栏简化为浮动 ↑↓↵Esc**,专为响应 agent prompt
>
> v0.2 中与上述冲突的决策一律以本版为准;未冲突的(语音模型、三状态机、连接、配色)继续有效。

---

## 一、产品定位

**一句话:** 一个 iOS/iPadOS 上的 SSH/tmux terminal,为触屏和移动场景重新设计。核心价值是 **让没那么硬核的人也能像大神一样多 agent 并发 vibe coding**——帮你在 Mac/Linux/WSL 上配好 tmux,手机/iPad 随时随地续上,效率不掉。

**三个核心卖点:**

1. **Voice Input(微信式)**:按住 pane 录音,松开前的方向手势决定"发送 / 取消 / 转 shell 命令 / 仅输入"
2. **快速 TUI 响应**:浮动快捷键栏(↑↓↵Esc)让你一指回应 agent 弹出的选择/确认 prompt,不必弹键盘
3. **跨设备续接**:Mac 上一个复杂会话用到一半,iPad 躺沙发续上 / 带手机出门不中断——page/viewport 模型让"换设备"几乎零成本

**目标用户:**

- **接入层(蓝海)**:想多 agent 并发但不会配 tmux/内网穿透的人。我们用桌面 helper + 扫码配对替代 tailscale + tmux 的心智成本。
- **续接层(留存)**:已经会 tmux 的专业用户。卖点是"更无缝"——detach 不杀 session,跨设备 attach 同一 tmux,scrollback 不丢。

**与竞品的差异:**

| 维度 | Blink / Termius | Happy Coder | **本产品** |
|---|---|---|---|
| 通用 SSH terminal | ✓ | ✗ | ✓ |
| 触屏手势优化 | 一般 | N/A | **核心** |
| Voice input | ✗ | 简单版 | **微信式深度集成** |
| tmux control mode | ✗ | ✗ | **独家** |
| 跨设备无缝续接 | 弱 | ✗ | **page/viewport + tmux 持久化** |
| pane 状态自动识别 | ✗ | 仅 agent 特定 | **通用三状态机** |

---

## 二、核心概念模型

### 2.1 术语

- **Host(主机)**:一个远端服务器配置
- **Session(会话)**:对应一个 tmux session,持久存活
- **Window(窗口)**:对应一个 tmux window,内含一组 pane
- **Pane(面板)**:一个终端,跑一个 shell/TUI
- **Page(页面)**:**当前正在显示的内容,其尺寸的唯一事实来自 tmux**
  - Tiles 视图里 page = 整个 window(所有 pane 的布局)
  - List/Focus 里 page = 被聚焦的那个 pane
- **Viewport(视口)**:屏幕上的可见区域(设备内容区,**不含键盘**)

### 2.2 page/viewport 模型(核心,取代旧画布模型)

旧的"可缩放画布"被废弃。原因:终端是**离散网格**,没有"连续缩放下仍可读"的稳定态——用户被迫频繁缩放,每次缩放又触发 SwiftTerm cell 重算 → tmux layout-change → history 重传,形成"高频操作 × 每次昂贵"的负反馈。这是过去大量 bug 和体验差的根因。

新模型像浏览器,但 **user-scalable = false**:

- **Page 尺寸是 tmux 的事实**,不是我们随便缩放的对象
- **Viewport 是 client 的事**,随键盘/旋转/Split View 变化,但**不影响 page**
- **没有捏合缩放**。字号只在 Settings 里选,改字号改的是 page 像素尺寸,不改逻辑 cell 数

**渲染规则(page vs viewport):**

| 关系 | 行为 |
|---|---|
| page < viewport | 左上角对齐,**禁止滚动**,空白区**与终端背景融合**(不是突兀黑色) |
| page == viewport | 锁定,无滚动(绝大多数情况) |
| page > viewport | 提供**双指平移**导航,**低优先级**,不抢单指 scrollback / 长按语音 |

**键盘弹出只改 viewport,不改 page**,且不刻意追踪光标位置。

### 2.3 那堵墙:一个 window 只有一份几何

必须写进 PRD 的硬约束:**一个 tmux window 的几何被所有 client 共享。** 一个 PTY 跑的 TUI(vim/claude)只渲染到一个 cols×rows,绝对定位的 cell 网格**无法 reflow 成两种宽度**。所以做不到"PC 看完整布局、手机同时看适配尺寸"。

这是 PTY/TUI 的物理事实,不是 tmux 的缺陷,**换自建 daemon 也逃不掉**(见附录 A)。我们的所有设计都在这个约束下展开——不试图绕过它,而是用尺寸权威(2.5)+ 两种视图把它变成 feature。

### 2.4 两种视图:Tiles 与 List

都能下钻到单 pane 的全屏 focus,只是入口和交互不同:

**Tiles(平铺,空间视图)**
- 按 tmux 真实布局 1:1 镜像所有 pane,page = window
- 绝大多数时候 viewport == page(严格相等);不等时走 2.2 渲染规则
- 切 pane = `select-pane`(高亮移动,布局不变);tap 某个 pane 可下钻 focus
- 受 **尺寸权威**(见 2.5)约束
- 适合大屏(iPad 横屏 / 桌面)。手机上技术可选,但会是很小的、要平移的网格,**允许但不优化**

**List(列表,扁平视图)**
- 第一层 = pane 列表:状态点 + 名字/当前命令 + 最近活动
- **MVP 不做缩略图**(是否加待定——手机原生 session 的 pane 没有空间关系,列表足够)
- tap 进入 → 该 pane 全屏,**适配当前设备尺寸**(除非别的设备拥有尺寸)
- 适合手机(扁平 agent 集的心智:不是"左/右那个",就是一串 agent)

**默认:** 手机默认 List,iPad/桌面默认 Tiles。**切换控件直接放在顶部栏上**(见 3.8),不藏在菜单里——视图切换是高频动作,值得一个常驻入口。

### 2.5 尺寸权威:三种策略(会话状态,存在服务器上)

**这是一个状态,不是一次操作**,而且**它属于会话,不属于设备**。三种策略各自就是 tmux 自己的 `window-size` 值——我们不发明第二套仲裁,只是把它做成可选、可见、可归属:

| 策略 | `window-size` | 谁定尺寸 | 代价 |
|---|---|---|---|
| **跟随活动设备**(默认) | `latest` | 最后被使用的客户端 | 每次换设备翻一次尺寸 |
| **适配所有设备** | `smallest` | 所有 attach 客户端的最小值 | 大屏被小屏钳住,只有小屏那台能松开 |
| **以此设备为准** | `manual` + `resize-window` | 明确记录的那一台 | 交接是显式动作,不是敲键盘的副作用 |

**为什么必须存在服务器上**:早期版本把它存在每台设备的 `UserDefaults`,并在**每次 attach 时重新写回服务器**——于是两台设备互相覆盖对方的选择(iPad 在重连循环里每 ~50 秒发一次 `window-size latest`,把 Mac 上的钉选悄悄抹掉)。现在:

- 策略的唯一副本 = tmux 的 `window-size`;attach 时**只读不写**(`adoptSizingPolicy`),本地存储降级为读到之前的显示缓存
- 归属写在会话选项 `@bento_size_owner` = `<拥有者的 tmux client name>|<设备标签>`
- **身份用 tmux 的 client name(tty),不自造设备 id**:`list-clients` 天然回答"拥有者还在不在",不需要心跳;`%client-detached` 到达时若正是拥有者,立刻释放回 `latest`——**离开的设备不可能长期扣着会话**
- 拥有者自己重连后 client name 会变,所以它在 attach 时按本地"我曾认领"的记录**重新认领**;别的设备在拥有者不在时才接管

**非拥有者一律不推尺寸**(`manual` 下 tmux 本来就会忽略 `refresh-client`,我们连发都不发);`latest` 和 `smallest` 下**每台都必须持续声明自己的真实网格**,因为那正是 tmux 计算窗口的输入。

### 2.6 resize 触发规则(严格白名单)

**只有**以下事件触发对 tmux 的 resize:

1. Connect —— 按会话上已有的策略(见 2.5;attach 只读策略,不写)
2. 菜单里手动"以此设备为准"/"适配到当前设备"
3. 旋转 —— **非"别的设备拥有"时**
4. Split View / app 窗口尺寸变化 —— **非"别的设备拥有"时**
5. Settings 改字号

**绝不触发** resize 的事件:键盘弹出/收起、滚动、双指平移、切换 pane、任何 UI 覆盖层(语音面板、菜单、设置)。

→ 这把 resize 从"每分钟好几次"降到"每次换设备/旋转一次",一天个位数。配合本地 scrollback 缓存,history 重传几乎不可感知。这是解决旧版核心痛点的关键。

### 2.7 多 client:共享同一 window(不强制断联)

因 2.3 的墙,多 client 同时 attach 同一 tmux window 会共享同一份几何。我们**不强制断联**——接入时只 `attach`,**不** `attach -d` 去踢掉其它 client(如 PC)。冲突由 **尺寸权威(2.5)** 化解,而不是靠断开别人:

- 手机选 **以此设备为准** → 手机是唯一尺寸来源,PC 无法(也不会尝试)改动;手机离开时归属自动释放,PC 拿回自己的尺寸
- 手机选 **适配所有设备** → 取最小值,两端都不被裁切,代价是 PC 被钳住
- 默认 **跟随活动设备** → 谁在用谁说了算(此时确实会影响 PC 的视图,是用户的明确操作)
- **"换设备续接"靠 tmux 持久化 + page/viewport**:在哪台设备 attach 都看到同一 session,scrollback 不丢——不需要先把别的设备踢下线
- "真要同屏镜像看"(demo/教学/结对)= spectator 模式,放 v2

### 2.8 三状态机(保留,但职责调整)

每个 pane 在任意时刻处于三态之一:

| 状态 | 语义 | 视觉 |
|---|---|---|
| **Working** | 程序在跑,不需介入 | 中性 |
| **Idle** | 空闲/超时无输出 | 略暗 |
| **Awaiting Input** | 明确等用户决定,必须回应 | 琥珀色 |

**v0.3 职责变化**:三状态机不再驱动一个独立的"按需浮现 quick keys 面板"(那个被固定的浮动 ↑↓↵Esc 工具栏取代)。它现在驱动:

- **List 视图的状态点/颜色**(核心:"谁在等我")
- **标题栏状态点**
- **Live Activity / 通知**

检测可靠性优先押 **Awaiting**——它是"agent 要我回"的核心信号,working/idle 错了影响小。

---

## 三、交互设计

### 3.1 统一手势表(无模式系统)

v0.2 的 🎤/⌨️ 模式切换**已废弃**。键盘由双击召唤,不再有全局模式。

| 手势 | 行为 |
|---|---|
| 长按 ≥180ms | 触觉反馈 + 进入录音(语音) |
| 录音中保持不动 | 实时转写 + 方向提示悬浮 |
| 录音后松开(方向决定结果,见 3.2) | 发送 / 取消 / 转命令 / 仅输入 |
| 单指立即拖动 | 滚动 pane 历史(scrollback) |
| 双指拖动(**仅 page > viewport**) | page 平移导航 |
| 单击 | 选中/切换 active pane(幂等,无副作用闪烁) |
| 双击 | 弹出/收起键盘(**任何视图/模式恒定如此**) |
| 单指双击 pane 里文字 | 选词 + 手柄调整选区(SwiftTerm 原生) |
| 浮动快捷键 / 键盘 accessory | 发送对应按键 |
| tap 标题栏 ⛶ / ⋯ | 最大化(focus/zoom) / pane 菜单 |
| (List)tap 列表项 | 进入该 pane 全屏 focus |

**两条恒定铁律(任何视图/模式都一样):**
- **长按 = 语音**
- **双击 = 弹键盘**

**focus/zoom 永远由标题栏的 ⛶ 最大化按钮触发,绝不由手势(尤其不是双击)触发。** 在 Tiles 里单击 pane 只是把它选为 active(`select-pane`),要让它占满 window 必须点 ⛶。

手势优先级:长按语音(180ms)→ 单指拖动 scrollback → 双指平移(仅 page>viewport 时启用)。单击不 `require` 双击失败,所以双击 = 先选中再弹键盘(原子,符合直觉)。

### 3.2 Voice Input(微信式)—— 保留

(沿用 v0.2,无变化)

**录音阶段:** 按住 pane >180ms 触发,触觉反馈,pane 边框高亮,手指附近浮现:实时转写 + 四方向提示(↑发送 / ←→ AI shell / ↓取消 / 松开仅输入),手指滑向某方向高亮 + 微振动。**手指位置 = 录音目标**,保留"按哪个 pane 对哪个说话"的空间直觉。

**结束阶段(松开前方向):**
- 无方向 → 转写注入,不发送
- 上推 → 转写 + `\n`(发送)
- 左/右推 → 转写发 LLM 转 shell command,注入并发送
- 下推 → 取消

**滚动 vs 录音:** 按下立刻动 = 滚动;停住不动 = 计时开始;停住 180ms = 进入录音。两者自然过渡。

**引擎:** 默认 Apple SFSpeechRecognizer(本地/免费/中英混合好),Settings 可切 OpenAI(自带 key 或 proxy)。

**LLM 转命令:** MVP 自带 key,默认 pane 最后 N 行作上下文,首次启用弹窗告知,Settings 可配行数/模板/脱敏。

### 3.3 浮动快捷键栏(取代状态感知 Quick Keys)

- **固定四键:↑ ↓ ↵ Esc**,专为响应 agent 弹出的选择/确认 prompt(箭头在选项列表里移动、↵ 确认、Esc 取消——现代 agent 多用箭头选择而非敲 y/n)
- **常驻**(不再 state-gated),只要有 active pane 就在
- **定位**:贴 active pane 左下角,自动调整保证在屏幕内、不遮挡 active pane、键盘弹起时浮到键盘上方
- **样式**:Bento 卡片(`bentoSurface` 填充 + 1px `bentoBorder`,无阴影无 blur,遵循 `docs/design.md`),与软键盘上方的 accessory bar 是不同 surface(后者随键盘、键更多)

v0.2 基于 profile 的浮现式 quick keys([Y][N]…)在 MVP 简化掉;profile 体系仍可用于状态检测,但不再驱动独立按键面板。

### 3.4 三状态机检测(保留)

**识别机制(按优先级):** Hook 协议(v2)→ Title 匹配 → 输出正则(最后 N 行)→ tmux silence(无输出 > 阈值 = idle)→ 兜底 working。

**配置:** 按 `pane_current_command` 自动匹配 profile;用户可手动改;MVP 只内置 profile(Claude Code / Codex / 通用 shell / vim / git),自定义放 v2。

**触达:** 前台 = List 颜色 + 标题栏点 + 轻触觉;后台/锁屏 = Live Activity;**不发推送**(awaiting 不是紧急,推送会打断);节流(同 pane 不重复振动,多 pane 短时合并)。

### 3.5 Pane 标题栏(每个 pane 自己的)

每个 pane 顶部一条 ~32pt 窄标题栏:

- **背景与终端背景融合**,无分隔线、无对比带(两个 surface 流成一片)
- **左侧**:状态点 + pane title(单行截断)
- **右侧**:⛶ 最大化 + ⋯ pane 菜单
  - **⛶ 最大化 = 进入/退出 focus/zoom(tmux zoom)**。这是进入 focus 的**唯一**入口,不靠手势
  - **⋯ pane 菜单**(pane 作用域):关闭 / 分屏 H/V / 重命名 / 改 profile
- 非活跃 pane 隐藏右侧按钮,title 弱化
- 标题栏自身不承担手势(避免学习成本)

### 3.6 顶部栏(整个 session 的 chrome)

区别于 3.5 的 pane 标题栏——这条是整个屏幕顶部的应用栏,作用域是 session/全局。从左到右:

```
[← 返回]  [session 名称]            [ Tiles | List ]  [⋯]
```

- **返回按钮**:回到 session 列表
- **session 名称**:**宽度不够时隐藏**;**点击 = 切换 session 的快捷入口**(弹出当前 host 的 session 列表直接切,不必返回上一层)
- **Tiles / List 切换**:常驻的分段控件(segmented),一键切视图,**不在菜单里**
- **⋯ 菜单**(session/全局作用域):新建 window / window 列表 / Session Size 三选一(别的设备拥有时显示"由 X 设定") / 适配到当前设备 / Settings / kill session 等

> 注意:有**两个** ⋯ 菜单,作用域不同——顶部栏的是 session/全局级,pane 标题栏的是 pane 级。Session Size 这种会话级状态切换放顶部栏菜单,关闭/分屏这种 pane 级操作放 pane 菜单。

### 3.7 滚动(保留为硬约束)

单指立即拖动 = 滚动,零延迟,与所有其它手势靠"是否立刻移动"区分。滚动进 tmux copy-mode(透明),触底恢复跟随,多 pane 各自独立。

### 3.8 文本选择(保留)

双击选词 + 手柄拖动调整 + 浮出操作条(复制/全选/取消),复制进系统剪贴板 + 振动 + toast。

---

## 四、连接和基础设施

### 4.1 主界面

主机列表卡片(主机名/别名、用户名+地址、在线状态+最近连接)。点击进入。右上"+"添加主机。Bento 设计语言(见 `docs/design.md`)。

### 4.2 网络传输

MVP 默认 SSH,可选 mosh。手动重连,不自动重连(tmux 持久化已覆盖大部分断线场景)。接入层卖点:桌面 helper + 扫码配对替代 tailscale/手配 tmux(见路线图)。

### 4.3 SSH 密钥

导入私钥 + App 内生成,存 iOS Keychain(Face ID/Touch ID),公钥可导出。Secure Enclave 放 v2。

### 4.4 tmux 集成

- 用 tmux control mode(`tmux -CC`),客户端 UI 直接对应 tmux 真实状态
- **多 client 共享 window**(2.7):接入即 attach,**不强制断联**其它 client;尺寸冲突由尺寸权威(2.5)化解;**不默认 grouped session**
- 首次连接检测远端 tmux,无则提示安装
- 对用户透明(不需要知道 "tmux" 这个词)
- 未来可能用自建 daemon 替换/补充(附录 A),client 模型设计上不绑死 tmux 细节

---

## 五、视觉 / 字体 / 配色

### 5.1 字体

内置 3-5 种编程字体(SF Mono / JetBrains Mono / Maple NF CN / Menlo),预打包 Nerd Font 变体。字号在 Settings 离散选(小/中/大)。自定义字体放 v2。

### 5.2 配色主题

内置多套经典主题 + 支持导入 iTerm2 `.itermcolors`。可视化编辑器放 v2。终端外的 chrome 遵循 Bento 设计语言(`docs/design.md`,深色锁定,5 色 icon 调色板,无 purple)。

### 5.3 键盘工具栏(软键盘 accessory)

- iOS Input Accessory View,系统键盘上方,键盘收起一起消失
- 键位:Esc / Tab / Ctrl / ↑↓←→ / `|` / `/` / `~` / `-`,Ctrl 粘滞
- **与浮动快捷键栏(3.3)是两个不同的东西**:accessory 随键盘、键多,用于打字时;浮动栏常驻、只 4 键,用于不弹键盘快速回应 prompt

### 5.4 window / 多 pane 暴露

- Tiles/List 视图切换 + window 列表放在菜单
- 新手只看到一个 pane(List 默认),不需要理解 window 概念

---

## 六、反馈和触达

### 6.1 触觉

录音开始 light impact / 方向越阈 selection / 发送 success / 取消 warning。不做声音(公共场合)。Settings 可关。

### 6.2 Live Activity

awaiting pane 在锁屏/灵动岛显示,合并多 pane("X 个 pane 等待输入"),点击直达。不发推送。

### 6.3 Onboarding(简化)

首次进入终端弹**一次性引导覆盖层**,只教两个核心手势:

- **长按任意位置 → 说话**
- **双击任意位置 → 弹键盘**

点"我知道了"后永不再现(`UserDefaults`,per-app)。不再是 v0.2 的 5 张卡片(画布/模式相关的卡片已随架构废弃)。Settings 里保留"手势说明"页。

---

## 七、商业化

**MVP 阶段完全免费。** 重心打磨产品、积累用户。

- 永久免费:SSH、tmux 集成、Tiles/List、基础 voice、三状态识别、内置主题
- 未来可付费(Phase 2):NAT 穿透/跳板服务、ASR/LLM 额度、iTerm2 主题导入、iCloud 同步、Hook 协议、自定义 profile、Apple Watch、spectator 多端同看

---

## 八、MVP 范围

### 必做

**连接基础:** SSH + Keychain;tmux control mode;主机列表 UI;键盘工具栏 / 字体 / 主题(含 iTerm2 导入)

**显示与交互核心(本版重写):**
- page/viewport 模型 + 三条渲染规则(< / == / >)
- Tiles / List 两种视图,均可下钻 focus
- 尺寸权威三策略(跟随活动设备 / 适配所有设备 / 以此设备为准)+ 菜单切换 + 服务器端归属
- 严格 resize 触发白名单(键盘/滚动/平移/切 pane 绝不触发)
- 统一手势(无模式系统),双击弹键盘
- 多 client 共享 window(不强制断联),冲突由尺寸权威化解

**三大卖点:**
- Voice input(微信式):按住录音 + 四方向结束 + LLM 转 shell
- 浮动快捷键栏(↑↓↵Esc)响应 agent prompt
- 跨设备续接(page/viewport + tmux 持久化)

**其它:** 三状态机(驱动 List 颜色/标题栏/Live Activity);单指纯滚动;文本选择;窄标题栏(⋯ + ⛶);简化 onboarding;触觉;Live Activity

### 不做(v2+)

- 缩略图(List 第一层,待定)
- iPad Tiles 的拖动 divider 调 layout(下一阶段)
- spectator 多端同看镜像
- mosh 自动选择 / 自动重连
- 自定义 profile / Hook 协议
- 自建 daemon 替换 tmux(附录 A)
- 主题可视化编辑器 / 自定义字体 / Apple Watch / Catalyst / iCloud / SFTP / Secure Enclave

### 永远不做

- Claude Code 专用解析或 UI(保持通用 terminal)
- 绑定特定 AI agent 生态
- Android(至少前两年)

---

## 九、待决策 / 未深入

- List 第一层要不要加缩略图(目前倾向不加;若加,用"布局示意图"——按 pane 布局画矩形 + 状态着色,零终端渲染,且只对有空间安排的桌面来源 session 有意义)
- Tiles/List 切换的具体入口与默认记忆粒度
- "device size" 用于 match 判断时的精确定义(确定不含键盘;工具栏 reserve 是否计入)
- 后台保活、错误处理 UI、iCloud 同步
- 桌面 helper 自动配 tmux + NAT 穿透的具体形态(接入层卖点)
- TestFlight 招募、App Store 素材
- iPad + 物理键盘 / 触控板优化

---

## 十、v0.3 决策变更记录

### 反转 / 废弃(覆盖 v0.2)

- ❌ **画布模型(可缩放可平移)** → ✅ page/viewport(user-scalable=false)。理由:终端离散网格无稳定缩放态,是 resize storm 根因
- ❌ **语音/键盘模式系统(🎤/⌨️)** → ✅ 统一手势,双击弹键盘
- ❌ **grouped session 默认** → ✅ 多 client 共享 window + 尺寸权威(2.5/2.7),不强制断联
- ❌ **状态感知浮现 Quick Keys** → ✅ 固定浮动 ↑↓↵Esc(三状态机改为驱动 List/通知)
- ❌ **活跃/非活跃 pane 视觉 scale 字号差** → 不再适用(无缩放)
- ❌ **5 张 onboarding 卡片** → ✅ 一次性两手势引导覆盖层

### 新增关键决策

- **page 尺寸唯一事实 = tmux**(Tiles 里=window,Focus 里=pane)
- **那堵墙**:一个 window 一份共享几何,PTY/TUI 物理约束,daemon 也逃不掉
- **尺寸权威是会话级粘性状态**,存在 tmux 服务器上(`window-size` + `@bento_size_owner`),attach 只读不写
- **resize 严格白名单**:connect/手动/旋转(Tracking)/Split View(Tracking)/字号;键盘等绝不触发
- **Tiles/List 两视图**,尺寸权威只在 Tiles 有意义,List 永远适配设备(除非别的设备拥有尺寸)
- **多 client 共享 window,不强制断联;尺寸冲突由尺寸权威决定**
- **检测优先押 Awaiting 状态**

---

## 附录 A:自建 daemon 的未来考虑(不做,但记录)

讨论结论:现在不替换 tmux。

- **换 daemon 逃不掉那堵墙**(2.3)——几何是 PTY/TUI 物理,不是 tmux 的
- **也不解决 resize storm**——那是 client 端触发纪律的事(2.6),与底层无关
- **唯一真正能买到的**:把"pane = 独立 PTY"(而非共享 window 几何的 split),让 List/Focus 一次看一个 PTY 时直接 size 成设备尺寸,无需 zoom hack、PC 不受影响。把墙从 per-window 降到 per-PTY
- **代价**:terminal 多路复用是严肃工程(reflow/copy-mode/持久化);丢掉"attach 用户已有 tmux"的互操作;不是团队比较优势,也不是护城河

**策略**:MVP 留 tmux(白嫖持久化/reflow/互操作),client 的 pane/page/viewport 抽象不绑 tmux 细节。将来若判定"移动续接是核心卖点且独立-PTY 是其前提",再做 daemon,且大概率 **bento-native PTY 会话 + 可 attach 已有 tmux 并存**,非二选一。

---

## 附录 B:仍需留意的推测

- List 列表项的具体字段(状态点 + 名字 + 最近活动是建议)
- 三状态视觉强度(略暗/琥珀是推荐默认,你只说"可配置")
- Awaiting 之外两状态的检测精度要求(我判断可放宽)
- 浮动快捷键栏"常驻 vs 仅 awaiting 浮现"(我选了常驻,简单;若想省屏幕可改回 awaiting 浮现)
- 内置 profile 具体清单
