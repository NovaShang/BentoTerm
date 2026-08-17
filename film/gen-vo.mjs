/**
 * VO generation → film/audio/vo/
 *
 * Source of truth: timeline.js `vo` — one clip per line, because lines are the
 * unit the mix places on the clock. After generating, actual durations are
 * measured (ffprobe) into manifest.json so the timeline can be re-fitted to
 * the voice, not the voice to the timeline.
 *
 * API shape mirrors voltreality-keynote/scripts/gen-voice.mjs (proven):
 * api.minimax.io t2a_v2, Bearer key, hex audio in JSON. The key is read from
 * that repo's .env.local — referenced, not copied; film/.env.local overrides.
 *
 * Usage:
 *   node gen-vo.mjs --voices               # list system voices (pick English ones)
 *   node gen-vo.mjs --sample v1 v2 …       # one VO line in each candidate voice
 *   node gen-vo.mjs --full <voice_id>      # whole script in ONE request → full.mp3
 *   node gen-vo.mjs <voice_id>             # generate all lines + manifest.json
 *   node gen-vo.mjs <voice_id> 3 7         # regenerate specific lines (0-based)
 */
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { vo } from './timeline.js'

const MODEL = 'speech-02-hd'
const API = 'https://api.minimax.io/v1/t2a_v2'

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

async function tts(text, voiceId) {
  const res = await fetch(API, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
    body: JSON.stringify({
      model: MODEL,
      text,
      voice_setting: { voice_id: voiceId, speed: 1.0, vol: 1.0, pitch: 0 },
      audio_setting: { format: 'mp3', sample_rate: 44100, bitrate: 128000 },
    }),
  })
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`)
  const json = await res.json()
  if (json.base_resp?.status_code !== 0)
    throw new Error(`${json.base_resp?.status_code} ${json.base_resp?.status_msg}`)
  return Buffer.from(json.data.audio, 'hex')
}

const outDir = new URL('./audio/vo/', import.meta.url)
await mkdir(outDir, { recursive: true })
const args = process.argv.slice(2)

if (args[0] === '--voices') {
  const res = await fetch('https://api.minimax.io/v1/get_voice', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
    body: JSON.stringify({ voice_type: 'system' }),
  })
  const json = await res.json()
  const list = json.system_voice ?? []
  for (const v of list) console.log(`${v.voice_id}\t${v.voice_name ?? ''}`)
  console.log(`— ${list.length} voices`)
  process.exit(0)
}

// The line that stresses a voice most: pacing, a dash, and the states litany.
const SAMPLE = vo[3].text

if (args[0] === '--sample') {
  for (const v of args.slice(1)) {
    process.stdout.write(`sample ${v} … `)
    try {
      const buf = await tts(SAMPLE, v)
      await writeFile(new URL(`sample-${v}.mp3`, outDir), buf)
      console.log(`✓ ${(buf.length / 1024).toFixed(0)} KB`)
    } catch (e) { console.log(`✗ ${e.message}`) }
  }
  process.exit(0)
}

if (args[0] === '--full') {
  // One request for the whole script: the model shapes intonation across the
  // full arc instead of eleven cold starts. Breathing room comes from pause
  // markers — a longer one at each sectionEnd (chapter boundary).
  const v = args[1]
  if (!v) { console.error('usage: gen-vo.mjs --full <voice_id>'); process.exit(1) }
  const script = vo
    .map((l, i) => (l.tts ?? l.text) + (i < vo.length - 1 ? (l.sectionEnd ? ' <#1.0#>' : ' <#0.6#>') : ''))
    .join(' ')
  console.log(`script: ${script.length} chars, ${vo.length} lines`)
  const buf = await tts(script, v)
  const path = new URL('full.mp3', outDir)
  await writeFile(path, buf)
  const dur = parseFloat(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration',
    '-of', 'csv=p=0', path.pathname]).toString())
  console.log(`✓ full.mp3 — ${(buf.length / 1024).toFixed(0)} KB, ${dur.toFixed(1)}s, voice ${v}`)
  process.exit(0)
}

const voice = args[0]
if (!voice) { console.error('usage: gen-vo.mjs --voices | --sample <id…> | --full <id> | <voice_id> [line…]'); process.exit(1) }
const only = args.slice(1).map(Number)

const manifest = []
for (let i = 0; i < vo.length; i++) {
  const name = `line-${String(i).padStart(2, '0')}.mp3`
  const path = new URL(name, outDir)
  if (!only.length || only.includes(i)) {
    process.stdout.write(`${name} “${vo[i].text.slice(0, 40)}…” `)
    const buf = await tts(vo[i].tts ?? vo[i].text, voice)
    await writeFile(path, buf)
    console.log(`✓ ${(buf.length / 1024).toFixed(0)} KB`)
    await new Promise(r => setTimeout(r, 300))
  }
  const dur = existsSync(path)
    ? parseFloat(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration',
        '-of', 'csv=p=0', path.pathname]).toString())
    : null
  manifest.push({ i, file: name, at: vo[i].at, slot: vo[i].dur, actual: dur, text: vo[i].text })
}
await writeFile(new URL('manifest.json', outDir),
  JSON.stringify({ voice, lines: manifest }, null, 2))

// The report that matters: which lines don't fit their slot.
for (const l of manifest) if (l.actual && l.actual > l.slot + 0.15)
  console.log(`⚠ line ${l.i} runs ${l.actual.toFixed(1)}s in a ${l.slot}s slot — retime or tighten`)
console.log(`done: ${manifest.length} lines → audio/vo/`)
