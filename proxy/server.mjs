import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { load } from 'cheerio';
import { chromium } from 'playwright';

const host = process.env.BRIDGE_HOST ?? '0.0.0.0';
const port = Number(process.env.BRIDGE_PORT ?? 8787);
const providerOrigin = Buffer.from('aHR0cHM6Ly9hbmlrb3RvdHYudG8=', 'base64').toString('utf8');
const sources = new Map();
const seriesCache = new Map();
let browserPromise;

function json(response, status, body) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  response.end(JSON.stringify(body));
}
function text(response, status, body, type = 'text/plain; charset=utf-8') {
  response.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' }); response.end(body);
}
function absoluteUrl(value, parent) { return new URL(value, parent).toString(); }
function mediaUrl(id, upstream) { return `/media/${id}?url=${encodeURIComponent(upstream)}`; }
function isPlaylist(url, contentType) { return new URL(url).pathname.toLowerCase().endsWith('.m3u8') || contentType.includes('mpegurl'); }
function cleanText(value) { return String(value ?? '').replace(/\s+/g, ' ').trim(); }
function requireProviderUrl(value) {
  const url = new URL(value, providerOrigin);
  if (url.origin !== providerOrigin || !url.pathname.startsWith('/watch/')) throw new Error('Only catalog watch URLs are accepted');
  return url;
}
function providerUrl(path) { return new URL(path, providerOrigin).toString(); }
async function fetchWithTimeout(url, options = {}, timeoutMs = 15000, label = 'Request') {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } catch (error) {
    if (error?.name === 'AbortError') throw new Error(`${label} timed out after ${Math.ceil(timeoutMs / 1000)} seconds`);
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}
async function providerJson(path) {
  const response = await fetchWithTimeout(providerUrl(path), { headers: { Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest' } }, 15000, 'Provider request');
  if (!response.ok) throw new Error(`Provider HTTP ${response.status}`);
  const payload = await response.json();
  if (Number(payload.status) !== 200) throw new Error(payload.message || 'Provider did not return a successful result');
  return payload.result;
}
function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = '';
    request.on('data', (part) => { body += part; if (body.length > 100000) reject(new Error('Request too large')); });
    request.on('end', () => resolve(body)); request.on('error', reject);
  });
}

function parseSearch(html) {
  const $ = load(html); const seen = new Set(); const results = [];
  $('a.item[href*="/watch/"]').each((_, node) => {
    const url = new URL($(node).attr('href'), providerOrigin).toString();
    if (seen.has(url)) return; seen.add(url);
    results.push({
      title: cleanText($(node).find('.name').first().text()) || 'Untitled', watchUrl: url,
      imageUrl: $(node).find('img').first().attr('src') ? absoluteUrl($(node).find('img').first().attr('src'), providerOrigin) : null,
      meta: cleanText($(node).find('.meta').text()),
    });
  });
  return results;
}
function parseSeriesPage(html, watchUrl) {
  const $ = load(html); const root = $('#watch-main'); const animeId = root.attr('data-id');
  if (!animeId || !/^\d+$/.test(animeId)) throw new Error('Series identifier was not found');
  return { animeId, title: cleanText($('#w-info h1, #w-info .film-name, h1').first().text()) || 'Untitled', watchUrl };
}
function parseEpisodes(html) {
  const $ = load(html); const episodes = [];
  $('[data-ids]').each((_, node) => {
    const element = $(node); const number = Number(element.attr('data-num')); const ids = element.attr('data-ids');
    if (!Number.isFinite(number) || !ids) return;
    episodes.push({ number, title: cleanText(element.text()).replace(/^\d+\s*/, '') || `Episode ${number}`, ids });
  });
  return episodes.sort((a, b) => a.number - b.number);
}
function parseServers(html) {
  const $ = load(html); const servers = [];
  $('li[data-link-id]').each((index, node) => {
    const item = $(node); const linkId = item.attr('data-link-id'); if (!linkId) return;
    const serverMarkup = [
      item.attr('data-type'),
      item.closest('[data-type]').attr('data-type'),
      item.attr('class'),
      item.parent().attr('class'),
      item.closest('div, ul, section').attr('class'),
      item.text(),
    ].filter(Boolean).join(' ').toLowerCase();
    const type = /(?:^|[^a-z])dub(?:[^a-z]|$)/.test(serverMarkup) ? 'dub' : 'sub';
    servers.push({ index, name: cleanText(item.text()) || `Server ${index + 1}`, type, linkId });
  });
  return servers;
}
async function getSeries(watchUrl) {
  const url = requireProviderUrl(watchUrl); const page = await fetchWithTimeout(url, { headers: { Accept: 'text/html' } }, 15000, 'Provider page request');
  if (!page.ok) throw new Error(`Provider page HTTP ${page.status}`);
  const series = parseSeriesPage(await page.text(), url.toString());
  const episodeMarkup = await providerJson(`/ajax/episode/list/${series.animeId}`); const episodes = parseEpisodes(episodeMarkup);
  if (!episodes.length) throw new Error('No episodes were returned');
  const key = randomUUID(); seriesCache.set(key, { ...series, episodes, expiresAt: Date.now() + 20 * 60 * 1000 });
  console.info(`[bridge] Loaded ${series.title}: ${episodes.length} episode(s)`);
  return { seriesKey: key, title: series.title, episodes: episodes.map(({ number, title }) => ({ number, title })) };
}
function cachedSeries(key) {
  const series = seriesCache.get(key);
  if (!series || series.expiresAt < Date.now()) { seriesCache.delete(key); throw new Error('Series session expired; search again'); }
  return series;
}
async function getServers(seriesKey, episodeNumber) {
  const series = cachedSeries(seriesKey); const episode = series.episodes.find((candidate) => candidate.number === Number(episodeNumber));
  if (!episode) throw new Error('Episode was not found');
  const markup = await providerJson(`/ajax/server/list?servers=${encodeURIComponent(episode.ids)}`); const servers = parseServers(markup);
  if (!servers.length) throw new Error('No servers were returned');
  const subCount = servers.filter((server) => server.type === 'sub').length;
  console.info(`[bridge] Episode ${episode.number}: ${subCount} Sub, ${servers.length - subCount} Dub servers`);
  series.lastServers = { episodeNumber: episode.number, servers };
  return { episode: episode.number, servers: servers.map(({ index, name, type }) => ({ index, name, type })) };
}
async function getBrowser() {
  if (!browserPromise) {
    console.info('[bridge] Launching Chromium for player discovery');
    browserPromise = chromium.launch({ headless: true }).catch((error) => { browserPromise = undefined; throw error; });
  }
  return browserPromise;
}
function classifyUrl(value, found) {
  try {
    const url = new URL(value); const path = url.pathname.toLowerCase();
    if (path.endsWith('.m3u8')) found.hls.add(url.toString());
    if (path.endsWith('.vtt')) found.vtt.add(url.toString());
  } catch { /* Ignore non-URLs. */ }
}
function collectMediaUrls(value, found) {
  if (typeof value === 'string') { classifyUrl(value, found); return; }
  if (Array.isArray(value)) { for (const child of value) collectMediaUrls(child, found); return; }
  if (!value || typeof value !== 'object') return;
  for (const child of Object.values(value)) collectMediaUrls(child, found);
}
async function resolveEmbed(embedUrl) {
  const browser = await getBrowser(); const page = await browser.newPage({ extraHTTPHeaders: { Referer: `${providerOrigin}/` } });
  const found = { hls: new Set(), loadedHls: new Set(), masterHls: new Set(), vtt: new Set(), requestHeaders: {} }; const pending = [];
  page.on('request', (request) => {
    const url = request.url().toLowerCase();
    if (!url.includes('.m3u8') && !url.includes('.vtt')) return;
    const headers = request.headers();
    // These public request-context headers match the player request. Deliberately
    // do not retain cookies, authorization headers, or any user credentials.
    for (const name of ['referer', 'origin', 'user-agent', 'accept', 'accept-language']) if (headers[name]) found.requestHeaders[name] = headers[name];
  });
  page.on('response', (response) => {
    classifyUrl(response.url(), found); const type = response.headers()['content-type'] ?? '';
    if (response.ok() && new URL(response.url()).pathname.toLowerCase().endsWith('.m3u8')) {
      found.loadedHls.add(response.url());
      pending.push(response.text().then((body) => {
        if (body.includes('#EXT-X-STREAM-INF')) found.masterHls.add(response.url());
      }).catch(() => {}));
    }
    if (type.includes('json') || /getSources/i.test(response.url())) pending.push(response.json().then((body) => collectMediaUrls(body, found)).catch(() => {}));
  });
  try {
    console.info('[bridge] Opening selected player');
    await page.goto(embedUrl, { waitUntil: 'domcontentloaded', timeout: 15000 });
    console.info('[bridge] Player page opened; waiting for its video element');
    await page.waitForSelector('video', { timeout: 12000 });
    await page.locator('video').evaluate(async (video) => {
      video.muted = true;
      try { await video.play(); } catch { /* Source discovery can still continue without autoplay. */ }
    });
    console.info('[bridge] Video element found; discovering HLS and subtitle tracks');
    await page.waitForTimeout(5000);
    const domUrls = await page.evaluate(() => ({
      video: [...document.querySelectorAll('video')].map((node) => node.currentSrc || node.getAttribute('src') || ''),
      tracks: [...document.querySelectorAll('track')].map((node) => node.getAttribute('src') || ''),
      resources: performance.getEntriesByType('resource').map((entry) => entry.name),
    }));
    collectMediaUrls(domUrls, found);
    await Promise.race([Promise.allSettled(pending), page.waitForTimeout(2000)]);
    await page.locator('video').evaluate((video) => video.pause());
  } catch (error) {
    await page.close(); throw error;
  }
  console.info(`[bridge] Player discovery found ${found.hls.size} HLS candidate(s), ${found.loadedHls.size} loaded, ${found.vtt.size} subtitle track(s)`);
  let hlsUrl = [...found.masterHls, ...found.loadedHls][0];
  for (const candidate of found.hls) {
    if (hlsUrl) break;
    const valid = await page.evaluate(async (url) => {
      const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 5000);
      try {
        const response = await fetch(url, { signal: controller.signal });
        if (!response.ok) return false;
        return (await response.text()).includes('#EXTM3U');
      } catch {
        return false;
      } finally {
        clearTimeout(timeout);
      }
    }, candidate).catch(() => false);
    if (valid) { hlsUrl = candidate; break; }
  }
  if (!hlsUrl) { await page.close(); throw new Error(`The selected player did not expose a usable HLS playlist (${found.hls.size} candidates, ${found.loadedHls.size} loaded)`); }
  return { hlsUrl, requestHeaders: found.requestHeaders, mediaPage: page, subtitles: [...found.vtt].map((vttUrl, index) => ({ name: `Subtitles ${index + 1}`, language: 'und', vttUrl, default: index === 0 })) };
}
async function createPlayback(seriesKey, episodeNumber, serverIndex, requestHost) {
  const series = cachedSeries(seriesKey);
  if (!series.lastServers || series.lastServers.episodeNumber !== Number(episodeNumber)) await getServers(seriesKey, episodeNumber);
  const server = series.lastServers.servers.find((candidate) => candidate.index === Number(serverIndex)); if (!server) throw new Error('Server was not found');
  console.info(`[bridge] Resolving episode ${episodeNumber}, ${server.type.toUpperCase()} server ${server.name}`);
  const reply = await providerJson(`/ajax/server?get=${encodeURIComponent(server.linkId)}`); if (!reply?.url) throw new Error('Player URL was not returned');
  console.info('[bridge] Player URL returned; starting discovery');
  const media = await resolveEmbed(reply.url); const id = randomUUID(); sources.set(id, media);
  const expiry = setTimeout(() => { const source = sources.get(id); sources.delete(id); source?.mediaPage?.close().catch(() => {}); }, 2 * 60 * 60 * 1000);
  expiry.unref();
  console.info(`[bridge] Playback ready with ${media.subtitles.length} subtitle track(s)`);
  return { playbackUrl: `http://${requestHost}/watch/${id}/master.m3u8`, subtitleTracks: media.subtitles.length };
}

function rewriteUriLines(textValue, baseUrl, id) {
  return textValue.split(/\r?\n/).map((line) => {
    const value = line.trim(); if (!value) return line;
    if (!value.startsWith('#')) return mediaUrl(id, absoluteUrl(value, baseUrl));
    return line.replace(/URI="([^"]+)"/g, (match, uri) => uri.startsWith('/subtitle/') ? match : `URI="${mediaUrl(id, absoluteUrl(uri, baseUrl))}"`);
  }).join('\n');
}
function injectSubtitles(master, source, id) {
  const tracks = source.subtitles ?? []; if (!tracks.length || /TYPE=SUBTITLES/.test(master)) return master;
  const declarations = tracks.map((track, index) => `#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="bridge-subs",NAME="${track.name.replaceAll('"', '')}",LANGUAGE="${track.language.replaceAll('"', '')}",DEFAULT=${track.default ? 'YES' : 'NO'},AUTOSELECT=YES,URI="/subtitle/${id}/${index}.m3u8"`);
  const variants = master.replace(/#EXT-X-STREAM-INF:([^\r\n]*)/g, (line, attrs) => /(?:^|,)SUBTITLES=/.test(attrs) ? line : `#EXT-X-STREAM-INF:${attrs},SUBTITLES="bridge-subs"`);
  return variants.replace(/^#EXTM3U\s*$/m, '#EXTM3U\n' + declarations.join('\n'));
}
function secondsInVttTimestamp(match) { return Number(match[1] ?? 0) * 3600 + Number(match[2]) * 60 + Number(match[3]); }
function durationFromVtt(vtt) {
  const pattern = /^(?:(\d+):)?(\d{2}):(\d{2}\.\d{3})\s+-->\s+(?:(\d+):)?(\d{2}):(\d{2}\.\d{3})/gm; let duration = 1;
  for (const match of vtt.matchAll(pattern)) duration = Math.max(duration, secondsInVttTimestamp([, match[4], match[5], match[6]]));
  return Math.ceil(duration);
}
async function fetchFromPlayer(source, url, range) {
  if (!source.mediaPage || source.mediaPage.isClosed()) throw new Error('The player session expired');
  const result = await source.mediaPage.evaluate(async ({ url, range }) => {
    const response = await fetch(url, { headers: range ? { Range: range } : undefined });
    const bytes = new Uint8Array(await response.arrayBuffer()); let binary = '';
    for (let offset = 0; offset < bytes.length; offset += 0x8000) binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
    return { ok: response.ok, status: response.status, url: response.url, type: response.headers.get('content-type') ?? '', body: btoa(binary) };
  }, { url, range });
  if (!result.ok) throw new Error(`Upstream responded ${result.status}`);
  return { url: result.url, type: result.type, body: Buffer.from(result.body, 'base64') };
}
function removePlayerTransportPrefix(url, body) {
  // This mirrors the public player’s SegmentStrip behavior for the affected
  // CDNs. It removes only its documented fixed transport prefix, never media
  // content, credentials, or DRM data.
  const hostname = new URL(url).hostname;
  return /(?:ibyteimg\.com|tiktokcdn\.com|ipstatp\.com|yoot\.akirax\.buzz)$/i.test(hostname) && body.length > 252 ? body.subarray(252) : body;
}
async function fetchUpstream(url, source, range) {
  const headers = { ...source.requestHeaders, ...(range ? { range } : {}) };
  try {
    const response = await fetch(url, { redirect: 'follow', headers });
    if (response.ok) return { url: response.url, type: response.headers.get('content-type') ?? '', body: Buffer.from(await response.arrayBuffer()) };
    if (response.status !== 403) throw new Error(`Upstream responded ${response.status}`);
  } catch (error) { if (!source.mediaPage || source.mediaPage.isClosed()) throw error; }
  return fetchFromPlayer(source, url, range);
}
async function sendUpstream(response, upstreamUrl, id, source, inject, range) {
  const upstream = await fetchUpstream(upstreamUrl, source, range); upstream.body = removePlayerTransportPrefix(upstream.url, upstream.body); const type = upstream.type;
  if (!isPlaylist(upstream.url, type)) { response.writeHead(200, { 'content-type': upstream.url.toLowerCase().includes('.vtt') ? 'text/vtt; charset=utf-8' : type || 'application/octet-stream' }); response.end(upstream.body); return; }
  let playlist = upstream.body.toString('utf8'); const manifestStart = playlist.indexOf('#EXTM3U'); if (manifestStart > 0) playlist = playlist.slice(manifestStart); if (inject) playlist = injectSubtitles(playlist, source, id); playlist = rewriteUriLines(playlist, upstream.url, id);
  text(response, 200, playlist, 'application/vnd.apple.mpegurl; charset=utf-8');
}
async function sendSingleVttPlaylist(response, track, id, source) {
  if (!track.duration) { const vtt = await fetchUpstream(track.vttUrl, source); const body = vtt.body.toString('utf8'); if (!/^WEBVTT(?:\r?\n|$)/.test(body)) throw new Error('Subtitle did not return WebVTT'); track.duration = durationFromVtt(body); }
  const duration = track.duration; const playlist = ['#EXTM3U', '#EXT-X-VERSION:3', `#EXT-X-TARGETDURATION:${duration}`, '#EXT-X-PLAYLIST-TYPE:VOD', `#EXTINF:${duration}.000,`, mediaUrl(id, track.vttUrl), '#EXT-X-ENDLIST', ''].join('\n');
  text(response, 200, playlist, 'application/vnd.apple.mpegurl; charset=utf-8');
}

const server = http.createServer(async (request, response) => {
  const requestUrl = new URL(request.url, `http://${request.headers.host}`);
  try {
    if (requestUrl.pathname === '/health' || requestUrl.pathname.startsWith('/api/')) {
      console.info(`[bridge] ${request.method} ${requestUrl.pathname}`);
    }
    if (request.method === 'GET' && requestUrl.pathname === '/health') return json(response, 200, { ok: true });
    if (request.method === 'GET' && requestUrl.pathname === '/api/search') {
      const results = parseSearch((await providerJson(`/ajax/anime/search?keyword=${encodeURIComponent(requestUrl.searchParams.get('q') ?? '')}`)).html ?? '');
      console.info(`[bridge] Search returned ${results.length} result(s)`);
      return json(response, 200, { results });
    }
    if (request.method === 'POST' && requestUrl.pathname === '/api/series') return json(response, 200, await getSeries(JSON.parse(await readBody(request)).watchUrl));
    const serversRoute = requestUrl.pathname.match(/^\/api\/series\/([\w-]+)\/servers$/);
    if (request.method === 'GET' && serversRoute) return json(response, 200, await getServers(serversRoute[1], requestUrl.searchParams.get('episode')));
    if (request.method === 'POST' && requestUrl.pathname === '/api/play') { const body = JSON.parse(await readBody(request)); return json(response, 201, await createPlayback(body.seriesKey, body.episode, body.serverIndex, request.headers.host)); }
    const watch = requestUrl.pathname.match(/^\/watch\/([\w-]+)\/master\.m3u8$/);
    if (request.method === 'GET' && watch) { const source = sources.get(watch[1]); if (!source) return json(response, 404, { error: 'Unknown or expired source' }); return await sendUpstream(response, source.hlsUrl, watch[1], source, true, request.headers.range); }
    const subtitle = requestUrl.pathname.match(/^\/subtitle\/([\w-]+)\/(\d+)\.m3u8$/);
    if (request.method === 'GET' && subtitle) { const source = sources.get(subtitle[1]); const track = source?.subtitles[Number(subtitle[2])]; if (!track) return json(response, 404, { error: 'Unknown subtitle track' }); return track.playlistUrl ? await sendUpstream(response, track.playlistUrl, subtitle[1], source, false, request.headers.range) : await sendSingleVttPlaylist(response, track, subtitle[1], source); }
    const media = requestUrl.pathname.match(/^\/media\/([\w-]+)$/);
    if (request.method === 'GET' && media) { const source = sources.get(media[1]); const upstream = requestUrl.searchParams.get('url'); if (!source || !upstream) return json(response, 404, { error: 'Unknown media request' }); return await sendUpstream(response, new URL(upstream).toString(), media[1], source, false, request.headers.range); }
    json(response, 404, { error: 'Not found' });
  } catch (error) {
    console.error(`[bridge] ${request.method} ${requestUrl.pathname} failed: ${error.message}`);
    json(response, 502, { error: error.message });
  }
});
server.listen(port, host, () => console.log(`AirPlay Subtitle Bridge: http://${host}:${port}`));
