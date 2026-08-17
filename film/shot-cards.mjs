// Screenshot each card in cards.html to a 2560x1440 PNG (real Chrome for fonts).
import { chromium } from '/Users/nova/code/voltreality-keynote/node_modules/playwright/index.mjs'
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' })
const page = await browser.newPage({ viewport: { width: 2560, height: 1440 } })
await page.goto('file://' + process.cwd() + '/cards.html')
await page.waitForTimeout(800)
for (const id of ['claim', 'end']) {
  await page.evaluate(id => {
    for (const c of document.querySelectorAll('.card')) c.style.display = c.id === id ? 'flex' : 'none'
  }, id)
  await page.waitForTimeout(200)
  await page.screenshot({ path: `assets/cards/${id}.png` })
  console.log(id, 'done')
}
await browser.close()
