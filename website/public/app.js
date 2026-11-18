/**
 * mcu.iamngoni.dev behaviour: the hero sketch and the latest-release labels.
 * The sketch's cursor reproduces the app's own flight (CursorFlight.swift):
 * a quadratic arc eased with smoothstep, a lean into the direction of travel
 * and a small swell weighted by sin(pi t), and a 0.42 s fading trail
 * (ServiceOverlay.swift, TrailOverlay). Reduced motion jumps instead.
 */
(() => {
  "use strict";
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const sleep = (ms) => new Promise((r) => setTimeout(r, reduce ? Math.min(ms, 400) : ms));
  document.documentElement.classList.add("js");

  /* Latest release. Labels stay generic if the API is unavailable. */
  fetch("/api/latest")
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
    .then((rel) => {
      $$("[data-version]").forEach((el) => (el.textContent = `Version ${rel.version}`));
      if (rel.dmg) $$("[data-size]").forEach((el) => (el.textContent = ` · ${(rel.dmg.size / 1048576).toFixed(1)} MB`));
      $$("[data-notes]").forEach((el) => (el.href = rel.notes_url));
    })
    .catch(() => {});

  $$("[data-copy]").forEach((b) =>
    b.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = "Copied"; }
      catch { b.textContent = "Press ⌘C"; }
      setTimeout(() => (b.textContent = "Copy"), 1600);
    }),
  );

  /* Agent install tabs. */
  const tabs = $$('[role="tab"]');
  const pick = (t, focus) => {
    tabs.forEach((x) => {
      const on = x === t;
      x.setAttribute("aria-selected", on); x.tabIndex = on ? 0 : -1;
      document.getElementById(x.getAttribute("aria-controls")).hidden = !on;
    });
    if (focus) t.focus();
  };
  tabs.forEach((t, i) => {
    t.addEventListener("click", () => pick(t));
    t.addEventListener("keydown", (e) => {
      const d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
      if (d) { e.preventDefault(); pick(tabs[(i + d + tabs.length) % tabs.length], true); }
    });
  });

  /* Gentle one-time entrance for sections below the fold. */
  const io = new IntersectionObserver((es) => es.forEach((e) => {
    if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
  }), { threshold: 0.12 });
  $$("main > section:not(:first-child)").forEach((s) => { s.classList.add("fade"); io.observe(s); });

  /* ---------- The sketch ---------- */
  const desk = $("#desk"), agent = $("#agent"), cv = $("#trail"), ctx = cv.getContext("2d");
  const ring = $("#ring"), bubble = $("#bubble"), ask = $("#ask"), log = $("#log");
  const inkPath = $("#inkPath");
  const ACCENT = "61,170,255";
  // The cursor art's tip sits at (16, 15) in its 84 px image.
  const TIP = { x: 16 / 84, y: 15 / 84 };
  const REST = Math.atan2(-1, -1); // the art points up and to the left
  let W = 0, H = 0, dpr = 1;
  let pos = { x: 0.84, y: 0.9 };
  let trail = [];
  let flight = null;
  let runId = 0;

  const size = () => {
    const r = desk.getBoundingClientRect();
    W = r.width; H = r.height; dpr = Math.min(devicePixelRatio || 1, 2);
    cv.width = W * dpr; cv.height = H * dpr;
    draw(performance.now());
  };

  const place = (p, rot = 0, scale = 1) => {
    const w = agent.offsetWidth;
    agent.style.transformOrigin = `${TIP.x * 100}% ${TIP.y * 100}%`;
    agent.style.transform = `translate(${p.x * W - TIP.x * w}px, ${p.y * H - TIP.y * w}px) rotate(${rot}rad) scale(${scale})`;
  };

  const smoothstep = (t) => { const x = Math.min(Math.max(t, 0), 1); return x * x * (3 - 2 * x); };

  // Teaching pace from CursorFlight.swift: distance / 800 pt/s, 0.6 to 1.4 s,
  // lifted by min(20% of the distance, 80 pt), swelling up to 30%.
  const fly = (to) => new Promise((done) => {
    const from = { x: pos.x * W, y: pos.y * H }, end = { x: to.x * W, y: to.y * H };
    const dist = Math.hypot(end.x - from.x, end.y - from.y);
    if (reduce || dist < 6) { pos = to; place(pos); return done(); }
    const lift = Math.min(dist * 0.2, 80);
    const control = { x: (from.x + end.x) / 2, y: (from.y + end.y) / 2 - lift };
    flight = { from, end, control, start: performance.now(), duration: Math.min(Math.max(dist / 800, 0.6), 1.4) * 1000, done };
  });

  const draw = (now) => {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    trail = trail.filter((p) => now - p.t <= 420);
    if (trail.length >= 2) {
      const age = (now - trail[0].t) / 1000;
      ctx.globalAlpha = Math.max(0.35, 1 - age / 0.6);
      ctx.lineCap = "round"; ctx.lineJoin = "round"; ctx.lineWidth = 4.5;
      ctx.strokeStyle = `rgba(${ACCENT},.85)`;
      ctx.shadowColor = `rgba(${ACCENT},.9)`; ctx.shadowBlur = 7;
      ctx.beginPath();
      trail.forEach((p, i) => (i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)));
      ctx.stroke();
      ctx.globalAlpha = 1; ctx.shadowBlur = 0;
    }
  };

  const frame = (now) => {
    if (flight) {
      const f = flight, raw = (now - f.start) / f.duration;
      if (raw >= 1) {
        pos = { x: f.end.x / W, y: f.end.y / H };
        place(pos);
        flight = null;
        f.done();
      } else {
        const t = Math.max(raw, 0), e = smoothstep(t), u = 1 - e;
        const x = u * u * f.from.x + 2 * u * e * f.control.x + e * e * f.end.x;
        const y = u * u * f.from.y + 2 * u * e * f.control.y + e * e * f.end.y;
        const tx = 2 * u * (f.control.x - f.from.x) + 2 * e * (f.end.x - f.control.x);
        const ty = 2 * u * (f.control.y - f.from.y) + 2 * e * (f.end.y - f.control.y);
        const weight = Math.sin(Math.PI * t);
        let turn = Math.atan2(ty, tx) - REST;
        turn = Math.atan2(Math.sin(turn), Math.cos(turn));
        pos = { x: x / W, y: y / H };
        place(pos, turn * weight, 1 + 0.3 * weight);
        const last = trail[trail.length - 1];
        if (!last || Math.hypot(last.x - x, last.y - y) > 1.5) trail.push({ x, y, t: now });
      }
    }
    draw(now);
    requestAnimationFrame(frame);
  };

  // Where an element's point sits, as a fraction of the desk.
  const at = (el, fx = 0.5, fy = 0.5) => {
    const d = desk.getBoundingClientRect(), e = el.getBoundingClientRect();
    return { x: (e.left - d.left + e.width * fx) / d.width, y: (e.top - d.top + e.height * fy) / d.height };
  };
  const pinAt = (el, p, dx = 14, dy = 18) => {
    const maxX = W - el.offsetWidth - 8;
    el.style.left = `${Math.min(p.x * W + dx, maxX)}px`;
    el.style.top = `${Math.min(p.y * H + dy, H - el.offsetHeight - 8)}px`;
  };
  const click = async () => {
    ring.style.left = `${pos.x * W}px`; ring.style.top = `${pos.y * H}px`;
    ring.classList.remove("go"); void ring.offsetWidth; ring.classList.add("go");
    await sleep(160);
  };
  const say = (text) => { bubble.textContent = text; pinAt(bubble, pos); bubble.classList.add("on"); };
  const hush = () => bubble.classList.remove("on");
  const entry = (html, cls) => {
    const li = document.createElement("li");
    li.className = cls; li.innerHTML = html;
    log.appendChild(li);
    requestAnimationFrame(() => li.classList.add("in"));
    while (log.children.length > 10) log.firstChild.remove();
  };
  const call = (name, args) => entry(`<b>${name}</b>(${args})`, "call");
  const result = (text) => entry(text, "res ok");

  const drawInk = (d, ms) => {
    inkPath.setAttribute("d", d);
    const len = inkPath.getTotalLength();
    inkPath.style.transition = "none";
    inkPath.style.strokeDasharray = `${len}`;
    inkPath.style.strokeDashoffset = `${len}`;
    inkPath.getBoundingClientRect();
    inkPath.style.transition = `stroke-dashoffset ${reduce ? 1 : ms}ms cubic-bezier(.22,1,.36,1)`;
    inkPath.style.strokeDashoffset = "0";
    return sleep(ms);
  };

  const reset = () => {
    $$(".box", desk).forEach((b) => b.classList.remove("on"));
    $("#typed").textContent = "";
    $("#url").textContent = "github.com";
    const pub = $("#publish"); pub.textContent = "Publish release"; pub.classList.remove("done");
    const draft = $("#draft"); draft.textContent = "Draft"; draft.classList.remove("live");
    inkPath.setAttribute("d", "");
    hush(); ask.classList.remove("on");
    log.innerHTML = "";
  };

  const scene = async (id) => {
    const alive = () => id === runId;
    reset();
    await sleep(500);

    call("get_app_state", 'app: "Notes"'); await sleep(450);
    result("window 8121 · 46 elements"); if (!alive()) return;

    await fly(at($("#t1"))); await click(); $("#t1").classList.add("on");
    call("click", "element_index: 12"); result("pressed in the background");
    await sleep(350); if (!alive()) return;
    await fly(at($("#t2"))); await click(); $("#t2").classList.add("on");
    call("click", "element_index: 14"); result("pressed in the background");
    await sleep(350); if (!alive()) return;

    await fly(at($("#typed"), 0, 0.5)); $(".typed").classList.add("typing");
    call("type_text", '"Notes are in. Tagging now."');
    for (const ch of "Notes are in. Tagging now.") { if (!alive()) return; $("#typed").textContent += ch; await sleep(38); }
    $(".typed").classList.remove("typing"); result("typed 26 characters");
    await sleep(400); if (!alive()) return;

    call("navigate", 'url: "github.com/…/releases"');
    await fly(at($("#url"), 0.3, 0.5));
    $("#url").textContent = "github.com/iamngoni/mac-computer-use/releases";
    result("Safari tab updated"); await sleep(400); if (!alive()) return;

    // Point at the button and circle it, the way annotate draws.
    const pub = $("#publish");
    const d = desk.getBoundingClientRect(), b = pub.getBoundingClientRect();
    const cx = b.left - d.left + b.width / 2, cy = b.top - d.top + b.height / 2;
    const rx = b.width * 0.68, ry = b.height * 1.05;
    call("point_at", "element_index: 31");
    await fly(at(pub, 1.05, 1.1));
    say("This publishes the release.");
    call("annotate", "ellipse");
    await drawInk(`M ${cx - rx} ${cy + 2} C ${cx - rx} ${cy - ry * 1.35}, ${cx + rx} ${cy - ry * 1.4}, ${cx + rx + 3} ${cy} C ${cx + rx + 6} ${cy + ry * 1.35}, ${cx - rx + 4} ${cy + ry * 1.4}, ${cx - rx - 5} ${cy - 3}`, 900);
    await sleep(900); hush(); if (!alive()) return;

    call("ask_user", '"Publish v0.10.1 now?"');
    pinAt(ask, pos, 10, 16); ask.classList.add("on");
    await sleep(1500); if (!alive()) return;
    const yes = $("#askYes"); yes.classList.add("press"); await sleep(140); yes.classList.remove("press");
    result('you chose "Publish"'); ask.classList.remove("on");
    await sleep(300); if (!alive()) return;

    await fly(at(pub)); await click();
    pub.classList.add("press"); await sleep(120); pub.classList.remove("press");
    pub.textContent = "Published"; pub.classList.add("done");
    const draft = $("#draft"); draft.textContent = "Latest"; draft.classList.add("live");
    inkPath.setAttribute("d", "");
    call("click", "element_index: 31"); result("published");
    await sleep(500); if (!alive()) return;

    await fly(at($("#t3"))); await click(); $("#t3").classList.add("on");
    call("click", "element_index: 16"); result("all three done");
    say("Done. Your pointer didn't move.");
    await sleep(2200); hush();
    await fly({ x: 0.84, y: 0.9 });
  };

  const run = () => { runId += 1; flight = null; trail = []; return scene(runId); };
  $("#replay").addEventListener("click", () => { pos = { x: 0.84, y: 0.9 }; place(pos); run(); });

  addEventListener("resize", () => { size(); place(pos); });
  size(); place(pos);
  requestAnimationFrame(frame);

  // Start when the sketch is on screen.
  const start = new IntersectionObserver((es) => {
    if (es[0].isIntersecting) { start.disconnect(); run(); }
  }, { threshold: 0.35 });
  start.observe(desk);
})();
