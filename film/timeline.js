// The film, as data. Everything the stage shows is computed from this table —
// there is no other source of timing. Durations in seconds of FILM time.
//
// ANIMATIC MODE: this cut exists to be judged, not shipped. Every missing or
// wrong piece of footage says so on camera —
//   cls:'slate'  full-screen card describing footage that doesn't exist yet
//   cls:'chip'   corner note over footage that exists but will be re-recorded
// and the whole VO rides as a persistent subtitle track (`vo` below), so the
// pacing can be felt before anything is re-shot. Slates and chips are ordinary
// cards — delete their lines as the real footage lands.
//
// Shot fields:
//   src    clip path (null = card-only shot on black)
//   in     seconds into the source clip where this shot starts
//   dur    how long the shot holds the stage
//   fit    'width' (default, letterboxed) | 'portrait' (phone, centered)
//   xfade  crossfade INTO this shot, seconds (0 = hard cut)
//   push   {from:[x,y,scale], to:[x,y,scale]} — linear drift over the shot
//   crop   source-pixel rect scaled to fill the stage width
//   cards  [{at, dur, cls, html}] — overlays, times relative to shot start;
//          0.4s fade in/out handled by the engine

export const FPS = 60;
export const W = 2560, H = 1440;

export const shots = [
  { // 1 · cold open — question form (picked over statement / timer / silent)
    src: null, dur: 7,
    cards: [
      { at: 0, dur: 7, cls: 'slate', html: '<b>R1 · 待录</b>满屏 Terminal.app：claude 正在深跑，工具调用与输出连续滚动，无人操作' },
      { at: 1.0, dur: 5.8, cls: 'open', html: 'Your agent is working.' },
      { at: 3.4, dur: 3.4, cls: 'open open2', html: 'So what are you doing?' },
    ],
  },
  { // 2–4 · one screen
    src: 'assets/clips/edit-panes.mov', in: 1.5, dur: 20, xfade: 0.5,
    crop: { x: 56, y: 38, w: 1742, h: 934 },
    cards: [
      { at: 0.2, dur: 19.6, cls: 'chip', html: '<b>R2 重录</b>现素材是拖动演示；成片：静止五格 → 琥珀格按 1 → 转蓝，其余继续滚' },
      { at: 0.6, dur: 4.0, cls: 'chapter', html: 'A whole team, one screen' },
      { at: 13.0, dur: 6.0, cls: 'states',
        html: '<span class="w">working</span><span class="a">waiting for you</span><span class="d">done</span><span class="i">idle</span>' },
    ],
  },
  { // 5–7 · voice
    src: 'assets/clips/voice-input.mov', in: 0.5, dur: 17,   // R3 must record >=18s
    crop: { x: 56, y: 38, w: 1742, h: 934 },
    push: { from: [0, 0, 1.0], to: [-180, -60, 1.28] },  // drift toward the wheel
    cards: [
      { at: 0.2, dur: 16.6, cls: 'chip', html: '<b>R3 重录</b>示范句换成中英混说「跑一下 tests，然后把 diff 发我看一下，别 commit」；⇧⌘5 开麦收真人声' },
      { at: 0.6, dur: 4.0, cls: 'chapter', html: 'Say it, don’t type it' },
      { at: 8.5, dur: 4.5, cls: 'note', html: '~3× faster than typing' },
    ],
  },
  { // 8 · ⌘Q — footage doesn't exist yet
    src: null, dur: 7,
    cards: [
      { at: 0, dur: 7, cls: 'slate', html: '<b>R4 · 待录</b>五格可见还在跑 → 干脆 ⌘Q，app 消失露出干净桌面 → 静 3 拍' },
      { at: 0.6, dur: 4.2, cls: 'chapter', html: 'Leave the desk, not the work' },
    ],
  },
  { // 9 · lid close — generated (Hailuo). Optional beat: cut it and 8→10 still works.
    src: 'assets/gen/G1.mp4', in: 3.2, dur: 2.5,   // clip opens THEN closes; use only the closing half (3.0-5.7s)
    cards: [
      { at: 0.2, dur: 2.1, cls: 'chip', html: '<b>G1 · 已生成</b>可选镜头，砍掉不伤结构' },
    ],
  },
  { // 10 · phone
    src: 'assets/clips/iphone focus mode.mov', in: 2, dur: 15, fit: 'portrait', xfade: 0.5,
    cards: [
      { at: 0.2, dur: 14.6, cls: 'chip', html: '<b>R5 重录</b>现素材无琥珀时刻；成片：列表滚动 → 琥珀出现 → 点进按掉（Mac app 保持退出）' },
      { at: 9.5, dur: 5.0, cls: 'note', html: 'Same session. Still running.' },
    ],
  },
  { // 11 · credo — timed to the measured VO, lines accumulate
    src: null, dur: 10, xfade: 0.6,
    cards: [
      { at: 0.4, dur: 9.2, cls: 'credo', html: 'Parallel agents make faster input worth having.' },
      { at: 3.5, dur: 6.1, cls: 'credo c2', html: 'Faster input keeps parallel agents from piling up.' },
      { at: 6.9, dur: 2.7, cls: 'credo c3', html: 'Neither one resets when you stand up.' },
    ],
  },
  { // 12 · the claim
    src: null, dur: 5.5,
    cards: [
      { at: 0.5, dur: 5.0, cls: 'claim', html: 'Not three features — one way of working.' },
      { at: 2.6, dur: 2.9, cls: 'claim c2', html: 'And it compounds.' },
    ],
  },
  { // 13 · endcard
    src: null, dur: 8, xfade: 0.6,
    cards: [
      { at: 0.4, dur: 7.6, cls: 'end', html: `
        <img src="assets/site/bento-icon.svg" alt="">
        <h1>A terminal for watching and <em>talking</em> to your agents</h1>
        <code>brew install --cask NovaShang/tap/bento-term</code>
        <p>bentoai.dev · Free &amp; open source · macOS 14+ · iPhone &amp; iPad</p>` },
    ],
  },
];

let t0 = 0;
for (const s of shots) { s.start = t0; t0 += s.dur; }
export const TOTAL = t0;

// ---- VO ---------------------------------------------------------------------
// SCRIPT v2 (2026-08-13): the user's dictated narrative, polished. The cold
// open stays silent (cards only); the VO enters on the answer. Register stays
// plain-declarative (a synthetic voice is a flat reader). `tts` is what the
// synthesizer reads — <#x#> inserts a pause; subtitles show `text`.
//
// `at`/`dur` are PROVISIONAL — the shot table above still reflects the old
// storyboard; both get re-fitted once the audio and new storyboard land.
// `sectionEnd: true` marks a chapter boundary (longer breath in the full mix).
export const vo = [
  { at: 1.0, dur: 5.5, text: 'Your agent is working. So what are you doing?',
    tts: 'Your agent is working. <#0.7#> So what are you doing?', sectionEnd: true },

  { at: 7.5, dur: 3.0, text: 'You could be running more of them.' },
  { at: 11.0, dur: 5.0, text: 'In Bento Term, all of your agents run in one window, like a bento box.' },
  { at: 16.5, dur: 5.0, text: 'You watch every one of them at once, instead of switching from task to task.' },
  { at: 22.0, dur: 4.5, text: 'When one needs your attention, its color tells you.', sectionEnd: true },

  { at: 27.5, dur: 6.0, text: 'Talking is about three times faster than typing. So voice is the main way you give input.',
    tts: 'Talking is about three times faster than typing. <#0.4#> So voice is the main way you give input.' },
  { at: 34.0, dur: 6.0, text: 'You can drive the shell by voice. More importantly, you can direct your agents.',
    tts: 'You can drive the shell by voice. <#0.4#> More importantly, you can direct your agents.' },
  { at: 40.5, dur: 6.0, text: 'Bento hears the context, so technical terms, even names from your code, come out right.', sectionEnd: true },

  { at: 47.0, dur: 4.0, text: 'Your agents don’t stop when you leave the desk.' },
  { at: 51.5, dur: 4.0, text: 'On the sofa, the iPad gives you the whole setup.' },
  { at: 56.0, dur: 4.0, text: 'On the road, your phone can finish anything.', sectionEnd: true },

  { at: 61.0, dur: 8.0, text: 'Parallel, voice, remote. It’s one way of working. And the gains multiply.',
    // NOT isolated one-word "sentences": "Parallel." on its own got misread.
    // A comma list keeps real words in context; pauses still shape the beat.
    tts: 'Parallel, <#0.4#> voice, <#0.4#> and remote. <#0.5#> It’s one way of working. <#0.5#> And the gains multiply.' },
];

// Audio placement (M3/M4): the `vo` table above drives the ffmpeg mix too.
export const audio = [];
