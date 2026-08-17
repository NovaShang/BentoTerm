// Text overlays as transparent PNGs (this ffmpeg build has no libass or
// drawtext, and Chrome gives us Geist anyway). One strip per subtitle line
// (bottom) and per chapter title (top); build-v2 overlays them with
// enable='between(t,..)' windows. Times live in overlays().
import { chromium } from '/Users/nova/code/voltreality-keynote/node_modules/playwright/index.mjs'
import { mkdirSync, writeFileSync } from 'node:fs'

export const subs = [
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
export const chapters = [
  [5.9, 21.7, '一屏看全队'],
  [21.7, 44.9, '动口，不动手'],
  [44.9, 57.9, '人走，活不停'],
]

const html = `<!doctype html><meta charset="utf-8"><style>
  @font-face { font-family: Geist; src: url(assets/site/fonts/geist-sans-500.woff2) format('woff2'); font-weight: 500; }
  @font-face { font-family: Geist; src: url(assets/site/fonts/geist-sans-600.woff2) format('woff2'); font-weight: 600; }
  * { margin: 0; } body { background: transparent; font-family: Geist, sans-serif; }
  .strip { width: 2160px; display: flex; align-items: center; justify-content: center; text-align: center; }
  .sub  { height: 340px; background: linear-gradient(to bottom, rgba(5,6,8,0) 0%, rgba(5,6,8,.62) 30%, rgba(5,6,8,.62) 78%, rgba(5,6,8,0) 100%); } .sub span { font-size: 62px; font-weight: 500; color: #f2f3f5; max-width: 1840px; line-height: 1.3;
          text-shadow: 0 0 6px rgba(0,0,0,1), 0 0 6px rgba(0,0,0,1), 0 2px 10px rgba(0,0,0,1),
            0 2px 18px rgba(0,0,0,.95), 0 4px 34px rgba(0,0,0,.9), 0 6px 60px rgba(0,0,0,.85); }
  .chap { height: 300px; } .chap span { font-size: 56px; font-weight: 600; color: rgba(240,238,235,.82); letter-spacing: .3em;
          text-transform: uppercase; text-shadow: 0 0 6px rgba(0,0,0,1), 0 0 6px rgba(0,0,0,1), 0 2px 10px rgba(0,0,0,1),
            0 2px 16px rgba(0,0,0,.95), 0 4px 30px rgba(0,0,0,.9); }
</style><div id="host"></div>`
writeFileSync('overlay-strips.html', html)
mkdirSync('assets/text-zh', { recursive: true })

const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' })
const page = await browser.newPage({ viewport: { width: 2160, height: 400 } })
await page.goto('file://' + process.cwd() + '/overlay-strips.html')
await page.waitForTimeout(500)
async function shoot(cls, text, path) {
  await page.evaluate(([cls, text]) => {
    document.getElementById('host').innerHTML = `<div class="strip ${cls}"><span>${text}</span></div>`
  }, [cls, text])
  await page.waitForTimeout(120)
  const el = page.locator('.strip')
  await el.screenshot({ path, omitBackground: true })
}
for (let i = 0; i < subs.length; i++) await shoot('sub', subs[i][2], `assets/text-zh/sub-${String(i).padStart(2, '0')}.png`)
for (let i = 0; i < chapters.length; i++) await shoot('chap', chapters[i][2], `assets/text-zh/chap-${i}.png`)
await browser.close()

// emit the ffmpeg overlay filtergraph for build-v2 to source
let g = '', prev = '0:v'
const all = [
  ...subs.map((s, i) => ({ f: `assets/text-zh/sub-${String(i).padStart(2, '0')}.png`, y: 1800, a: s[0], b: s[1] })),
  ...chapters.map((c, i) => ({ f: `assets/text-zh/chap-${i}.png`, y: 70, a: c[0], b: c[1] })),
]
const inputs = all.map(o => `-i ${o.f}`).join(' ')
all.forEach((o, i) => {
  const out = i === all.length - 1 ? '[v]' : `[t${i}]`
  g += `[${prev}][${i + 1}:v]overlay=0:${o.y}:enable='between(t,${o.a},${o.b})'${out};`
  prev = `t${i}`
})
writeFileSync('assets/text-zh/inputs.txt', inputs + '\n')
writeFileSync('assets/text-zh/graph.txt', g.slice(0, -1).replaceAll('[t', '[t').replace(/;$/, '') + '\n')
console.log(`done: ${all.length} strips`)