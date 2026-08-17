/**
 * Chinese VO for the v3 picture lock. The video's cut points were fitted to
 * the English track, so Chinese is generated PER LINE and each clip is placed
 * at a fixed film time — line 6 is split so 「更重要的是」 lands exactly on the
 * shell→agent cut at 32.3s. Slot = time to the next line (overrun warns).
 *
 *   node gen-vo-zh.mjs                    # all lines + mixed 71s track
 *   node gen-vo-zh.mjs 3 7               # regenerate specific lines, remix
 */
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

const VOICE = 'Chinese (Mandarin)_Radio_Host'
const TOTAL = 71.0

// [film time, max slot, subtitle text, tts text (optional)]
export const zh = [
  [1.0, 4.7, '你的 agent 正忙着。那你呢？', '你的 agent 正忙着。<#0.6#>那你呢？'],
  [5.9, 1.9, '那就多开几个。'],
  [7.9, 5.2, 'Bento Term 把所有 agent 装进一个窗口，像便当盒一样。'],
  [13.25, 4.7, '每个格子在干什么，一眼看全，不用切来切去。'],
  [18.1, 3.4, '谁需要你，颜色会告诉你。'],
  [21.7, 5.6, '说话比打字快三倍。所以在 Bento，能说的就不用打。'],
  [27.5, 4.6, '对着 shell 说句话，命令就跑起来了。'],
  [32.3, 3.0, '更重要的是，还能这样指挥 agent。'],
  [35.45, 5.2, 'Bento 听得懂上下文，术语、代码里的名字，都一字不差。'],
  [44.9, 3.1, '合上电脑，agent 也不会停。'],
  [48.05, 4.5, '窝在沙发里，用 iPad 接着干，一样都不缺。'],
  [52.9, 4.8, '人在路上，手机也能把事办完。'],
  [57.95, 7.2, '并行、语音、远程。其实是同一种工作方式，效率成倍地涨。',
    '并行、<#0.3#>语音、<#0.3#>远程。<#0.5#>其实是同一种工作方式，效率成倍地涨。'],
]

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

async function tts(text) {
  const res = await fetch('https://api.minimax.io/v1/t2a_v2', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
    body: JSON.stringify({
      model: 'speech-02-hd', text,
      voice_setting: { voice_id: VOICE, speed: 1.0, vol: 1.0, pitch: 0 },
      audio_setting: { format: 'mp3', sample_rate: 44100, bitrate: 128000 },
    }),
  })
  const json = await res.json()
  if (json.base_resp?.status_code !== 0) throw new Error(`${json.base_resp?.status_code} ${json.base_resp?.status_msg}`)
  return Buffer.from(json.data.audio, 'hex')
}

const outDir = new URL('./audio/vo/zh/', import.meta.url)
await mkdir(outDir, { recursive: true })
const only = process.argv.slice(2).map(Number)

for (let i = 0; i < zh.length; i++) {
  const name = `line-${String(i).padStart(2, '0')}.mp3`
  const path = new URL(name, outDir)
  if (!only.length || only.includes(i)) {
    process.stdout.write(`${name} “${zh[i][2].slice(0, 18)}…” `)
    await writeFile(path, await tts(zh[i][3] ?? zh[i][2]))
    console.log('✓')
    await new Promise(r => setTimeout(r, 300))
  }
  const dur = parseFloat(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration',
    '-of', 'csv=p=0', path.pathname]).toString())
  const flag = dur > zh[i][1] + 0.1 ? `  ⚠ ${dur.toFixed(1)}s in ${zh[i][1]}s slot` : ''
  console.log(`  L${i} @${zh[i][0]}s  ${dur.toFixed(2)}s / ${zh[i][1]}s${flag}`)
}

// mix: each clip delayed to its film time over a 71s bed
const inputs = zh.map((_, i) => `-i audio/vo/zh/line-${String(i).padStart(2, '0')}.mp3`).join(' ')
const delays = zh.map((l, i) => `[${i}:a]adelay=${Math.round(l[0] * 1000)}|${Math.round(l[0] * 1000)}[d${i}]`).join(';')
const mix = zh.map((_, i) => `[d${i}]`).join('') + `amix=inputs=${zh.length}:normalize=0,apad=whole_dur=${TOTAL}`
const cmd = `ffmpeg -y -loglevel error ${inputs} -filter_complex "${delays};${mix}" -ac 2 -t ${TOTAL} audio/vo/zh-track.wav`
await writeFile('mix-zh.sh', `#!/bin/zsh\nset -e\ncd "$(dirname "$0")"\n${cmd}\n`)
execFileSync('zsh', ['mix-zh.sh'], { stdio: 'inherit' })
console.log('→ audio/vo/zh-track.wav')