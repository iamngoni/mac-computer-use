/**
 * mcu.iamngoni.dev effects. The visitor's own pointer becomes the app's agent
 * cursor: the tip tracks the mouse exactly (no lag), while the art leans into
 * the direction of travel, swells with speed and leaves the same glowing
 * 0.42 s trail as the app. Clicks ripple like the app's click ring. Touch and
 * reduced-motion visitors keep the system cursor and get static styling.
 */
(() => {
  "use strict";
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fine = matchMedia("(hover: hover) and (pointer: fine)").matches;
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const root = document.documentElement;

  /* ---------- Scroll-lit statement: words light up as you read. ---------- */
  const st = document.querySelector(".statement p");
  if (st) {
    const wrap = (node) => {
      [...node.childNodes].forEach((n) => {
        if (n.nodeType === 3) {
          const frag = document.createDocumentFragment();
          n.textContent.split(/(\s+)/).forEach((w) => {
            if (!w) return;
            if (/^\s+$/.test(w)) return frag.append(w);
            const s = document.createElement("span"); s.className = "w"; s.textContent = w; frag.append(s);
          });
          n.replaceWith(frag);
        } else if (n.nodeType === 1) wrap(n);
      });
    };
    wrap(st);
    const words = $$(".w", st);
    st.classList.add("lit");
    const light = () => {
      const r = st.getBoundingClientRect(), vh = innerHeight;
      const p = Math.min(Math.max((vh * 0.85 - r.top) / (r.height + vh * 0.35), 0), 1);
      const n = Math.round(p * words.length);
      words.forEach((w, i) => w.classList.toggle("on", reduce || i < n));
    };
    addEventListener("scroll", light, { passive: true }); light();
  }

  /* ---------- Sketch settles flat as it scrolls in. ---------- */
  const sketch = document.getElementById("sketch");
  if (sketch && !reduce) {
    const tilt = () => {
      const r = sketch.getBoundingClientRect();
      const p = Math.min(Math.max((innerHeight - r.top) / (innerHeight * 0.75), 0), 1);
      sketch.style.setProperty("--tilt", `${(1 - p) * 18}deg`);
      sketch.style.setProperty("--sk", `${1 - (1 - p) * 0.06}`);
    };
    addEventListener("scroll", tilt, { passive: true }); tilt();
  }

  if (!fine || reduce) return;
  root.classList.add("fx");

  /* ---------- The cursor. ---------- */
  const cv = document.createElement("canvas"); cv.className = "fx-trail"; cv.setAttribute("aria-hidden", "true");
  const cur = document.createElement("div"); cur.className = "fx-cur"; cur.setAttribute("aria-hidden", "true");
  cur.innerHTML = '<img src="/cursor.png" alt=""><i class="fx-beam"></i><b class="fx-tag"></b>';
  const halo = document.createElement("div"); halo.className = "fx-halo"; halo.setAttribute("aria-hidden", "true");
  document.body.append(cv, halo, cur);
  const img = cur.querySelector("img"), tag = cur.querySelector(".fx-tag");
  const ctx = cv.getContext("2d");
  const TIP = { x: 16 / 84, y: 15 / 84 }, SIZE = 26, REST = Math.atan2(-1, -1), ACCENT = "61,170,255";
  img.style.transformOrigin = `${TIP.x * 100}% ${TIP.y * 100}%`;

  let W = 0, H = 0, dpr = 1;
  const size = () => { W = innerWidth; H = innerHeight; dpr = Math.min(devicePixelRatio || 1, 2); cv.width = W * dpr; cv.height = H * dpr; };
  addEventListener("resize", size); size();

  let x = -100, y = -100, px = x, py = y, vx = 0, vy = 0, rot = 0, sc = 1, seen = false;
  let trail = [], mode = "", hx = x, hy = y;

  addEventListener("pointermove", (e) => {
    if (e.pointerType !== "mouse") return;
    x = e.clientX; y = e.clientY;
    if (!seen) { seen = true; px = hx = x; py = hy = y; root.classList.add("fx-on"); }
    root.style.setProperty("--mx", `${x}px`); root.style.setProperty("--my", `${y}px`);
  }, { passive: true });
  document.addEventListener("pointerleave", () => root.classList.remove("fx-on"));
  document.addEventListener("pointerenter", () => seen && root.classList.add("fx-on"));

  // What's under the pointer decides the cursor's mood.
  const label = (el) => el.closest("[data-cur]")?.dataset.cur || "";
  document.addEventListener("pointerover", (e) => {
    const t = e.target;
    let m = "";
    if (t.closest("pre, input, textarea, .typed")) m = "text";
    else if (t.closest("a, button, summary, [role=tab], .copy")) m = "link";
    else if (t.closest(".desk")) m = "desk";
    mode = m;
    cur.dataset.mode = m; root.dataset.cmode = m;
    const l = m === "link" ? label(t) : m === "desk" ? "agent's turn — yours is free" : "";
    tag.textContent = l; cur.classList.toggle("tagged", !!l);
  });

  const ripple = (cx, cy) => {
    const r = document.createElement("i"); r.className = "fx-ring";
    r.style.left = `${cx}px`; r.style.top = `${cy}px`;
    document.body.append(r); r.addEventListener("animationend", () => r.remove());
  };
  addEventListener("pointerdown", (e) => { if (e.pointerType === "mouse") { cur.classList.add("down"); ripple(e.clientX, e.clientY); } });
  addEventListener("pointerup", () => cur.classList.remove("down"));

  const tick = (now) => {
    const dx = x - px, dy = y - py; px = x; py = y;
    vx += (dx - vx) * 0.25; vy += (dy - vy) * 0.25;
    const speed = Math.hypot(vx, vy);
    const w = Math.min(speed / 28, 1); // 0..1, how hard we're moving
    let turn = speed > 0.6 ? Math.atan2(vy, vx) - REST : 0;
    turn = Math.atan2(Math.sin(turn), Math.cos(turn));
    rot += (turn * w * 0.9 - rot) * 0.18;
    const target = (mode === "link" ? 1.18 : 1) + 0.3 * w;
    sc += (target - sc) * 0.2;
    cur.style.transform = `translate3d(${x}px, ${y}px, 0)`;
    img.style.transform = `translate(${-TIP.x * SIZE}px, ${-TIP.y * SIZE}px) rotate(${rot}rad) scale(${sc})`;
    hx += (x - hx) * 0.12; hy += (y - hy) * 0.12;
    halo.style.transform = `translate3d(${hx}px, ${hy}px, 0)`;

    if (seen && speed > 1.2 && mode !== "text") {
      const last = trail[trail.length - 1];
      if (!last || Math.hypot(last.x - x, last.y - y) > 1.5) trail.push({ x, y, t: now });
    }
    trail = trail.filter((p) => now - p.t <= 420);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H);
    if (trail.length >= 2) {
      ctx.lineCap = "round"; ctx.lineJoin = "round";
      ctx.shadowColor = `rgba(${ACCENT},.9)`; ctx.shadowBlur = 8;
      for (let i = 1; i < trail.length; i++) {
        const a = 1 - (now - trail[i].t) / 420;
        ctx.globalAlpha = Math.max(a, 0) * 0.9;
        ctx.lineWidth = 1 + 3.5 * a;
        ctx.strokeStyle = `rgba(${ACCENT},1)`;
        ctx.beginPath(); ctx.moveTo(trail[i - 1].x, trail[i - 1].y); ctx.lineTo(trail[i].x, trail[i].y); ctx.stroke();
      }
      ctx.globalAlpha = 1; ctx.shadowBlur = 0;
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);

  /* ---------- Magnetic buttons. ---------- */
  $$(".btn, .nav-dl").forEach((b) => {
    b.addEventListener("pointermove", (e) => {
      const r = b.getBoundingClientRect();
      const mx = e.clientX - r.left - r.width / 2, my = e.clientY - r.top - r.height / 2;
      b.style.translate = `${mx * 0.18}px ${my * 0.3}px`;
      b.style.setProperty("--bx", `${e.clientX - r.left}px`); b.style.setProperty("--by", `${e.clientY - r.top}px`);
    });
    b.addEventListener("pointerleave", () => (b.style.translate = ""));
  });

  /* ---------- Spotlight borders on cards. ---------- */
  $$(".points article, .tool-cols dl, .steps li, .faq details").forEach((c) => {
    c.classList.add("spot");
    c.addEventListener("pointermove", (e) => {
      const r = c.getBoundingClientRect();
      c.style.setProperty("--sx", `${e.clientX - r.left}px`); c.style.setProperty("--sy", `${e.clientY - r.top}px`);
    });
  });

  /* ---------- Scroll progress. ---------- */
  const bar = document.createElement("div"); bar.className = "fx-progress"; bar.setAttribute("aria-hidden", "true");
  document.body.append(bar);
  const prog = () => (bar.style.transform = `scaleX(${scrollY / Math.max(document.documentElement.scrollHeight - innerHeight, 1)})`);
  addEventListener("scroll", prog, { passive: true }); prog();

  /* ---------- A resident agent. When you sit still it flies in, points at
     something worth knowing and circles it, then gets out of your way.
     Esc pauses it, exactly like the app. ---------- */
  const bud = document.createElement("div"); bud.className = "fx-bud"; bud.setAttribute("aria-hidden", "true");
  bud.innerHTML = '<img src="/cursor.png" alt=""><span class="fx-say"></span>';
  const ink = document.createElementNS("http://www.w3.org/2000/svg", "svg"); ink.setAttribute("class", "fx-ink"); ink.setAttribute("aria-hidden", "true");
  const inkP = document.createElementNS("http://www.w3.org/2000/svg", "path"); ink.append(inkP);
  const pill = document.createElement("div"); pill.className = "fx-pill"; pill.setAttribute("role", "status");
  document.body.append(ink, bud, pill);
  const bimg = bud.querySelector("img"), bsay = bud.querySelector(".fx-say");
  bimg.style.transformOrigin = `${TIP.x * 100}% ${TIP.y * 100}%`;
  let bpos = { x: innerWidth + 60, y: innerHeight * 0.6 }, bflight = null, busy = false, paused = false, idleAt = performance.now();
  const visited = new Set();
  const smooth = (t) => t * t * (3 - 2 * t);
  const bplace = (rot = 0, s = 1) => {
    bud.style.transform = `translate3d(${bpos.x}px, ${bpos.y}px, 0)`;
    bimg.style.transform = `translate(${-TIP.x * SIZE}px, ${-TIP.y * SIZE}px) rotate(${rot}rad) scale(${s})`;
  };
  bplace();
  const bfly = (to) => new Promise((done) => {
    const dist = Math.hypot(to.x - bpos.x, to.y - bpos.y), lift = Math.min(dist * 0.2, 80);
    bflight = { from: { ...bpos }, to, c: { x: (bpos.x + to.x) / 2, y: (bpos.y + to.y) / 2 - lift }, t0: performance.now(), dur: Math.min(Math.max(dist / 800, 0.6), 1.4) * 1000, done };
  });
  let lastNow = performance.now();
  const btick = (now) => {
    const f = bflight, dt = now - lastNow; lastNow = now;
    if (f && paused) f.t0 += dt;
    else if (f) {
      const raw = (now - f.t0) / f.dur;
      if (raw >= 1) { bpos = { ...f.to }; bplace(); bflight = null; f.done(); }
      else {
        const t = Math.max(raw, 0), e = smooth(t), u = 1 - e;
        const x = u * u * f.from.x + 2 * u * e * f.c.x + e * e * f.to.x, y = u * u * f.from.y + 2 * u * e * f.c.y + e * e * f.to.y;
        const tx = 2 * u * (f.c.x - f.from.x) + 2 * e * (f.to.x - f.c.x), ty = 2 * u * (f.c.y - f.from.y) + 2 * e * (f.to.y - f.c.y);
        const w = Math.sin(Math.PI * t);
        let turn = Math.atan2(ty, tx) - REST; turn = Math.atan2(Math.sin(turn), Math.cos(turn));
        bpos = { x, y }; bplace(turn * w, 1 + 0.3 * w);
        trail.push({ x, y, t: now });
      }
    }
    requestAnimationFrame(btick);
  };
  requestAnimationFrame(btick);
  const wait = (ms) => new Promise((r) => {
    let left = ms, prev = performance.now();
    const go = () => { const n = performance.now(); if (!paused) left -= n - prev; prev = n; left <= 0 ? r() : setTimeout(go, 50); };
    go();
  });
  const circle = (r, ms) => {
    const pad = 10, cx = r.left + r.width / 2, cy = r.top + r.height / 2, rx = r.width / 2 + pad, ry = r.height / 2 + pad;
    inkP.setAttribute("d", `M ${cx - rx} ${cy + 2} C ${cx - rx} ${cy - ry * 1.35}, ${cx + rx} ${cy - ry * 1.4}, ${cx + rx + 3} ${cy} C ${cx + rx + 6} ${cy + ry * 1.35}, ${cx - rx + 4} ${cy + ry * 1.4}, ${cx - rx - 5} ${cy - 3}`);
    const len = inkP.getTotalLength();
    inkP.style.transition = "none"; inkP.style.strokeDasharray = len; inkP.style.strokeDashoffset = len; inkP.getBoundingClientRect();
    inkP.style.transition = `stroke-dashoffset ${ms}ms cubic-bezier(.22,1,.36,1), opacity .4s`;
    inkP.style.opacity = 1; inkP.style.strokeDashoffset = 0;
  };
  const visit = async () => {
    const tips = $$("[data-tip]").filter((el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.top > 80 && r.bottom < innerHeight - 90; });
    const el = tips.find((t) => !visited.has(t));
    if (!el) return;
    busy = true; visited.add(el);
    const r = el.getBoundingClientRect();
    bud.classList.add("on");
    await bfly({ x: Math.min(r.right + 6, innerWidth - 220), y: r.bottom + 4 });
    circle(el.getBoundingClientRect(), 800);
    bsay.textContent = el.dataset.tip; bud.classList.add("talk");
    await wait(3200);
    bud.classList.toggle("talk", false); inkP.style.opacity = 0;
    await wait(250);
    await bfly({ x: innerWidth + 60, y: bpos.y + 40 });
    bud.classList.toggle("on", false); busy = false; idleAt = performance.now();
  };
  addEventListener("pointermove", () => (idleAt = performance.now()), { passive: true });
  addEventListener("scroll", () => { idleAt = performance.now(); if (busy) inkP.style.opacity = 0; }, { passive: true });
  setInterval(() => {
    if (!busy && !paused && seen && document.visibilityState === "visible" && performance.now() - idleAt > 4500) visit();
  }, 500);

  let pillTimer;
  addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || e.target.closest("input, textarea")) return;
    paused = !paused;
    root.classList.toggle("fx-paused", paused);
    pill.innerHTML = paused ? "<b>⏸</b> All agents paused · press <kbd>esc</kbd> to resume" : "<b>▶</b> Agents resumed";
    pill.classList.add("on"); clearTimeout(pillTimer);
    if (!paused) { idleAt = performance.now(); pillTimer = setTimeout(() => pill.classList.toggle("on", false), 1600); }
  });

  /* ---------- Drag on empty space to draw, the way annotate does. ---------- */
  const pad = document.createElementNS("http://www.w3.org/2000/svg", "svg"); pad.setAttribute("class", "fx-pad"); pad.setAttribute("aria-hidden", "true");
  document.body.append(pad);
  const blank = (t) => !t.closest("p, h1, h2, h3, a, button, code, pre, kbd, dt, dd, summary, label, img, .desk, .log, [role=tab], .fx-pal");
  let stroke = null, pts = [];
  addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "mouse" || e.button !== 0 || !blank(e.target)) return;
    e.preventDefault();
    stroke = document.createElementNS("http://www.w3.org/2000/svg", "path"); pad.append(stroke);
    pts = [[e.clientX, e.clientY]];
  });
  addEventListener("pointermove", (e) => {
    if (!stroke) return;
    pts.push([e.clientX, e.clientY]);
    let d = `M ${pts[0][0]} ${pts[0][1]}`;
    for (let i = 1; i < pts.length - 1; i++) { const mx = (pts[i][0] + pts[i + 1][0]) / 2, my = (pts[i][1] + pts[i + 1][1]) / 2; d += ` Q ${pts[i][0]} ${pts[i][1]} ${mx} ${my}`; }
    stroke.setAttribute("d", d);
  }, { passive: true });
  addEventListener("pointerup", () => {
    if (!stroke) return;
    const s = stroke; stroke = null;
    setTimeout(() => s.classList.add("gone"), 1400);
    s.addEventListener("transitionend", () => s.parentNode && s.parentNode.removeChild(s));
  });
  addEventListener("scroll", () => $$("path", pad).forEach((p) => p.classList.add("gone")), { passive: true });

  /* ---------- Tool chips copy their name, and the cursor says so. ---------- */
  $$(".tool-cols code").forEach((c) => {
    c.dataset.cur = "Copy name";
    c.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(c.textContent); } catch {}
      tag.textContent = `Copied ${c.textContent}`; cur.classList.add("tagged", "ok");
      setTimeout(() => { cur.classList.toggle("ok", false); tag.textContent = "Copy name"; }, 1200);
    });
  });
  // Links/buttons pick up data-cur labels; code chips need it too.
  document.addEventListener("pointerover", (e) => {
    const c = e.target.closest(".tool-cols code");
    if (c) { cur.dataset.mode = "link"; root.dataset.cmode = "link"; if (!cur.classList.contains("ok")) tag.textContent = c.dataset.cur; cur.classList.add("tagged"); }
  });

  /* ---------- ⌘K: a palette that sends the agent anywhere on the page. ---------- */
  const items = [
    ["Watch the demo", "#sketch"], ["How it works", "#how"], ["Set up", ".setup"], ["All 37 tools", "#tools"], ["Questions", "#faq"], ["Download", ".end"],
    ...$$(".tool-cols code").map((c) => [c.textContent, c, "tool"]),
    ...$$(".agents [role=tab]").map((b) => [`Connect ${b.textContent}`, b, "setup"]),
  ];
  const pal = document.createElement("div"); pal.className = "fx-pal"; pal.hidden = true;
  pal.innerHTML = '<div class="fx-pal-box" role="dialog" aria-label="Jump to"><input type="text" placeholder="Send the agent to…" aria-label="Search the page" autocomplete="off" spellcheck="false"><ul role="listbox"></ul><p class="fx-pal-foot"><kbd>↑</kbd><kbd>↓</kbd> move · <kbd>↵</kbd> go · <kbd>esc</kbd> close</p></div>';
  document.body.append(pal);
  const q = pal.querySelector("input"), ul = pal.querySelector("ul");
  let sel = 0, shown = [];
  const render = () => {
    const v = q.value.trim().toLowerCase();
    shown = items.filter(([n]) => !v || n.toLowerCase().includes(v)).slice(0, 8);
    sel = Math.min(sel, Math.max(shown.length - 1, 0));
    ul.innerHTML = shown.map(([n, , k], i) => `<li role="option" aria-selected="${i === sel}" data-i="${i}"><span>${n.replace(/</g, "&lt;")}</span>${k ? `<em>${k}</em>` : ""}</li>`).join("") || '<li class="none">Nothing here. Try “click”.</li>';
  };
  const open = () => { pal.hidden = false; q.value = ""; sel = 0; render(); requestAnimationFrame(() => { pal.classList.add("on"); q.focus(); }); };
  const close = () => { pal.classList.toggle("on", false); setTimeout(() => (pal.hidden = true), 200); };
  const go = async (i) => {
    const it = shown[i]; if (!it) return;
    close();
    const el = typeof it[1] === "string" ? document.querySelector(it[1]) : it[1];
    if (it[2] === "setup") el.click();
    el.scrollIntoView({ behavior: "smooth", block: "center" });
    await new Promise((r) => setTimeout(r, 650));
    const r = el.getBoundingClientRect();
    busy = true; bud.classList.add("on");
    await bfly({ x: Math.min(r.left + Math.min(r.width, 200) / 2, innerWidth - 220), y: Math.min(r.top + Math.min(r.height, 60) / 2, innerHeight - 60) });
    if (it[2] === "tool") { circle(el.getBoundingClientRect(), 600); bsay.textContent = el.parentNode.textContent.replace(/\s+/g, " ").trim().slice(0, 70); bud.classList.add("talk"); await wait(2600); bud.classList.toggle("talk", false); inkP.style.opacity = 0; }
    else await wait(900);
    await bfly({ x: innerWidth + 60, y: bpos.y + 40 });
    bud.classList.toggle("on", false); busy = false; idleAt = performance.now();
  };
  q.addEventListener("input", () => { sel = 0; render(); });
  q.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); sel = (sel + (e.key === "ArrowDown" ? 1 : -1) + shown.length) % Math.max(shown.length, 1); render(); }
    else if (e.key === "Enter") { e.preventDefault(); go(sel); }
    else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); }
  });
  ul.addEventListener("pointermove", (e) => { const li = e.target.closest("[data-i]"); if (li && +li.dataset.i !== sel) { sel = +li.dataset.i; render(); } });
  ul.addEventListener("click", (e) => { const li = e.target.closest("[data-i]"); if (li) go(+li.dataset.i); });
  pal.addEventListener("pointerdown", (e) => { if (e.target === pal) close(); });
  addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); pal.hidden ? open() : close(); }
    else if (e.key === "/" && pal.hidden && !e.target.closest("input, textarea")) { e.preventDefault(); open(); }
  }, true);

  /* ---------- A one-time hint. ---------- */
  let hinted = false;
  try { hinted = localStorage.getItem("mcu-hint") === "1"; } catch {}
  if (!hinted) {
    const h = document.createElement("div"); h.className = "fx-hint";
    h.innerHTML = "<kbd>⌘K</kbd> send the agent anywhere · drag on empty space to draw · <kbd>esc</kbd> pauses it";
    document.body.append(h);
    setTimeout(() => h.classList.add("on"), 2500);
    setTimeout(() => { h.classList.toggle("on", false); try { localStorage.setItem("mcu-hint", "1"); } catch {} }, 11000);
  }
})();
