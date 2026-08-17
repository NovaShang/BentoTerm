// Cards for landscape (2560x1440, the original 16:9 design) and portrait
// (1080x1920, fonts scaled down and stacked), en + zh.
import { chromium } from '/Users/nova/code/voltreality-keynote/node_modules/playwright/index.mjs'
const b = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' })
const PORTRAIT_CSS = `body,.card{width:1080px!important;height:1920px!important}
  .triad{font-size:64px!important;gap:44px!important}
  .claimline{font-size:42px!important;margin-top:60px!important}
  .claimsub{font-size:28px!important}
  .end img{width:140px!important;height:140px!important}
  .end h1{font-size:52px!important;max-width:900px!important;margin-top:48px!important}
  .end .url{font-size:58px!important;margin-top:56px!important}
  .end p{font-size:22px!important}`
for (const lang of ['', '-zh']) {
  const file = lang ? 'cards-zh.html' : 'cards.html'
  // landscape: the file's native 2560x1440 layout
  let p = await b.newPage({ viewport: { width: 2560, height: 1440 } })
  await p.goto('file://' + process.cwd() + '/' + file)
  await p.waitForTimeout(600)
  for (const id of ['claim', 'end']) {
    await p.evaluate(id => { for (const c of document.querySelectorAll('.card')) c.style.display = c.id === id ? 'flex' : 'none' }, id)
    await p.waitForTimeout(150)
    await p.screenshot({ path: `assets/cards/${id}${lang}-l.png` })
  }
  await p.close()
  // portrait
  p = await b.newPage({ viewport: { width: 1080, height: 1920 } })
  await p.goto('file://' + process.cwd() + '/' + file)
  await p.addStyleTag({ content: PORTRAIT_CSS })
  await p.waitForTimeout(600)
  for (const id of ['claim', 'end']) {
    await p.evaluate(id => { for (const c of document.querySelectorAll('.card')) c.style.display = c.id === id ? 'flex' : 'none' }, id)
    await p.waitForTimeout(150)
    await p.screenshot({ path: `assets/cards/${id}${lang}-p.png` })
  }
  await p.close()
  console.log(file, 'l+p done')
}
await b.close()
