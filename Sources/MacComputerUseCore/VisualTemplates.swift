// Ready-made live visuals. Each template is a small page driven entirely by
// `maccu.data` and `maccu.targets`, so an agent gets a finished, animated
// visual from one call and can restyle or advance it with update_visual.
import CoreGraphics
import Foundation

struct VisualTemplate {
    let name: String
    let summary: String
    let placement: VisualPlacement
    let size: CGSize
    let needsAnchor: Bool
    var interactive = false
    let body: String
}

/// Shared helpers every template page gets before its own script.
private let templatePrelude = #"""
<script>
const D = () => maccu.data || {};
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
const accent = () => D().color || "var(--mc-accent)";
// Runs render now and again only when maccu.data changes, so layout-only
// updates (resize, window moves) never restart entrance animations.
function onData(render) {
  let last = JSON.stringify(D()); render();
  maccu.on("update", () => { const k = JSON.stringify(D()); if (k !== last) { last = k; render(); } });
}
function fit(el, pad = 0) {
  requestAnimationFrame(() => {
    const r = el.getBoundingClientRect();
    maccu.resize(Math.ceil(r.width + pad), Math.ceil(r.height + pad));
  });
}
</script>
"""#

let visualTemplates: [String: VisualTemplate] = {
    let list = [
        VisualTemplate(
            name: "spotlight",
            summary: "Dims the screen except the anchor element, rings it, and shows data.title / data.text beside it.",
            placement: .screen,
            size: .zero,
            needsAnchor: true,
            body: #"""
<style>
#dim{position:fixed;inset:0;width:100%;height:100%}
#ring{position:absolute;border-radius:14px;border:2.5px solid var(--c);box-shadow:0 0 0 6px color-mix(in srgb,var(--c) 25%,transparent),0 0 40px var(--c);
animation:mc-pulse 1.8s ease-in-out infinite;transition:all .5s cubic-bezier(.2,.9,.25,1)}
#tip{position:absolute;max-width:340px;transition:all .5s cubic-bezier(.2,.9,.25,1)}
#hole{transition:all .5s cubic-bezier(.2,.9,.25,1)}
.fadein{animation:mc-fade .45s ease both}
</style>
<svg id="dim" class="fadein"><defs><mask id="m"><rect width="100%" height="100%" fill="white"/>
<rect id="hole" rx="14" fill="black"/></mask><filter id="f"><feGaussianBlur stdDeviation="6"/></filter></defs>
<rect width="100%" height="100%" fill="rgba(4,6,14,.62)" mask="url(#m)"/></svg>
<div id="ring"></div><div id="tip" class="mc-card"><div class="mc-title" id="t"></div><div class="mc-sub" id="x"></div></div>
<script>
function draw() {
  const a = maccu.targets.anchor; if (!a) return;
  const pad = D().padding ?? 10, d = D();
  document.documentElement.style.setProperty("--c", d.color || "#7c5cff");
  const hole = document.getElementById("hole"), ring = document.getElementById("ring"), tip = document.getElementById("tip");
  Object.entries({x:a.x-pad,y:a.y-pad,width:a.width+pad*2,height:a.height+pad*2}).forEach(([k,v]) => hole.setAttribute(k, v));
  Object.assign(ring.style, {left:(a.x-pad)+"px", top:(a.y-pad)+"px", width:(a.width+pad*2)+"px", height:(a.height+pad*2)+"px"});
  document.getElementById("t").innerHTML = esc(d.title || "");
  document.getElementById("x").innerHTML = esc(d.text || "");
  tip.style.display = d.title || d.text ? "" : "none";
  const W = innerWidth, H = innerHeight, tw = tip.offsetWidth, th = tip.offsetHeight, g = 22;
  let left = a.x + a.width + pad + g, top = a.cy - th / 2;
  if (left + tw > W - 12) left = a.x - pad - g - tw;
  if (left < 12) { left = Math.min(Math.max(a.cx - tw / 2, 12), W - tw - 12); top = a.y + a.height + pad + g; if (top + th > H - 12) top = a.y - pad - g - th; }
  tip.style.left = left + "px"; tip.style.top = Math.min(Math.max(top, 12), H - th - 12) + "px";
}
draw(); maccu.on("update", draw); addEventListener("resize", draw);
</script>
"""#
        ),
        VisualTemplate(
            name: "coach",
            summary: "A step card beside the anchor: data.step, data.total, data.title, data.body, data.hint. Points at the anchor.",
            placement: .beside,
            size: CGSize(width: 360, height: 210),
            needsAnchor: false,
            body: #"""
<style>
#wrap{position:absolute;padding:14px}
.card{position:relative;width:310px}
.dots{display:flex;gap:6px;margin-top:14px}.dot{width:7px;height:7px;border-radius:4px;background:rgba(255,255,255,.2);transition:all .4s}
.dot.on{width:22px;background:linear-gradient(90deg,var(--mc-accent),var(--mc-accent-2))}
.hint{margin-top:12px;font-size:12px;color:var(--mc-accent-2);display:flex;gap:6px;align-items:center}
.nub{position:absolute;width:16px;height:16px;background:var(--mc-glass);border:1px solid var(--mc-line);transform:rotate(45deg)}
</style>
<div id="wrap"><div class="mc-card card" id="card"></div></div>
<script>
function render() {
  const d = D(), total = d.total || 0, step = d.step || 0;
  const card = document.getElementById("card");
  card.innerHTML = `
    ${total ? `<div class="mc-pill">Step ${step} of ${total}</div>` : (d.badge ? `<div class="mc-pill">${esc(d.badge)}</div>` : "")}
    <div class="mc-title" style="margin-top:10px">${esc(d.title || "")}</div>
    <div class="mc-sub">${esc(d.body || "")}</div>
    ${d.hint ? `<div class="hint">→ ${esc(d.hint)}</div>` : ""}
    ${total ? `<div class="dots">${Array.from({length: total}, (_, i) => `<div class="dot ${i + 1 === step ? "on" : ""}"></div>`).join("")}</div>` : ""}
    <div class="nub" id="nub"></div>`;
  card.classList.remove("mc-in"); void card.offsetWidth; card.classList.add("mc-in");
  const nub = document.getElementById("nub"), s = maccu.side;
  const place = {left:{left:"-9px",top:"50%"},right:{right:"-9px",top:"50%"},top:{top:"-9px",left:"50%"},bottom:{bottom:"-9px",left:"50%"}}[s];
  if (place) Object.assign(nub.style, place, {marginTop: s === "left" || s === "right" ? "-8px" : "", marginLeft: s === "top" || s === "bottom" ? "-8px" : ""});
  else nub.remove();
  fit(document.getElementById("wrap"));
}
onData(render);
</script>
"""#
        ),
        VisualTemplate(
            name: "checklist",
            summary: "A live task list: data.title and data.items (strings or {text, done}); data.current highlights one. Update data to tick items off.",
            placement: .center,
            size: CGSize(width: 340, height: 300),
            needsAnchor: false,
            body: #"""
<style>
#wrap{position:absolute;padding:12px}
.card{width:300px}
.item{display:flex;gap:10px;align-items:flex-start;padding:8px 0;font-size:14px;border-top:1px solid rgba(255,255,255,.06);transition:opacity .3s}
.item:first-of-type{border-top:0}
.box{flex:none;width:18px;height:18px;border-radius:6px;border:1.5px solid rgba(255,255,255,.35);display:grid;place-items:center;transition:all .35s cubic-bezier(.2,.9,.25,1.4)}
.done .box{background:var(--mc-ok);border-color:var(--mc-ok);transform:scale(1.08)}
.done .txt{color:var(--mc-dim);text-decoration:line-through;text-decoration-color:rgba(255,255,255,.3)}
.cur .box{border-color:var(--mc-accent);box-shadow:0 0 12px var(--mc-accent)}
.cur .txt{font-weight:600}
.bar{height:4px;border-radius:2px;background:rgba(255,255,255,.08);margin:10px 0 6px;overflow:hidden}
.fill{height:100%;background:linear-gradient(90deg,var(--mc-ok),var(--mc-accent-2));transition:width .6s cubic-bezier(.2,.9,.25,1)}
</style>
<div id="wrap"><div class="mc-card card mc-in"><div class="mc-title" id="t"></div><div class="bar"><div class="fill" id="fill"></div></div><div id="list"></div></div></div>
<script>
function render() {
  const d = D(), items = (d.items || []).map(i => typeof i === "string" ? {text: i} : i);
  document.getElementById("t").textContent = d.title || "Checklist";
  const done = items.filter(i => i.done).length;
  document.getElementById("fill").style.width = (items.length ? done / items.length * 100 : 0) + "%";
  const list = document.getElementById("list"), prev = [...list.children].map(c => c.classList.contains("done"));
  list.innerHTML = items.map((i, n) => `<div class="item ${i.done ? "done" : ""} ${n === d.current ? "cur" : ""}">
    <div class="box">${i.done ? `<svg width="11" height="11" viewBox="0 0 12 12"><path d="M2 6.5l2.6 2.6L10 3.4" stroke="#06281c" stroke-width="2.2" fill="none" stroke-linecap="round" class="mc-draw" style="--mc-len:14"/></svg>` : ""}</div>
    <div class="txt">${esc(i.text)}</div></div>`).join("");
  [...list.children].forEach((c, n) => { if (items[n].done && prev[n]) c.querySelector("path")?.classList.remove("mc-draw"); });
  fit(document.getElementById("wrap"));
}
onData(render);
</script>
"""#
        ),
        VisualTemplate(
            name: "keycaps",
            summary: "Animated keyboard shortcut: data.keys as [\"⌘\",\"Shift\",\"4\"] or \"cmd+shift+4\", optional data.caption. Keys press in sequence.",
            placement: .center,
            size: CGSize(width: 560, height: 190),
            needsAnchor: false,
            body: #"""
<style>
body{display:grid;place-items:center}
#wrap{display:flex;flex-direction:column;align-items:center;gap:14px;padding:18px}
.row{display:flex;gap:12px;align-items:center}
.key{min-width:62px;height:62px;padding:0 16px;box-sizing:border-box;border-radius:14px;display:grid;place-items:center;font-size:24px;font-weight:600;
background:linear-gradient(180deg,#3a3f52,#232736);border:1px solid rgba(255,255,255,.14);
box-shadow:0 6px 0 #11131b,0 14px 30px rgba(0,0,0,.45),inset 0 1px 0 rgba(255,255,255,.15);transition:all .12s;animation:mc-rise .45s both}
.key.down{transform:translateY(5px);box-shadow:0 1px 0 #11131b,0 0 28px var(--mc-accent),inset 0 1px 0 rgba(255,255,255,.15);border-color:var(--mc-accent)}
.plus{color:var(--mc-dim);font-size:20px}
.cap{font-size:15px;color:var(--mc-ink);background:var(--mc-glass);border:1px solid var(--mc-line);padding:7px 14px;border-radius:999px}
</style>
<div id="wrap"><div class="row" id="row"></div><div class="cap" id="cap"></div></div>
<script>
const names = {cmd:"⌘",command:"⌘",shift:"⇧",opt:"⌥",option:"⌥",alt:"⌥",ctrl:"⌃",control:"⌃",return:"↩",enter:"↩",tab:"⇥",esc:"esc",escape:"esc",
  delete:"⌫",backspace:"⌫",space:"space",up:"↑",down:"↓",left:"←",right:"→",fn:"fn",caps:"⇪"};
let timer;
function render() {
  const d = D(); let keys = d.keys || [];
  if (typeof keys === "string") keys = keys.split(/\s*\+\s*/);
  keys = keys.map(k => names[String(k).toLowerCase()] || (String(k).length === 1 ? String(k).toUpperCase() : k));
  const row = document.getElementById("row");
  row.innerHTML = keys.map((k, i) => `${i ? '<span class="plus">+</span>' : ""}<div class="key" style="animation-delay:${i * .07}s">${esc(k)}</div>`).join("");
  const cap = document.getElementById("cap"); cap.textContent = d.caption || ""; cap.style.display = d.caption ? "" : "none";
  clearInterval(timer);
  const els = [...row.querySelectorAll(".key")];
  const press = () => { els.forEach((e, i) => setTimeout(() => e.classList.add("down"), 250 + i * 180));
    setTimeout(() => els.forEach(e => e.classList.remove("down")), 250 + els.length * 180 + 700); };
  setTimeout(press, 400); if (!maccu.reduceMotion && d.loop !== false) timer = setInterval(press, 2600);
}
onData(render);
</script>
"""#
        ),
        VisualTemplate(
            name: "confetti",
            summary: "A full-screen celebration burst from the anchor (or screen centre) with an optional big data.message. Clears itself.",
            placement: .screen,
            size: .zero,
            needsAnchor: false,
            body: #"""
<style>
canvas{position:fixed;inset:0}
#msg{position:fixed;left:50%;top:38%;transform:translate(-50%,-50%);font-size:54px;font-weight:800;letter-spacing:-.02em;text-align:center;
filter:drop-shadow(0 8px 30px rgba(124,92,255,.55));animation:pop 1s cubic-bezier(.2,1.4,.3,1) both}
@keyframes pop{0%{opacity:0;transform:translate(-50%,-40%) scale(.6)}100%{opacity:1;transform:translate(-50%,-50%) scale(1)}}
</style>
<canvas id="c"></canvas><div id="msg" class="mc-gradient-text"></div>
<script>
const c = document.getElementById("c"), x = c.getContext("2d"), dpr = devicePixelRatio || 1;
c.width = innerWidth * dpr; c.height = innerHeight * dpr; x.scale(dpr, dpr);
const d = D(), a = maccu.targets.anchor, ox = a ? a.cx : innerWidth / 2, oy = a ? a.cy : innerHeight * .45;
document.getElementById("msg").textContent = d.message || "";
const colors = d.colors || ["#7c5cff", "#22d3ee", "#ff4d8d", "#fbbf24", "#34d399", "#ffffff"];
const N = maccu.reduceMotion ? 0 : (d.count || 220);
const P = Array.from({length: N}, () => { const ang = Math.random() * Math.PI * 2, sp = 6 + Math.random() * 14;
  return {x: ox, y: oy, vx: Math.cos(ang) * sp, vy: Math.sin(ang) * sp - 8, r: 4 + Math.random() * 6, rot: Math.random() * 6,
          vr: (Math.random() - .5) * .4, c: colors[Math.random() * colors.length | 0], s: Math.random() < .3 ? "c" : "r", life: 0}; });
let t0 = performance.now();
(function frame(now) {
  x.clearRect(0, 0, innerWidth, innerHeight);
  for (const p of P) { p.vy += .32; p.vx *= .985; p.vy *= .985; p.x += p.vx; p.y += p.vy; p.rot += p.vr; p.life++;
    x.save(); x.translate(p.x, p.y); x.rotate(p.rot); x.globalAlpha = Math.max(0, 1 - p.life / 240); x.fillStyle = p.c;
    if (p.s === "c") { x.beginPath(); x.arc(0, 0, p.r / 2, 0, 7); x.fill(); } else x.fillRect(-p.r / 2, -p.r / 4, p.r, p.r / 2);
    x.restore(); }
  if (now - t0 < (d.duration_ms || 4200)) requestAnimationFrame(frame); else maccu.close();
})(t0);
</script>
"""#
        ),
        VisualTemplate(
            name: "chart",
            summary: "An animated chart: data.type bar|line|donut, data.labels, data.values, optional data.title, data.unit, data.highlight (index).",
            placement: .center,
            size: CGSize(width: 460, height: 300),
            needsAnchor: false,
            body: #"""
<style>
#wrap{position:absolute;inset:0;padding:12px;box-sizing:border-box}
.card{height:100%;box-sizing:border-box;display:flex;flex-direction:column}
svg{flex:1;width:100%;overflow:visible}
.lbl{fill:var(--mc-dim);font-size:11px}.val{fill:var(--mc-ink);font-size:11px;font-weight:600}
.bar{transform-box:fill-box;transform-origin:bottom;animation:grow .8s cubic-bezier(.2,.9,.25,1) both}
@keyframes grow{from{transform:scaleY(0)}}
.seg{animation:mc-fade .6s both}
</style>
<div id="wrap"><div class="mc-card card mc-in"><div class="mc-title" id="t"></div><div class="mc-sub" id="s"></div><svg id="g"></svg></div></div>
<script>
const pal = ["#7c5cff", "#22d3ee", "#ff4d8d", "#fbbf24", "#34d399", "#a78bfa", "#f472b6", "#60a5fa"];
function render() {
  const d = D(), v = (d.values || []).map(Number), L = d.labels || v.map((_, i) => i + 1), u = d.unit || "";
  document.getElementById("t").textContent = d.title || ""; document.getElementById("s").textContent = d.subtitle || "";
  const g = document.getElementById("g"), W = g.clientWidth || 400, H = g.clientHeight || 200, max = Math.max(...v, 0) || 1;
  const fmt = n => (Math.abs(n) >= 1000 ? (n / 1000).toFixed(1) + "k" : +n.toFixed(2)) + u;
  let s = "";
  if (d.type === "donut") {
    const tot = v.reduce((a, b) => a + b, 0) || 1, r = Math.min(W * .28, H / 2 - 8), cx = r + 8, cy = H / 2; let a0 = -Math.PI / 2;
    v.forEach((n, i) => { const a1 = a0 + n / tot * Math.PI * 2, big = a1 - a0 > Math.PI ? 1 : 0;
      const p = (a, rr) => [cx + Math.cos(a) * rr, cy + Math.sin(a) * rr];
      const [x0, y0] = p(a0, r), [x1, y1] = p(a1, r), [x2, y2] = p(a1, r * .62), [x3, y3] = p(a0, r * .62);
      s += `<path class="seg" style="animation-delay:${i * .08}s" fill="${pal[i % 8]}" opacity="${d.highlight == null || d.highlight === i ? 1 : .35}"
        d="M${x0},${y0}A${r},${r} 0 ${big} 1 ${x1},${y1}L${x2},${y2}A${r * .62},${r * .62} 0 ${big} 0 ${x3},${y3}Z"/>`;
      s += `<circle cx="${2 * r + 34}" cy="${16 + i * 20}" r="5" fill="${pal[i % 8]}"/><text class="lbl" x="${2 * r + 46}" y="${20 + i * 20}">${esc(L[i])} · <tspan class="val">${fmt(n)}</tspan></text>`;
      a0 = a1; });
  } else if (d.type === "line") {
    const step = v.length > 1 ? W / (v.length - 1) : W, y = n => H - 18 - n / max * (H - 36);
    const pts = v.map((n, i) => [i * step, y(n)]), path = pts.map((p, i) => (i ? "L" : "M") + p.join(",")).join("");
    s += `<defs><linearGradient id="lg" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="#7c5cff" stop-opacity=".45"/><stop offset="1" stop-color="#7c5cff" stop-opacity="0"/></linearGradient></defs>`;
    s += `<path d="${path}L${W},${H - 18}L0,${H - 18}Z" fill="url(#lg)" class="seg"/>`;
    s += `<path d="${path}" fill="none" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" class="mc-draw" style="--mc-len:${W * 2}" stroke="#22d3ee"/>`;
    pts.forEach(([px, py], i) => { s += `<circle cx="${px}" cy="${py}" r="${d.highlight === i ? 6 : 3.5}" fill="${d.highlight === i ? "#ff4d8d" : "#22d3ee"}" class="seg" style="animation-delay:${.6 + i * .05}s"/>`;
      s += `<text class="lbl" x="${px}" y="${H}" text-anchor="middle">${esc(L[i])}</text>`; });
  } else {
    const n = v.length || 1, gap = 10, bw = (W - gap * (n - 1)) / n;
    v.forEach((val, i) => { const h = val / max * (H - 40), x = i * (bw + gap);
      const fill = d.highlight == null || d.highlight === i ? `url(#bg${i % 2})` : "rgba(255,255,255,.14)";
      s += `<rect class="bar" style="animation-delay:${i * .06}s" x="${x}" y="${H - 18 - h}" width="${bw}" height="${h}" rx="6" fill="${fill}"/>`;
      s += `<text class="val" x="${x + bw / 2}" y="${H - 24 - h}" text-anchor="middle">${fmt(val)}</text><text class="lbl" x="${x + bw / 2}" y="${H}" text-anchor="middle">${esc(L[i])}</text>`; });
    s = `<defs><linearGradient id="bg0" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="#8b6dff"/><stop offset="1" stop-color="#5b3df0"/></linearGradient>
         <linearGradient id="bg1" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="#2ee6ff"/><stop offset="1" stop-color="#0ea5c6"/></linearGradient></defs>` + s;
  }
  g.innerHTML = s;
}
render(); maccu.on("update", render); addEventListener("resize", render);
</script>
"""#
        ),
        VisualTemplate(
            name: "model3d",
            summary: "A live 3D scene the user can drag to orbit and scroll to zoom: data.parts [{shape: box|sphere|cylinder|cone|torus|torusknot|capsule|plane, size: [x,y,z] or radius, position: [x,y,z], rotation: [x,y,z] degrees, color, metalness, roughness, opacity, label}] and/or data.url (a .glb/.gltf model), data.title, data.caption, data.autorotate (default true), data.highlight (part label to glow). Labelled parts get pinned callouts.",
            placement: .center,
            size: CGSize(width: 560, height: 440),
            needsAnchor: false,
            interactive: true,
            body: #"""
<style>
#stage{position:absolute;inset:10px;border-radius:20px;overflow:hidden;background:radial-gradient(120% 90% at 50% 0%,rgba(124,92,255,.22),rgba(10,12,22,.9) 60%);
border:1px solid var(--mc-line);box-shadow:0 30px 80px rgba(0,0,0,.5);animation:mc-pop .5s cubic-bezier(.2,.9,.25,1.2) both;cursor:grab}
#stage:active{cursor:grabbing}
canvas{display:block}
#head{position:absolute;left:28px;top:24px;pointer-events:none}
#cap{position:absolute;left:28px;right:28px;bottom:22px;pointer-events:none;font-size:13px;color:var(--mc-dim)}
.tag{position:absolute;transform:translate(-50%,-100%);pointer-events:none;white-space:nowrap;font-size:12px;font-weight:600;padding:4px 9px;border-radius:999px;
background:rgba(14,16,28,.82);border:1px solid var(--mc-line);transition:opacity .2s}
.tag.hot{border-color:var(--mc-accent);box-shadow:0 0 16px var(--mc-accent)}
.tag:after{content:"";position:absolute;left:50%;top:100%;width:1px;height:14px;background:rgba(255,255,255,.45)}
#hint{position:absolute;right:24px;top:26px;font-size:11px;color:var(--mc-dim);pointer-events:none}
#err{position:absolute;inset:0;display:none;place-items:center;color:var(--mc-hot);font-size:13px}
</style>
<div id="stage"><div id="head"><div class="mc-title" id="t"></div></div><div id="hint">drag to rotate · scroll to zoom</div><div id="cap"></div><div id="tags"></div><div id="err"></div></div>
<script type="importmap">{"imports":{"three":"https://cdn.jsdelivr.net/npm/three@0.170.0/build/three.module.js","three/addons/":"https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/"}}</script>
<script type="module">
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
const stage = document.getElementById("stage");
const renderer = new THREE.WebGLRenderer({antialias: true, alpha: true});
renderer.setPixelRatio(devicePixelRatio); renderer.toneMapping = THREE.ACESFilmicToneMapping; renderer.outputColorSpace = THREE.SRGBColorSpace;
stage.prepend(renderer.domElement);
const scene = new THREE.Scene();
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;
const camera = new THREE.PerspectiveCamera(38, 1, 0.01, 1000);
const key = new THREE.DirectionalLight(0xffffff, 1.6); key.position.set(3, 5, 4); scene.add(key);
scene.add(new THREE.HemisphereLight(0xb8a8ff, 0x101020, 0.6));
const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true; controls.dampingFactor = 0.08; controls.autoRotateSpeed = 1.4;
const root = new THREE.Group(); scene.add(root);
const floor = new THREE.Mesh(new THREE.CircleGeometry(1, 64), new THREE.MeshBasicMaterial({color: 0x7c5cff, transparent: true, opacity: .08}));
floor.rotation.x = -Math.PI / 2; scene.add(floor);
let tags = [];
const geo = (p) => {
  const s = p.size ?? 1, v = Array.isArray(s) ? s : [s, s, s];
  switch (p.shape) {
    case "sphere": return new THREE.SphereGeometry(v[0] / (Array.isArray(s) ? 2 : 1), 64, 32);
    case "cylinder": return new THREE.CylinderGeometry(v[0] / 2, v[0] / 2, v[1], 64);
    case "cone": return new THREE.ConeGeometry(v[0] / 2, v[1], 64);
    case "torus": return new THREE.TorusGeometry(v[0] / 2, (v[1] ?? v[0]) / 8, 32, 96);
    case "torusknot": return new THREE.TorusKnotGeometry(v[0] / 3, v[0] / 10, 200, 24);
    case "capsule": return new THREE.CapsuleGeometry(v[0] / 2, v[1], 12, 32);
    case "plane": return new THREE.PlaneGeometry(v[0], v[1]);
    default: return new THREE.BoxGeometry(v[0], v[1], v[2], 4, 4, 4);
  }
};
function clear() { while (root.children.length) root.remove(root.children[0]); tags.forEach(t => t.el.remove()); tags = []; }
function frame() {
  const box = new THREE.Box3().setFromObject(root); if (box.isEmpty()) return;
  const size = box.getSize(new THREE.Vector3()).length(), center = box.getCenter(new THREE.Vector3());
  controls.target.copy(center); camera.near = size / 100; camera.far = size * 100; camera.updateProjectionMatrix();
  camera.position.copy(center).add(new THREE.Vector3(0.9, 0.6, 1.2).normalize().multiplyScalar(size * 1.85));
  floor.position.set(center.x, box.min.y - size * 0.01, center.z); floor.scale.setScalar(size * 0.34);
}
function addTag(label, object, local) {
  const el = document.createElement("div"); el.className = "tag"; el.textContent = label;
  document.getElementById("tags").appendChild(el); tags.push({el, object, local: local || new THREE.Vector3(), label});
}
function build() {
  const d = D(); clear();
  document.getElementById("t").textContent = d.title || ""; document.getElementById("cap").textContent = d.caption || "";
  controls.autoRotate = d.autorotate !== false && !maccu.reduceMotion;
  for (const p of d.parts || []) {
    const mat = new THREE.MeshPhysicalMaterial({color: new THREE.Color(p.color || "#8b7bff"), metalness: p.metalness ?? .2, roughness: p.roughness ?? .35,
      clearcoat: .4, transparent: (p.opacity ?? 1) < 1, opacity: p.opacity ?? 1, side: THREE.DoubleSide});
    if (p.label && d.highlight === p.label) { mat.emissive = new THREE.Color(p.color || "#7c5cff"); mat.emissiveIntensity = .55; }
    const mesh = new THREE.Mesh(geo(p), mat);
    mesh.position.fromArray(p.position || [0, 0, 0]);
    if (p.rotation) mesh.rotation.set(...p.rotation.map(a => a * Math.PI / 180));
    root.add(mesh);
    if (p.label) { const b = new THREE.Box3().setFromObject(mesh); addTag(p.label, mesh, new THREE.Vector3(0, (b.max.y - b.min.y) / 2, 0)); }
  }
  if (d.url) {
    new GLTFLoader().load(d.url, (g) => { root.add(g.scene); frame(); maccu.send({loaded: d.url}); },
      undefined, (e) => { const el = document.getElementById("err"); el.style.display = "grid"; el.textContent = "Couldn't load model"; maccu._error(e); });
  }
  if (!(d.parts || []).length && !d.url) root.add(new THREE.Mesh(new THREE.TorusKnotGeometry(.5, .16, 220, 28), new THREE.MeshPhysicalMaterial({color: "#8b7bff", metalness: .3, roughness: .2, clearcoat: 1})));
  frame();
}
function size() { const r = stage.getBoundingClientRect(); renderer.setSize(r.width, r.height, false); renderer.domElement.style.width = r.width + "px";
  renderer.domElement.style.height = r.height + "px"; camera.aspect = r.width / r.height; camera.updateProjectionMatrix(); }
const v = new THREE.Vector3();
renderer.setAnimationLoop(() => {
  controls.update(); renderer.render(scene, camera);
  const r = stage.getBoundingClientRect();
  for (const t of tags) { v.copy(t.local); t.object.localToWorld(v); v.project(camera);
    t.el.style.left = ((v.x + 1) / 2 * r.width) + "px"; t.el.style.top = ((1 - v.y) / 2 * r.height - 14) + "px";
    t.el.style.opacity = v.z < 1 ? 1 : 0; t.el.classList.toggle("hot", D().highlight === t.label); }
});
renderer.domElement.addEventListener("pointerdown", () => { controls.autoRotate = false; maccu.send({interacted: true}); });
size(); build(); addEventListener("resize", size);
let last = JSON.stringify(D()); maccu.on("update", () => { size(); const k = JSON.stringify(D()); if (k !== last) { last = k; build(); } });
window.three = {THREE, scene, camera, root, controls, renderer};
</script>
"""#
        ),
        VisualTemplate(
            name: "compare",
            summary: "Before / after side by side: data.before and data.after, each {title, text} or {title, items: [...]}, plus optional data.title.",
            placement: .center,
            size: CGSize(width: 620, height: 280),
            needsAnchor: false,
            body: #"""
<style>
#wrap{position:absolute;padding:12px}
.top{font-size:13px;color:var(--mc-dim);margin:0 0 10px 4px;font-weight:600;letter-spacing:.04em;text-transform:uppercase}
.cols{display:flex;gap:14px;align-items:stretch}
.col{width:250px}.col.after{border-color:color-mix(in srgb,var(--mc-ok) 50%,transparent);box-shadow:0 0 0 1px rgba(52,211,153,.25),0 24px 60px rgba(0,0,0,.45)}
.tag{font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;margin-bottom:8px}
.before .tag{color:var(--mc-hot)}.after .tag{color:var(--mc-ok)}
.arrow{align-self:center;font-size:26px;color:var(--mc-dim);animation:mc-rise .6s .2s both}
ul{margin:8px 0 0;padding-left:18px}li{font-size:13px;color:var(--mc-dim);margin:4px 0}
</style>
<div id="wrap"><div class="top" id="t"></div><div class="cols" id="cols"></div></div>
<script>
function side(cls, label, s) { s = s || {}; return `<div class="mc-card col ${cls}"><div class="tag">${label}</div><div class="mc-title">${esc(s.title || "")}</div>
  ${s.text ? `<div class="mc-sub">${esc(s.text)}</div>` : ""}${s.items ? `<ul>${s.items.map(i => `<li>${esc(i)}</li>`).join("")}</ul>` : ""}</div>`; }
function render() { const d = D(); document.getElementById("t").textContent = d.title || "";
  document.getElementById("cols").innerHTML = side("before", d.before_label || "Before", d.before) + `<div class="arrow">→</div>` + side("after", d.after_label || "After", d.after);
  document.querySelector(".after").style.animationDelay = ".15s"; fit(document.getElementById("wrap")); }
onData(render);
</script>
"""#
        ),
    ]
    return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
}()

/// Builds a template page, with the agent's optional extra HTML (styles or
/// scripts) appended after the template's own.
func visualTemplatePage(_ template: VisualTemplate, extra: String?) -> String {
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(template.name)</title></head><body>"
        + templatePrelude + template.body + (extra ?? "") + "</body></html>"
}
