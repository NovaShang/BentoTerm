import { chromium } from '/Users/nova/code/voltreality-keynote/node_modules/playwright/index.mjs'
const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' })
const page = await browser.newPage({ viewport: { width: 2160, height: 2160 } })
await page.goto('file://' + process.cwd() + '/cards-zh.html')
await page.addStyleTag({ content: 'body,.card{width:2160px!important;height:2160px!important}' })
await page.waitForTimeout(800)
for (const id of ['claim', 'end']) {
  await page.evaluate(id => { for (const c of document.querySelectorAll('.card')) c.style.display = c.id === id ? 'flex' : 'none' }, id)
  await page.waitForTimeout(200)
  await page.screenshot({ path: `assets/cards/${id}-zh.png` })
  console.log(id, 'sq done')
}
await browser.close()
