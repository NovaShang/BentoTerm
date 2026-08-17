/**
 * Generated live-action shots → film/assets/gen/
 *
 * MiniMax video generation (Hailuo), same account/key as gen-vo.mjs. Async
 * API: submit → task_id, poll → file_id, retrieve → download_url.
 *
 * HOUSE RULE baked into every prompt: no readable screen content, no logos.
 * Generated footage supplies atmosphere only — any UI the film shows must be
 * a real recording. A generated frame with legible fake UI is exactly the
 * kind of shot this project promised never to ship.
 *
 * Usage:
 *   node gen-video.mjs            # generate every shot below
 *   node gen-video.mjs G1         # just one
 */
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'

const MODEL = 'MiniMax-H3'   // Hailuo 03, shipped 2026-07-31 — v2 endpoint, content-array request
const BASE = 'https://api.minimax.io/v1'

const SHOTS = {
  G1: {
    duration: 6,
    prompt:
      'Close-up, low three-quarter angle: two hands gently close the lid of an ultra-thin modern unibody aluminum laptop on a dark wooden desk at night. The laptop has correct proportions: a flat thin rectangular lid, straight hinge along the back edge, keyboard deck below. As the lid lowers, the screen glow narrows to a thin line and goes dark. One warm desk lamp as background bokeh, shallow depth of field, cinematic dark grade. The screen faces away obliquely; its content is never readable. No logos anywhere. [Static shot]',
  },
  G2: {
    duration: 6,
    prompt:
      'Evening living room, a person relaxing on a sofa holding a smartphone, seen from behind over the shoulder. The phone is angled away from camera so the screen content is not visible. Soft warm lamp light, cozy, cinematic shallow depth of field, dark moody grade. No logos. [Static shot]',
  },
  G3: {
    duration: 6,
    prompt:
      'Inside a modern train at dusk: seen from behind a seated passenger, their hand holds a smartphone with only its plain matte BACK toward the camera, the screen fully turned away and never visible. Beyond it, the window with landscape streaking past in blue-hour light. Cinematic, shallow depth of field, moody. No logos, no visible screen. [Static shot]',
  },
}

async function readEnv(url) {
  if (!existsSync(url)) return {}
  const out = {}
  for (const line of (await readFile(url, 'utf8')).split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.+)$/)
    if (m) out[m[1]] = m[2].trim()
  }
  return out
}
const env = {
  ...(await readEnv(new URL('../../voltreality-keynote/.env.local', import.meta.url))),
  ...(await readEnv(new URL('./.env.local', import.meta.url))),
  ...process.env,
}
const key = env.MINIMAX_API_KEY
if (!key) { console.error('MINIMAX_API_KEY not found'); process.exit(1) }
const H = { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` }

const outDir = new URL('./assets/gen/', import.meta.url)
await mkdir(outDir, { recursive: true })

const wanted = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(SHOTS)

// submit everything first, then poll — the queue runs server-side in parallel
const tasks = []
for (const id of wanted) {
  const s = SHOTS[id]
  if (!s) { console.error(`unknown shot ${id}`); process.exit(1) }
  const res = await fetch(`${BASE.replace('/v1', '/v2')}/video_generation`, {
    method: 'POST', headers: H,
    body: JSON.stringify({
      model: MODEL,
      content: [{ type: 'text', text: s.prompt }],
      resolution: '2K',            // 2K in 16:9 = the master's own pixel size
      ratio: '16:9',
      duration: s.duration,
    }),
  })
  const json = await res.json()
  const err = json.error?.message ?? (json.base_resp && json.base_resp.status_code !== 0 ? json.base_resp.status_msg : null)
  if (err) { console.error(`${id} submit failed: ${err}`); process.exit(1) }
  const taskId = json.task_id ?? json.id
  if (!taskId) { console.error(`${id} no task id in: ${JSON.stringify(json).slice(0, 300)}`); process.exit(1) }
  console.log(`${id} submitted → task ${taskId}`)
  tasks.push({ id, task: taskId })
}

for (const t of tasks) {
  process.stdout.write(`${t.id} `)
  // Poll v1, not v2: v2's query ignores task_id and items[0] is just the
  // account's newest task — polling two shots returned the same video twice
  // (G2 and G3 came back byte-identical). v1 addresses the task properly.
  let fileId = null
  for (let i = 0; i < 120; i++) {           // up to ~10 min per shot
    await new Promise(r => setTimeout(r, 5000))
    const res = await fetch(`${BASE}/query/video_generation?task_id=${t.task}`, { headers: H })
    const json = await res.json()
    process.stdout.write('.')
    if (json.status === 'Success') { fileId = json.file_id; break }
    if (json.status === 'Fail') { console.log(` ✗ generation failed`); break }
  }
  if (!fileId) continue
  const r2 = await fetch(`${BASE}/files/retrieve?file_id=${fileId}`, { headers: H })
  const url = (await r2.json()).file?.download_url
  if (!url) { console.log(` ✗ no download_url`); continue }
  const buf = Buffer.from(await (await fetch(url)).arrayBuffer())
  await writeFile(new URL(`${t.id}.mp4`, outDir), buf)
  console.log(` ✓ ${t.id}.mp4 (${(buf.length / 1048576).toFixed(1)} MB)`)
}
