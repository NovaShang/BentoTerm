// Text overlays as transparent PNGs (this ffmpeg build has no libass or
// drawtext, and Chrome gives us Geist anyway). One strip per subtitle line
// (bottom) and per chapter title (top); build-v2 overlays them with
// enable='between(t,..)' windows. Times live in overlays().
import { chromium } from '/Users/nova/code/voltreality-keynote/node_modules/playwright/index.mjs'
import { mkdirSync, writeFileSync } from 'node:fs'

export const subs = [
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
export const chapters = [
  [5.9, 21.7, 'A whole team, one screen'],
  [21.7, 44.9, 'Say it, don’t type it'],
  [44.9, 57.9, 'Leave the desk, not the work'],
]

const html = `<!doctype html><meta charset="utf-8"><style>
  @font-face { font-family: Geist; src: url(assets/site/fonts/geist-sans-500.woff2) format('woff2'); font-weight: 500; }
  @font-face { font-family: Geist; src: url(assets/site/fonts/geist-sans-600.woff2) format('woff2'); font-weight: 600; }
  * { margin: 0; } body { background: transparent; font-family: Geist, sans-serif; }
  .strip { width: 2160px; display: flex; align-items: center; justify-content: center; text-align: center; }
  .sub  { height: 340px; background: linear-gradient(to bottom, rgba(5,6,8,0) 0%, rgba(5,6,8,.62) 30%, rgba(5,6,8,.62) 78%, rgba(5,6,8,0) 100%); } .sub span { font-size: 62px; font-weight: 500; color: #f2f3f5; max-width: 1840px; line-height: 1.3;
          text-shadow: 0 0 6px rgba(0,0,0,1), 0 0 6px rgba(0,0,0,1), 0 2px 10px rgba(0,0,0,1),
            0 2px 18px rgba(0,0,0,.95), 0 4px 34px rgba(0,0,0,.9), 0 6px 60px rgba(0,0,0,.85); }
  .chap { height: 300px; } .chap span { font-size: 56px; font-weight: 600; color: rgba(240,238,235,.82); letter-spacing: .14em;
          text-transform: uppercase; text-shadow: 0 0 6px rgba(0,0,0,1), 0 0 6px rgba(0,0,0,1), 0 2px 10px rgba(0,0,0,1),
            0 2px 16px rgba(0,0,0,.95), 0 4px 30px rgba(0,0,0,.9); }
</style><div id="host"></div>`
writeFileSync('overlay-strips.html', html)
mkdirSync('assets/text', { recursive: true })

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
for (let i = 0; i < subs.length; i++) await shoot('sub', subs[i][2], `assets/text/sub-${String(i).padStart(2, '0')}.png`)
for (let i = 0; i < chapters.length; i++) await shoot('chap', chapters[i][2], `assets/text/chap-${i}.png`)
await browser.close()

// emit the ffmpeg overlay filtergraph for build-v2 to source
let g = '', prev = '0:v'
const all = [
  ...subs.map((s, i) => ({ f: `assets/text/sub-${String(i).padStart(2, '0')}.png`, y: 1800, a: s[0], b: s[1] })),
  ...chapters.map((c, i) => ({ f: `assets/text/chap-${i}.png`, y: 70, a: c[0], b: c[1] })),
]
const inputs = all.map(o => `-i ${o.f}`).join(' ')
all.forEach((o, i) => {
  const out = i === all.length - 1 ? '[v]' : `[t${i}]`
  g += `[${prev}][${i + 1}:v]overlay=0:${o.y}:enable='between(t,${o.a},${o.b})'${out};`
  prev = `t${i}`
})
writeFileSync('assets/text/inputs.txt', inputs + '\n')
writeFileSync('assets/text/graph.txt', g.slice(0, -1).replaceAll('[t', '[t').replace(/;$/, '') + '\n')
console.log(`done: ${all.length} strips`)