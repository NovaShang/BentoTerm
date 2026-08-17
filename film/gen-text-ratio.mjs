// Text strips + overlay graphs for the landscape (1920x1080) and portrait
// (1080x1920) recomposes, en + zh. Times identical to the square master.
import { chromium } from '/Users/nova/code/voltreality-keynote/node_modules/playwright/index.mjs'
import { mkdirSync, writeFileSync } from 'node:fs'

const subsEN = [
  [1.0, 5.7, 'Your agent is working. So what are you doing?'],
  [5.9, 7.8, 'You could be running more of them.'],
  [7.9, 13.1, 'In Bento Term, all of your agents run in one window, like a bento box.'],
  [13.25, 17.95, 'You watch every one of them at once, instead of switching from task to task.'],
  [18.1, 21.55, 'When one needs your attention, its color tells you.'],
  [21.7, 27.35, 'Talking is about three times faster than typing. So voice is the main way you give input.'],
  [27.5, 35.3, 'You can drive the shell by voice. More importantly, you can direct your agents.'],
  [35.45, 40.7, 'Bento hears the context, so technical terms, even names from your code, come out right.'],
  [44.9, 48.05, 'Your agents don’t stop when you leave the desk.'],
  [48.05, 50.65, 'On the sofa, the iPad gives you the whole setup.'],
  [52.9, 55.15, 'On the road, your phone can finish anything.'],
  [57.95, 65.2, 'Parallel, voice, remote. It’s one way of working. And the gains multiply.'],
]
const chapEN = [
  [5.9, 21.7, 'A whole team, one screen'],
  [21.7, 44.9, 'Say it, don’t type it'],
  [44.9, 57.9, 'Leave the desk, not the work'],
]
const subsZH = [
  [1.0, 5.7, '你的 agent 正忙着。那你呢？'],
  [5.9, 7.8, '那就多开几个。'],
  [7.9, 13.1, 'Bento Term 把所有 agent 装进一个窗口，像便当盒一样。'],
  [13.25, 17.95, '每个格子在干什么，一眼看全，不用切来切去。'],
  [18.1, 21.55, '谁需要你，颜色会告诉你。'],
  [21.7, 27.35, '说话比打字快三倍。所以在 Bento，能说的就不用打。'],
  [27.5, 32.1, '对着 shell 说句话，命令就跑起来了。'],
  [32.3, 35.3, '更重要的是，还能这样指挥 agent。'],
  [35.45, 40.7, 'Bento 听得懂上下文，术语、代码里的名字，都一字不差。'],
  [44.9, 48.05, '合上电脑，agent 也不会停。'],
  [48.05, 51.5, '窝在沙发里，用 iPad 接着干，一样都不缺。'],
  [52.9, 55.8, '人在路上，手机也能把事办完。'],
  [57.95, 65.2, '并行、语音、远程。其实是同一种工作方式，效率成倍地涨。'],
]
const chapZH = [
  [5.9, 21.7, '一屏看全队'],
  [21.7, 44.9, '动口，不动手'],
  [44.9, 57.9, '人走，活不停'],
]

const PROFILES = [
  { key: 'l', W: 1920, subH: 250, subFont: 44, subMax: 1560, chapH: 170, chapFont: 36, subY: 820, chapY: 14 },
  { key: 'p', W: 1080, subH: 320, subFont: 42, subMax: 930, chapH: 190, chapFont: 40, subY: 1510, chapY: 130 },
]
const LANGS = [
  { key: 'en', subs: subsEN, chaps: chapEN },
  { key: 'zh', subs: subsZH, chaps: chapZH },
]

const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' })
for (const P of PROFILES) {
  const html = `<!doctype html><meta charset="utf-8"><style>
    @font-face { font-family: Geist; src: url(assets/site/fonts/geist-sans-500.woff2) format('woff2'); font-weight: 500; }
    @font-face { font-family: Geist; src: url(assets/site/fonts/geist-sans-600.woff2) format('woff2'); font-weight: 600; }
    * { margin: 0; } body { background: transparent; font-family: Geist, sans-serif; }
    .strip { width: ${P.W}px; display: flex; align-items: center; justify-content: center; text-align: center; }
    .sub  { height: ${P.subH}px; background: linear-gradient(to bottom, rgba(5,6,8,0) 0%, rgba(5,6,8,.62) 30%, rgba(5,6,8,.62) 78%, rgba(5,6,8,0) 100%); }
    .sub span { font-size: ${P.subFont}px; font-weight: 500; color: #f2f3f5; max-width: ${P.subMax}px; line-height: 1.3;
          text-shadow: 0 0 5px rgba(0,0,0,1), 0 0 5px rgba(0,0,0,1), 0 2px 8px rgba(0,0,0,1), 0 2px 14px rgba(0,0,0,.95), 0 4px 26px rgba(0,0,0,.9); }
    .chap { height: ${P.chapH}px; } .chap span { font-size: ${P.chapFont}px; font-weight: 600; color: rgba(240,238,235,.82); letter-spacing: .22em;
          text-transform: uppercase; text-shadow: 0 0 5px rgba(0,0,0,1), 0 0 5px rgba(0,0,0,1), 0 2px 8px rgba(0,0,0,1), 0 2px 12px rgba(0,0,0,.95); }
  </style><div id="host"></div>`
  writeFileSync(`overlay-strips-${P.key}.html`, html)
  const page = await browser.newPage({ viewport: { width: P.W, height: 400 } })
  await page.goto('file://' + process.cwd() + `/overlay-strips-${P.key}.html`)
  await page.waitForTimeout(400)
  for (const L of LANGS) {
    const dir = `assets/text-${P.key}/${L.key}`
    mkdirSync(dir, { recursive: true })
    const shoot = async (cls, text, path) => {
      await page.evaluate(([cls, text]) => {
        document.getElementById('host').innerHTML = `<div class="strip ${cls}"><span>${text}</span></div>`
      }, [cls, text])
      await page.waitForTimeout(80)
      await page.locator('.strip').screenshot({ path, omitBackground: true })
    }
    for (let i = 0; i < L.subs.length; i++) await shoot('sub', L.subs[i][2], `${dir}/sub-${String(i).padStart(2, '0')}.png`)
    for (let i = 0; i < L.chaps.length; i++) await shoot('chap', L.chaps[i][2], `${dir}/chap-${i}.png`)
    // graph
    const all = [
      ...L.subs.map((s, i) => ({ f: `${dir}/sub-${String(i).padStart(2, '0')}.png`, y: P.subY, a: s[0], b: s[1] })),
      ...L.chaps.map((c, i) => ({ f: `${dir}/chap-${i}.png`, y: P.chapY, a: c[0], b: c[1] })),
    ]
    let g = '', prev = '0:v'
    all.forEach((o, i) => {
      const out = i === all.length - 1 ? '[v]' : `[t${i}]`
      g += `[${prev}][${i + 1}:v]overlay=0:${o.y}:enable='between(t,${o.a},${o.b})'${out};`
      prev = `t${i}`
    })
    writeFileSync(`${dir}/inputs.txt`, all.map(o => `-i ${o.f}`).join(' ') + '\n')
    writeFileSync(`${dir}/graph.txt`, g.replace(/;$/, '') + '\n')
    console.log(`${P.key}/${L.key}: ${all.length} strips`)
  }
  await page.close()
}
await browser.close()