// Mac Computer Use site Worker: serves static assets and resolves the latest
// signed GitHub release for /download and /api/latest (cached 10 minutes).
// Falls back to the GitHub releases page when the API is unavailable.
const REPO = "iamngoni/mac-computer-use";
const RELEASES = `https://github.com/${REPO}/releases/latest`;
const CACHE_SECONDS = 600;

async function latestRelease(ctx) {
  const cache = caches.default;
  const key = new Request("https://mcu.iamngoni.dev/__cache/latest-release");
  const hit = await cache.match(key);
  if (hit) return hit.json();

  const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
    headers: { "User-Agent": "mcu-site", Accept: "application/vnd.github+json" },
  });
  if (!res.ok) throw new Error(`GitHub API ${res.status}`);
  const r = await res.json();
  const pick = (ext) => r.assets.find((a) => a.name.toLowerCase().endsWith(ext));
  const dmg = pick(".dmg");
  const zip = pick(".zip");
  const data = {
    version: r.tag_name.replace(/^v/, ""),
    tag: r.tag_name,
    published_at: r.published_at,
    notes_url: r.html_url,
    dmg: dmg && { name: dmg.name, url: dmg.browser_download_url, size: dmg.size },
    zip: zip && { name: zip.name, url: zip.browser_download_url, size: zip.size },
  };
  ctx.waitUntil(
    cache.put(key, new Response(JSON.stringify(data), {
      headers: { "Cache-Control": `public, max-age=${CACHE_SECONDS}` },
    })),
  );
  return data;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/api/latest") {
      try {
        return Response.json(await latestRelease(ctx), {
          headers: { "Cache-Control": `public, max-age=${CACHE_SECONDS}`, "Access-Control-Allow-Origin": "*" },
        });
      } catch {
        return Response.json({ error: "unavailable", notes_url: RELEASES }, { status: 503 });
      }
    }

    if (url.pathname === "/download" || url.pathname.startsWith("/download/")) {
      const wantZip = url.pathname.endsWith("/zip");
      try {
        const rel = await latestRelease(ctx);
        const asset = wantZip ? rel.zip : rel.dmg;
        return Response.redirect(asset ? asset.url : RELEASES, 302);
      } catch {
        return Response.redirect(RELEASES, 302);
      }
    }

    return env.ASSETS.fetch(request);
  },
};
