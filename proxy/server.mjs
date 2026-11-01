import http from 'node:http';
import { createDecipheriv, createHmac, randomUUID } from 'node:crypto';
import { load } from 'cheerio';

const host = process.env.BRIDGE_HOST ?? '0.0.0.0';
const port = Number(process.env.BRIDGE_PORT ?? 8787);
const providerOrigin = Buffer.from('aHR0cHM6Ly9hbmlrb3RvdHYudG8=', 'base64').toString('utf8');
const sources = new Map();
const seriesCache = new Map();
const cdnTokenSecret = 'MpCdnT0k3n!9f2K#xQ7vL5mR8wN1pY4s';
const sourceEncKey = 'i?LMTAx0Q6,:}50U';
const sourceEncIv = "W0;27ToaUpl_P%'c";
const playerUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0';

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
function base64Url(value) { return Buffer.from(value).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, ''); }
function playlistDescriptor(value) {
  const url = new URL(value); const token = url.searchParams.get('token'); let expiresIn = null;
  try {
    const payload = Buffer.from(String(token ?? '').split('.')[0], 'base64url').toString('utf8');
    const expiry = Number(payload.split('|')[0]); if (Number.isFinite(expiry)) expiresIn = expiry - Math.floor(Date.now() / 1000);
  } catch { /* Diagnostics deliberately omit token values. */ }
  return `${url.hostname} token=${token ? 'yes' : 'no'}${expiresIn === null ? '' : ` expiresIn=${expiresIn}s`}`;
}
function attachCdnToken(value) {
  const url = new URL(value);
  if (url.searchParams.has('token')) return url.toString();
  const match = url.pathname.match(/\/([a-f0-9]{32})\/([a-f0-9]{32})\//i);
  if (!match) return url.toString();
  const expiresAt = Math.floor(Date.now() / 1000) + 90;
  const payload = `${expiresAt}|${match[1].toLowerCase()}/${match[2].toLowerCase()}`;
  const signature = createHmac('sha256', cdnTokenSecret).update(payload).digest();
  url.searchParams.set('token', `${base64Url(payload)}.${base64Url(signature)}`);
  return url.toString();
}
function paddedKey(value, length) {
  const result = Buffer.alloc(length); Buffer.from(value, 'utf8').copy(result); return result;
}
function decryptPlayerSources(value) {
  const encoded = String(value).replace(/-/g, '+').replace(/_/g, '/');
  const encrypted = Buffer.from(encoded + '='.repeat((4 - (encoded.length % 4)) % 4), 'base64');
  const decipher = createDecipheriv('aes-256-cbc', paddedKey(sourceEncKey, 32), paddedKey(sourceEncIv, 16));
  return JSON.parse(Buffer.concat([decipher.update(encrypted), decipher.final()]).toString('utf8'));
}
function resolveStreamFile(sources) {
  if (typeof sources === 'string') return sources;
  if (Array.isArray(sources)) return resolveStreamFile(sources[0]);
  return typeof sources?.file === 'string' ? sources.file : null;
}
function subtitleLanguage(track) {
  const value = `${track?.label ?? ''} ${track?.kind ?? ''}`.toLowerCase();
  if (/spanish|espa[nñ]ol|\bes\b/.test(value)) return 'es';
  if (/english|\ben\b/.test(value)) return 'en';
  return 'und';
}
async function resolvePlayerSource(embedUrl) {
  const page = await fetchWithTimeout(embedUrl, { headers: { Accept: 'text/html', Referer: `${providerOrigin}/`, 'User-Agent': playerUserAgent } }, 15000, 'Player page request');
  if (!page.ok) throw new Error(`Player page HTTP ${page.status}`);
  const $ = load(await page.text()); const player = $('#megaplay-player').first(); const episodeId = player.attr('data-id');
  if (!episodeId) throw new Error('Player episode identifier was not found');
  const playerOrigin = new URL(embedUrl).origin;
  const sourceUrl = new URL('/stream/getSources', playerOrigin); sourceUrl.searchParams.set('id', episodeId);
  console.info('[bridge] Loading public player source metadata');
  const sourceResponse = await fetchWithTimeout(sourceUrl, {
    headers: { Accept: 'application/json, text/javascript, */*; q=0.01', Referer: embedUrl, Origin: playerOrigin, 'User-Agent': playerUserAgent, 'X-Requested-With': 'XMLHttpRequest' },
  }, 15000, 'Player source request');
  if (!sourceResponse.ok) throw new Error(`Player source HTTP ${sourceResponse.status}`);
  const sourcePayload = await sourceResponse.json();
  const sources = sourcePayload.enc ? decryptPlayerSources(sourcePayload.enc) : sourcePayload.sources;
  const file = resolveStreamFile(sources);
  if (!file) throw new Error('Player source did not include an HLS file');
  const hlsUrl = attachCdnToken(absoluteUrl(file, playerOrigin));
  const tracks = Array.isArray(sourcePayload.tracks) ? sourcePayload.tracks : [];
  const subtitles = tracks.map((track, index) => ({
    name: cleanText(track?.label) || `Subtitles ${index + 1}`,
    language: subtitleLanguage(track),
    vttUrl: absoluteUrl(track?.file ?? '', playerOrigin),
    default: index === 0,
  })).filter((track) => track.vttUrl && new URL(track.vttUrl).pathname.toLowerCase().endsWith('.vtt'));
  console.info(`[bridge] Public source metadata returned ${subtitles.length} subtitle track(s)`);
  console.info(`[bridge] HLS candidate: ${playlistDescriptor(hlsUrl)}`);
  return {
    hlsUrl,
    requestHeaders: { Referer: `${playerOrigin}/`, Origin: playerOrigin, 'User-Agent': playerUserAgent, Accept: '*/*', 'Accept-Language': 'en-US,en;q=0.9' },
    subtitles,
  };
}
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
async function createPlayback(seriesKey, episodeNumber, serverIndex, requestHost) {
  const series = cachedSeries(seriesKey);
  if (!series.lastServers || series.lastServers.episodeNumber !== Number(episodeNumber)) await getServers(seriesKey, episodeNumber);
  const server = series.lastServers.servers.find((candidate) => candidate.index === Number(serverIndex)); if (!server) throw new Error('Server was not found');
  console.info(`[bridge] Resolving episode ${episodeNumber}, ${server.type.toUpperCase()} server ${server.name}`);
  const reply = await providerJson(`/ajax/server?get=${encodeURIComponent(server.linkId)}`);
  if (!reply?.url) throw new Error('Player URL was not returned');
  console.info('[bridge] Player URL returned; resolving public source metadata');
  const media = await resolvePlayerSource(reply.url);
  const id = randomUUID(); sources.set(id, media);
  const expiry = setTimeout(() => { sources.delete(id); }, 2 * 60 * 60 * 1000);
  expiry.unref();
  console.info(`[bridge] Playback ready with ${media.subtitles.length} subtitle track(s)`);
  return { playbackUrl: `http://${requestHost}/watch/${id}/master.m3u8`, subtitleTracks: media.subtitles.length, serverName: server.name };
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
function removePlayerTransportPrefix(url, body) {
  // This mirrors the public player’s SegmentStrip behavior for the affected
  // CDNs. It removes only its documented fixed transport prefix, never media
  // content, credentials, or DRM data.
  const hostname = new URL(url).hostname;
  return /(?:ibyteimg\.com|tiktokcdn\.com|ipstatp\.com|yoot\.akirax\.buzz)$/i.test(hostname) && body.length > 252 ? body.subarray(252) : body;
}
async function fetchUpstream(url, source, range) {
  const headers = { ...source.requestHeaders, ...(range ? { range } : {}) };
  const response = await fetch(url, { redirect: 'follow', headers });
  if (!response.ok) throw new Error(`Upstream responded ${response.status}`);
  return { url: response.url, type: response.headers.get('content-type') ?? '', body: Buffer.from(await response.arrayBuffer()) };
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
