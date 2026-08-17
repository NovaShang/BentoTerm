import { chromium } from '/Users/nova/code/voltreality-keynote/node_modules/playwright/index.mjs'
import { writeFileSync } from 'node:fs'
writeFileSync('shade.html', `<!doctype html><style>*{margin:0}body{width:2160px;height:2160px}
.g{width:2160px;height:2160px;background:linear-gradient(to bottom, rgba(11,13,16,0) 56%, rgba(11,13,16,.97) 74%, #0b0d10 100%)}</style><div class="g"></div>`)
const b = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' })
const p = await b.newPage({ viewport: { width: 2160, height: 2160 } })
await p.goto('file://' + process.cwd() + '/shade.html')
await p.locator('.g').screenshot({ path: 'assets/text/shade.png', omitBackground: true })
await b.close(); console.log('shade done')
