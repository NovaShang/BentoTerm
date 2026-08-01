"use strict";
// File-preview renderer: code (hljs) + markdown (markdown-it). The native
// side calls bentoRender(payload) after the template loads; payload =
// {name, text, line, dark}. Content arrives as a JS value (JSON), never as
// interpolated HTML — everything we inject goes through hljs escaping, or
// markdown-it (html:true) whose output is scrubbed by DOMPurify + a no-network
// hook before it reaches the DOM.

const LANG_BY_EXT = {
  swift: "swift", go: "go", rs: "rust", py: "python", rb: "ruby",
  js: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  ts: "typescript", tsx: "typescript", java: "java", kt: "kotlin", kts: "kotlin",
  c: "c", h: "c", cpp: "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp", hh: "cpp",
  m: "objectivec", mm: "objectivec", cs: "csharp", php: "php",
  sh: "bash", bash: "bash", zsh: "bash", json: "json", jsonl: "json",
  yaml: "yaml", yml: "yaml", toml: "ini", ini: "ini", conf: "ini",
  xml: "xml", html: "xml", htm: "xml", svg: "xml", plist: "xml",
  css: "css", scss: "scss", less: "less", sql: "sql", diff: "diff",
  patch: "diff", lua: "lua", pl: "perl", r: "r", scala: "scala",
  dart: "dart", ex: "elixir", exs: "elixir", erl: "erlang",
  ps1: "powershell", tex: "latex", vim: "vim", gradle: "gradle",
  cmake: "cmake", proto: "protobuf", graphql: "graphql", tf: "ini",
  mk: "makefile", entitlements: "xml", strings: "swift", log: "plaintext",
};
const LANG_BY_NAME = {
  makefile: "makefile", gnumakefile: "makefile", dockerfile: "dockerfile",
  cmakelists_txt: "cmake",
};
const MARKDOWN_EXTS = new Set(["md", "markdown", "mdown", "mkd"]);
const HILIGHT_MAX = 200000;   // beyond this, plain text (hljs gets slow)
const AUTO_MAX = 60000;       // auto-detection budget for unknown extensions

function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function escapeAttr(s) {
  return escapeHtml(s).replace(/"/g, "&quot;");
}

function extOf(name) {
  const i = name.lastIndexOf(".");
  return i > 0 ? name.slice(i + 1).toLowerCase() : "";
}

function bentoSetTheme(dark) {
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  document.getElementById("hl-light").disabled = !!dark;
  document.getElementById("hl-dark").disabled = !dark;
}

function highlightedCode(name, text) {
  const lang = LANG_BY_EXT[extOf(name)]
    || LANG_BY_NAME[name.toLowerCase().replace(/\./g, "_")];
  if (text.length <= HILIGHT_MAX && lang && hljs.getLanguage(lang)) {
    try {
      return hljs.highlight(text, { language: lang, ignoreIllegals: true }).value;
    } catch (e) { /* fall through */ }
  }
  if (text.length <= AUTO_MAX && !lang) {
    try {
      const auto = hljs.highlightAuto(text);
      if (auto.relevance >= 5) { return auto.value; }
    } catch (e) { /* fall through */ }
  }
  return escapeHtml(text);
}

function renderCode(root, payload, allowJump) {
  const html = highlightedCode(payload.name, payload.text);
  const lineCount = payload.text.split("\n").length;
  let gutter = "";
  for (let i = 1; i <= lineCount; i++) { gutter += i + "\n"; }
  root.innerHTML =
    '<div class="code-wrap"><div id="linemark"></div>' +
    '<pre class="gutter">' + gutter + "</pre>" +
    '<pre class="code"><code class="hljs">' + html + "</code></pre></div>";

  if (payload.line && payload.line >= 1 && payload.line <= lineCount) {
    const codeEl = document.querySelector(".code");
    const lh = parseFloat(getComputedStyle(codeEl).lineHeight) || 18;
    const padTop = parseFloat(getComputedStyle(codeEl).paddingTop) || 8;
    const top = padTop + (payload.line - 1) * lh;
    const mark = document.getElementById("linemark");
    mark.style.top = top + "px";
    mark.style.height = lh + "px";
    mark.style.display = "block";
    if (allowJump) { window.scrollTo(0, Math.max(0, top - window.innerHeight / 3)); }
  }
}

const md = window.markdownit({
  html: true,           // render embedded HTML — sanitized by bentoSanitize()
  linkify: true,
  highlight: function (str, lang) {
    if (lang && hljs.getLanguage(lang)) {
      try {
        return hljs.highlight(str, { language: lang, ignoreIllegals: true }).value;
      } catch (e) { /* fall through */ }
    }
    return "";
  },
});
// Images: the page never touches the network, so http(s) sources show a quiet
// stub. File-relative sources (the normal markdown case — resolved against the
// FILE's own directory, not any root) become placeholders the native side
// reads through the pane's file source and fills in as data: URIs — this works
// for local AND remote (SSH) files alike.
md.renderer.rules.image = function (tokens, idx) {
  const t = tokens[idx];
  const src = (t.attrGet("src") || "").trim();
  const label = t.content || src || "image";
  if (!src || /^(https?|ftp|data):/i.test(src)) {
    if (/^data:image\//i.test(src)) {
      return '<img class="md-img" src="' + escapeAttr(src) + '" alt="' + escapeAttr(label) + '">';
    }
    return '<span class="img-stub">🖼 ' + escapeHtml(label) + "</span>";
  }
  return '<img class="md-img" data-bento-src="' + escapeAttr(src) +
         '" alt="' + escapeAttr(label) + '">';
};

// Native side: query which images the document wants, then fill each in.
function bentoWantedImages() {
  const out = [];
  document.querySelectorAll("img[data-bento-src]").forEach(function (el) {
    const s = el.getAttribute("data-bento-src");
    if (s && out.indexOf(s) < 0) { out.push(s); }
  });
  return out;
}

function bentoSetImage(src, dataURI) {
  document.querySelectorAll("img[data-bento-src]").forEach(function (el) {
    if (el.getAttribute("data-bento-src") === src) { el.src = dataURI; }
  });
}

function bentoFailImage(src) {
  document.querySelectorAll("img[data-bento-src]").forEach(function (el) {
    if (el.getAttribute("data-bento-src") !== src) { return; }
    const span = document.createElement("span");
    span.className = "img-stub";
    span.textContent = "🖼 " + (el.getAttribute("alt") || src);
    el.replaceWith(span);
  });
}

// Markdown may embed raw HTML (badges, <details>, <kbd>, <sub>, tables, …).
// markdown-it passes it through verbatim (html:true), so DOMPurify is what
// keeps it safe: it strips <script>, inline event handlers (onerror/onload…),
// javascript: URLs, and framing/embedding tags. The hook additionally severs
// EVERY remote resource load (src/srcset/poster/background/href-loaded), so the
// preview keeps its "never touches the network" guarantee — a hostile file
// can't phone home or exfiltrate its own contents. data: URIs stay.
if (window.DOMPurify) {
  DOMPurify.addHook("afterSanitizeAttributes", function (node) {
    if (!node.getAttribute) { return; }
    for (const attr of ["src", "srcset", "poster", "background"]) {
      const v = node.getAttribute(attr);
      if (!v || /^data:/i.test(v.trim())) { continue; }
      node.removeAttribute(attr);
      // Embedded-HTML <img> with a file-relative source joins the same
      // native fill pipeline as markdown images (remote stays severed).
      if (attr === "src" && node.tagName === "IMG"
          && !/^(https?|ftp):/i.test(v.trim())) {
        node.setAttribute("data-bento-src", v.trim());
        node.classList.add("md-img");
      }
    }
  });
}

function bentoSanitize(html) {
  // In the WebView DOMPurify is present; in the bare-JSContext asset test there
  // is no DOM (and no DOMPurify) — the render pipeline is exercised there, the
  // sanitizer only runs against a real DOM.
  if (!window.DOMPurify) { return html; }
  return DOMPurify.sanitize(html, {
    FORBID_TAGS: ["style", "iframe", "frame", "object", "embed", "link",
                  "base", "meta", "form", "input", "button", "textarea",
                  "select", "video", "audio", "source", "track", "svg", "math"],
    FORBID_ATTR: ["ping", "target"],
  });
}

function renderMarkdown(root, payload) {
  root.innerHTML = '<div class="markdown">' + bentoSanitize(md.render(payload.text)) + "</div>";
}

function bentoRender(payload) {
  bentoSetTheme(payload.dark);
  const root = document.getElementById("root");
  // A reload of the SAME file (a pinned preview watching an agent edit) keeps
  // the scroll position and skips the :line jump; a new file starts at the top.
  const sameFile = window.__bentoLastName === payload.name;
  const savedScroll = sameFile ? window.scrollY : 0;
  if (!sameFile) { window.scrollTo(0, 0); }
  try {
    if (MARKDOWN_EXTS.has(extOf(payload.name))) {
      renderMarkdown(root, payload);
    } else {
      renderCode(root, payload, !sameFile);
    }
  } catch (e) {
    // Never a blank panel: worst case is plain escaped text.
    root.innerHTML = '<pre class="code">' + escapeHtml(payload.text) + "</pre>";
  }
  window.__bentoLastName = payload.name;
  if (sameFile) { window.scrollTo(0, savedScroll); }
}
