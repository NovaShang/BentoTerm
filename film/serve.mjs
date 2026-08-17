// Static server WITH HTTP Range support — the one thing `python3 -m
// http.server` lacks, and the thing that killed the stage: a <video> that
// seeks issues a Range request, python answers 200-whole-file instead of 206,
// and Chrome's media pipeline wedges at HAVE_METADATA forever. Idle preload
// (no seek) worked, which is why the landing page's videos never showed this.
//
//   node film/serve.mjs        → http://127.0.0.1:8899/film/
import { createServer } from 'node:http'
import { stat, createReadStream } from 'node:fs'
import { extname, join, normalize } from 'node:path'

const ROOT = new URL('..', import.meta.url).pathname   // bento-term/
const PORT = 8899
const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.mp4': 'video/mp4', '.mov': 'video/quicktime', '.mp3': 'audio/mpeg',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp',
  '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.json': 'application/json',
}

createServer((req, res) => {
  let path = decodeURIComponent(new URL(req.url, 'http://x').pathname)
  if (path.endsWith('/')) path += 'index.html'
  const file = join(ROOT, normalize(path).replace(/^(\.\.[/\\])+/, ''))
  stat(file, (err, st) => {
    if (err || !st.isFile()) { res.writeHead(404); return res.end('not found') }
    const type = MIME[extname(file).toLowerCase()] ?? 'application/octet-stream'
    const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? '')
    if (range && (range[1] || range[2])) {
      const start = range[1] ? parseInt(range[1]) : st.size - parseInt(range[2])
      const end = range[1] && range[2] ? parseInt(range[2]) : st.size - 1
      if (start >= st.size) { res.writeHead(416, { 'Content-Range': `bytes */${st.size}` }); return res.end() }
      res.writeHead(206, {
        'Content-Type': type, 'Accept-Ranges': 'bytes',
        'Content-Range': `bytes ${start}-${end}/${st.size}`, 'Content-Length': end - start + 1,
      })
      createReadStream(file, { start, end }).pipe(res)
    } else {
      res.writeHead(200, { 'Content-Type': type, 'Accept-Ranges': 'bytes', 'Content-Length': st.size })
      createReadStream(file).pipe(res)
    }
  })
}).listen(PORT, () => console.log(`serving ${ROOT} on :${PORT}`))
