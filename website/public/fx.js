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
})();
