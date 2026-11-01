import http from 'node:http';
import { createDecipheriv, createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
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
const bridgeUsers = configuredBridgeUsers();
const bridgeAdminToken = cleanText(process.env.BRIDGE_ADMIN_TOKEN);
const historyStorePath = resolve(process.env.HISTORY_STORE_PATH ?? `${process.cwd()}/data/history.json`);
const userStorePath = resolve(process.env.BRIDGE_USER_STORE_PATH ?? `${process.cwd()}/data/users.json`);
const mediaUrlSigningKey = randomUUID();
let historyUsers;
let historyMutation = Promise.resolve();
let persistedUsers;
let userMutation = Promise.resolve();

function json(response, status, body) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  response.end(JSON.stringify(body));
}
function text(response, status, body, type = 'text/plain; charset=utf-8') {
  response.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' }); response.end(body);
}
function absoluteUrl(value, parent) { return new URL(value, parent).toString(); }
function protectedPath(path, accessToken) {
  if (!accessToken) return path;
  return `${path}${path.includes('?') ? '&' : '?'}access_token=${encodeURIComponent(accessToken)}`;
}
function mediaUrlSignature(id, upstream) { return createHmac('sha256', mediaUrlSigningKey).update(`${id}\n${upstream}`).digest('base64url'); }
function mediaUrl(id, upstream, accessToken) { return protectedPath(`/media/${id}?url=${encodeURIComponent(upstream)}&sig=${mediaUrlSignature(id, upstream)}`, accessToken); }
function isPlaylist(url, contentType) { return new URL(url).pathname.toLowerCase().endsWith('.m3u8') || contentType.includes('mpegurl'); }
function cleanText(value) { return String(value ?? '').replace(/\s+/g, ' ').trim(); }
function normalizedUserId(value) {
  const userId = cleanText(value).toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{0,39}$/.test(userId)) throw new Error('Bridge user IDs must use 1-40 lowercase letters, numbers, hyphens, or underscores');
  return userId;
}
function configuredBridgeUsers() {
  const configured = cleanText(process.env.BRIDGE_USER_TOKENS);
  if (configured) {
    let entries;
    try { entries = Object.entries(JSON.parse(configured)); } catch { throw new Error('BRIDGE_USER_TOKENS must be a JSON object of user IDs to tokens'); }
    if (!entries.length) throw new Error('BRIDGE_USER_TOKENS cannot be empty');
    const users = entries.map(([userId, token]) => ({ userId: normalizedUserId(userId), token: cleanText(token) }));
    if (users.some((user) => !user.token) || new Set(users.map((user) => user.userId)).size !== users.length) throw new Error('BRIDGE_USER_TOKENS contains an invalid user or token');
    return users;
  }
  const token = cleanText(process.env.BRIDGE_ACCESS_TOKEN);
  return token ? [{ userId: 'default', token }] : [];
}
function sameSecret(left, right) {
  const leftBuffer = Buffer.from(String(left)); const rightBuffer = Buffer.from(String(right));
  return leftBuffer.length === rightBuffer.length && timingSafeEqual(leftBuffer, rightBuffer);
}
function requestedAccessToken(request, requestUrl) {
  const authorization = cleanText(request.headers.authorization);
  const bearer = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
  return cleanText(request.headers['x-bridge-token'] ?? bearer ?? requestUrl.searchParams.get('access_token'));
}
function tokenHash(token, salt) { return createHash('sha256').update(`${salt}:${token}`).digest('hex'); }
function requestedAdminToken(request) { return cleanText(request.headers['x-bridge-admin-token']); }
function isAdministrator(request) { return Boolean(bridgeAdminToken) && sameSecret(requestedAdminToken(request), bridgeAdminToken); }
async function loadPersistedUsers() {
  if (persistedUsers) return persistedUsers;
  persistedUsers = [];
  try {
    const parsed = JSON.parse(await readFile(userStorePath, 'utf8'));
    const users = Array.isArray(parsed?.users) ? parsed.users : [];
    persistedUsers = users.flatMap((user) => {
      try {
        const userId = normalizedUserId(user?.userId);
        const salt = cleanText(user?.salt); const hash = cleanText(user?.tokenHash);
        if (!/^[a-f0-9]{32}$/i.test(salt) || !/^[a-f0-9]{64}$/i.test(hash)) return [];
        return [{ userId, salt, tokenHash: hash, label: historyText(user?.label, 'Private user', 80), createdAt: cleanText(user?.createdAt) }];
      } catch { return []; }
    });
  } catch (error) {
    if (error?.code !== 'ENOENT') console.warn(`[bridge] User store could not be read: ${error.message}`);
  }
  return persistedUsers;
}
function validUserToken(value) { return /^[a-f0-9]{64}$/i.test(value); }
async function registerUser(token, label) {
  if (!validUserToken(token)) throw new Error('User token must be a 64-character hexadecimal value');
  await loadPersistedUsers();
  userMutation = userMutation.then(async () => {
    const users = await loadPersistedUsers();
    if (bridgeUsers.some((user) => sameSecret(token, user.token))) throw new Error('This token is reserved by bridge configuration');
    const existing = users.find((user) => sameSecret(user.tokenHash, tokenHash(token, user.salt)));
    if (existing) return existing;
    if (users.length >= 1000) throw new Error('User limit reached');
    const user = { userId: randomUUID(), salt: randomBytes(16).toString('hex'), tokenHash: '', label: historyText(label, 'Private user', 80), createdAt: new Date().toISOString() };
    user.tokenHash = tokenHash(token, user.salt);
    users.push(user);
    await mkdir(dirname(userStorePath), { recursive: true });
    const temporaryPath = `${userStorePath}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(temporaryPath, JSON.stringify({ version: 1, users }), 'utf8');
    await rename(temporaryPath, userStorePath);
    return user;
  });
  return userMutation;
}
async function authenticatedUser(request, requestUrl) {
  const token = requestedAccessToken(request, requestUrl);
  const configuredUser = bridgeUsers.find((user) => sameSecret(token, user.token));
  if (configuredUser) return configuredUser;
  const users = await loadPersistedUsers();
  const storedUser = users.find((user) => sameSecret(user.tokenHash, tokenHash(token, user.salt)));
  if (storedUser) return { userId: storedUser.userId, token };
  return !bridgeUsers.length && !users.length && !bridgeAdminToken ? { userId: 'local', token: '' } : null;
}
function forwardedValue(request, name) { return cleanText(request.headers[name]).split(',')[0].trim(); }
function requestOrigin(request) {
  const forwardedProtocol = forwardedValue(request, 'x-forwarded-proto');
  const protocol = forwardedProtocol === 'https' ? 'https' : 'http';
  const authority = forwardedValue(request, 'x-forwarded-host') || cleanText(request.headers.host);
  if (!authority) throw new Error('Request host was not provided');
  return `${protocol}://${authority}`;
}
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
function subtitleDetails(track, index) {
  // The provider often labels tracks as “Unknown language”.  Derive both the
  // user-facing name and BCP-47 tag from the label, srclang, and VTT filename.
  // Apple otherwise folds all `und` tracks into a single Unknown entry.
  const suppliedLabel = cleanText(track?.label);
  const value = `${suppliedLabel} ${track?.srclang ?? ''} ${track?.file ?? ''}`.toLowerCase();
  const hasText = (pattern) => pattern.test(value);
  const hasToken = (...tokens) => tokens.some((token) => new RegExp(`(?:^|[\\s_./-])${token}(?=$|[\\s_./-])`, 'i').test(value));
  const qualifiers = [];
  const addQualifier = (name, pattern) => { if (hasText(pattern) && !qualifiers.includes(name)) qualifiers.push(name); };
  addQualifier('Latin American', /latin[\s_-]*american/);
  addQualifier('European', /(?:^|[\s_./-])european(?=$|[\s_./-])/);
  addQualifier('Brazilian', /(?:^|[\s_./-])brazilian(?=$|[\s_./-])/);
  if (!qualifiers.includes('Latin American')) addQualifier('Latin', /(?:^|[\s_./-])latin(?=$|[\s_./-])/);
  addQualifier('Forced', /(?:^|[\s_./-])forced(?=$|[\s_./-])/);
  addQualifier('Dubtitle', /(?:^|[\s_./-])dubtitle(?=$|[\s_./-])/);
  addQualifier('SDH', /(?:^|[\s_./-])sdh(?=$|[\s_./-])/);
  addQualifier('CC', /(?:^|[\s_./-])cc(?=$|[\s_./-])|closed[\s_-]*captions?/);
  const named = (name, language, extra = []) => {
    const descriptors = [...extra, ...qualifiers];
    return { name: descriptors.length ? `${name} (${descriptors.join(', ')})` : name, language };
  };

  const chinese = hasText(/chinese|中文/) || hasToken('chi', 'zho', 'cmn', 'yue', 'zht', 'zhs', 'cht');
  if (chinese) {
    const traditional = hasText(/traditional|hant/) || hasToken('zht', 'cht');
    return named('Chinese', traditional ? 'zh-Hant' : 'zh-Hans', [traditional ? 'Traditional' : 'Simplified']);
  }

  const languages = [
    ['English', 'en', ['english', 'eng', 'en']], ['Spanish', 'es', ['spanish', 'español', 'espanol', 'spa', 'es']],
    ['French', 'fr', ['french', 'français', 'francais', 'fre', 'fra', 'fr']], ['German', 'de', ['german', 'deutsch', 'ger', 'deu', 'de']],
    ['Italian', 'it', ['italian', 'ita', 'it']], ['Portuguese', 'pt', ['portuguese', 'português', 'portugues', 'por', 'pt']],
    ['Polish', 'pl', ['polish', 'pol', 'pl']], ['Russian', 'ru', ['russian', 'русский', 'rus', 'ru']],
    ['Ukrainian', 'uk', ['ukrainian', 'ukr', 'uk']], ['Arabic', 'ar', ['arabic', 'ara', 'ar']],
    ['Indonesian', 'id', ['indonesian', 'ind', 'id']], ['Japanese', 'ja', ['japanese', 'jpn', 'ja']],
    ['Korean', 'ko', ['korean', 'kor', 'ko']], ['Malay', 'ms', ['malay', 'may', 'msa', 'ms']],
    ['Thai', 'th', ['thai', 'tha', 'th']], ['Vietnamese', 'vi', ['vietnamese', 'vie', 'vi']],
    ['Chinese', 'zh-Hans', ['simplified', 'chi', 'zho']], ['Turkish', 'tr', ['turkish', 'tur', 'tr']],
    ['Hindi', 'hi', ['hindi', 'hin', 'hi']], ['Bengali', 'bn', ['bengali', 'ben', 'bn']],
    ['Dutch', 'nl', ['dutch', 'nederlands', 'dut', 'nld', 'nl']], ['Swedish', 'sv', ['swedish', 'swe', 'sv']],
    ['Danish', 'da', ['danish', 'dan', 'da']], ['Finnish', 'fi', ['finnish', 'fin', 'fi']],
    ['Norwegian', 'no', ['norwegian', 'nor', 'no']], ['Norwegian (Bokmål)', 'nb', ['nob', 'nb']], ['Czech', 'cs', ['czech', 'ces', 'cze', 'cs']],
    ['Romanian', 'ro', ['romanian', 'română', 'romana', 'ron', 'rum', 'ro']], ['Hungarian', 'hu', ['hungarian', 'hun', 'hu']],
    ['Greek', 'el', ['greek', 'ell', 'gre', 'el']], ['Hebrew', 'he', ['hebrew', 'heb', 'he']],
    ['Persian', 'fa', ['persian', 'farsi', 'fas', 'per', 'fa']], ['Filipino', 'fil', ['filipino', 'tagalog', 'fil', 'tgl']],
    ['Tamil', 'ta', ['tamil', 'tam', 'ta']], ['Telugu', 'te', ['telugu', 'tel', 'te']], ['Urdu', 'ur', ['urdu', 'urd', 'ur']],
    ['Catalan', 'ca', ['catalan', 'cat', 'ca']], ['Basque', 'eu', ['basque', 'euskara', 'baq', 'eus', 'eu']],
    ['Galician', 'gl', ['galician', 'glg', 'gl']], ['Croatian', 'hr', ['croatian', 'hrv', 'hr']],
    ['Bulgarian', 'bg', ['bulgarian', 'bul', 'bg']], ['Serbian', 'sr', ['serbian', 'srp', 'sr']],
    ['Slovak', 'sk', ['slovak', 'slk', 'slo', 'sk']], ['Slovenian', 'sl', ['slovenian', 'slv', 'sl']],
    ['Lithuanian', 'lt', ['lithuanian', 'lit', 'lt']], ['Latvian', 'lv', ['latvian', 'lav', 'lv']],
    ['Estonian', 'et', ['estonian', 'est', 'et']], ['Icelandic', 'is', ['icelandic', 'isl', 'ice', 'is']],
    ['Welsh', 'cy', ['welsh', 'cym', 'wel', 'cy']],
  ];
  for (const [name, language, aliases] of languages) {
    if (aliases.some((alias) => hasText(new RegExp(`\\b${alias}\\b`, 'i')) || hasToken(alias))) {
      const latinAmerican = qualifiers.includes('Latin American'); const european = qualifiers.includes('European'); const brazilian = qualifiers.includes('Brazilian');
      const regionalLanguage = name === 'Spanish' && latinAmerican ? 'es-419'
        : name === 'Spanish' && european ? 'es-ES'
          : name === 'French' && european ? 'fr-FR'
            : name === 'Portuguese' && brazilian ? 'pt-BR'
              : name === 'Portuguese' && european ? 'pt-PT' : language;
      return named(name, regionalLanguage);
    }
  }

  const usableLabel = /^(?:unknown(?: language)?|subtitles?(?:\s+\d+)?)$/i.test(suppliedLabel) ? '' : suppliedLabel;
  return { name: usableLabel || `Subtitles ${index + 1}`, language: 'und' };
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
  const subtitles = tracks
    .filter((track) => /^(captions|subtitles)$/i.test(cleanText(track?.kind)))
    .map((track, index) => ({
      ...subtitleDetails(track, index),
      vttUrl: absoluteUrl(track?.file ?? '', playerOrigin),
    }))
    .filter((track) => track.vttUrl && new URL(track.vttUrl).pathname.toLowerCase().endsWith('.vtt'));
  const defaultIndex = subtitles.findIndex((track) => track.language === 'en');
  subtitles.forEach((track, index) => { track.default = index === (defaultIndex >= 0 ? defaultIndex : 0); });
  console.info(`[bridge] Public source metadata returned ${subtitles.length} subtitle track(s)`);
  console.info(`[bridge] HLS candidate: ${playlistDescriptor(hlsUrl)}`);
  return {
    hlsUrl,
    intro: validSkipRange(sourcePayload.intro),
    outro: validSkipRange(sourcePayload.outro),
    requestHeaders: { Referer: `${playerOrigin}/`, Origin: playerOrigin, 'User-Agent': playerUserAgent, Accept: '*/*', 'Accept-Language': 'en-US,en;q=0.9' },
    subtitles,
  };
}
function validSkipRange(value) {
  const start = Number(value?.start), end = Number(value?.end);
  return value && Number.isFinite(start) && Number.isFinite(end) && start >= 0 && end > start ? { start, end } : null;
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
function historyDate(value) {
  // Swift's default JSONEncoder encodes Date as seconds since 2001-01-01.
  if (typeof value === 'number' && Number.isFinite(value)) return new Date((value + 978307200) * 1000);
  const parsed = new Date(value);
  return Number.isNaN(parsed.valueOf()) ? new Date() : parsed;
}
function historyTimestamp(date) {
  return (new Date(date).valueOf() / 1000) - 978307200;
}
function historyText(value, fallback = '', maximum = 500) {
  return cleanText(value).slice(0, maximum) || fallback;
}
function normalizeHistoryEntry(value) {
  const watchUrl = requireProviderUrl(historyText(value?.watchUrl, '', 2000)).toString();
  const episode = Number(value?.episode);
  if (!Number.isInteger(episode) || episode < 1 || episode > 100000) throw new Error('History episode is invalid');
  const position = Number(value?.positionSeconds);
  return {
    seriesTitle: historyText(value?.seriesTitle, 'Untitled'),
    titleJp: value?.titleJp ? historyText(value.titleJp, '', 500) : null,
    watchUrl,
    imageUrl: value?.imageUrl ? historyText(value.imageUrl, '', 2000) : null,
    episode,
    episodeTitle: historyText(value?.episodeTitle, `Episode ${episode}`),
    serverName: historyText(value?.serverName, ''),
    positionSeconds: Number.isFinite(position) ? Math.max(0, position) : 0,
    updatedAt: historyDate(value?.updatedAt).toISOString(),
  };
}
function normalizeHistoryDeletion(value) {
  return {
    watchUrl: requireProviderUrl(historyText(value?.watchUrl, '', 2000)).toString(),
    updatedAt: historyDate(value?.updatedAt).toISOString(),
  };
}
function historyKey(entry) { return entry.watchUrl; }
function serializeHistoryEntry(entry) {
  return { ...entry, updatedAt: historyTimestamp(entry.updatedAt) };
}
function serializeHistoryDeletion(deletion) {
  return { ...deletion, updatedAt: historyTimestamp(deletion.updatedAt) };
}
function historyState(entries = [], deletions = []) {
  const latestEntries = new Map(); const latestDeletions = new Map();
  for (const entry of entries) {
    const previous = latestEntries.get(historyKey(entry));
    if (!previous || new Date(entry.updatedAt) >= new Date(previous.updatedAt)) latestEntries.set(historyKey(entry), entry);
  }
  for (const deletion of deletions) {
    const previous = latestDeletions.get(deletion.watchUrl);
    if (!previous || new Date(deletion.updatedAt) >= new Date(previous.updatedAt)) latestDeletions.set(deletion.watchUrl, deletion);
  }
  for (const [watchUrl, deletion] of latestDeletions) {
    const entry = latestEntries.get(watchUrl);
    if (entry && new Date(entry.updatedAt) > new Date(deletion.updatedAt)) latestDeletions.delete(watchUrl);
    else latestEntries.delete(watchUrl);
  }
  return {
    entries: [...latestEntries.values()].sort((left, right) => new Date(right.updatedAt) - new Date(left.updatedAt)).slice(0, 100),
    deletions: [...latestDeletions.values()].sort((left, right) => new Date(right.updatedAt) - new Date(left.updatedAt)).slice(0, 500),
  };
}
function serializeHistoryState(state) {
  return { entries: state.entries.map(serializeHistoryEntry), deletions: state.deletions.map(serializeHistoryDeletion) };
}
async function loadHistory() {
  if (historyUsers) return historyUsers;
  historyUsers = new Map();
  try {
    const parsed = JSON.parse(await readFile(historyStorePath, 'utf8'));
    const rawUsers = parsed?.users && typeof parsed.users === 'object'
      ? parsed.users
      : parsed?.profiles && typeof parsed.profiles === 'object'
        ? parsed.profiles
      : { default: Array.isArray(parsed?.entries) ? parsed.entries : [] };
    for (const [userId, value] of Object.entries(rawUsers)) {
      const normalizedUser = normalizedUserId(userId);
      const rawEntries = Array.isArray(value) ? value : value?.entries;
      const rawDeletions = Array.isArray(value) ? [] : value?.deletions;
      if (!Array.isArray(rawEntries)) continue;
      const normalizedEntries = []; const normalizedDeletions = [];
      for (const entry of rawEntries) {
        try { normalizedEntries.push(normalizeHistoryEntry(entry)); } catch { /* Ignore corrupted history rows. */ }
      }
      for (const deletion of Array.isArray(rawDeletions) ? rawDeletions : []) {
        try { normalizedDeletions.push(normalizeHistoryDeletion(deletion)); } catch { /* Ignore corrupted deletion rows. */ }
      }
      historyUsers.set(normalizedUser, historyState(normalizedEntries, normalizedDeletions));
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') console.warn(`[bridge] History store could not be read: ${error.message}`);
  }
  return historyUsers;
}
async function storedHistory(userId) {
  await historyMutation; const users = await loadHistory();
  return serializeHistoryState(users.get(userId) ?? historyState());
}
async function mergeHistory(userId, payload) {
  if (!Array.isArray(payload?.entries) || payload.entries.length > 100 || (payload.deletions && (!Array.isArray(payload.deletions) || payload.deletions.length > 500))) {
    throw new Error('History payload is invalid');
  }
  const incomingEntries = payload.entries.map(normalizeHistoryEntry);
  const incomingDeletions = (payload.deletions ?? []).map(normalizeHistoryDeletion);
  historyMutation = historyMutation.then(async () => {
    const users = await loadHistory(); const existing = users.get(userId) ?? historyState();
    const merged = historyState([...existing.entries, ...incomingEntries], [...existing.deletions, ...incomingDeletions]);
    users.set(userId, merged);
    await mkdir(dirname(historyStorePath), { recursive: true });
    const temporaryPath = `${historyStorePath}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(temporaryPath, JSON.stringify({ version: 4, users: Object.fromEntries(users) }), 'utf8');
    await rename(temporaryPath, historyStorePath);
    return merged;
  });
  return serializeHistoryState(await historyMutation);
}

function parseSearch(html) {
  const $ = load(html); const seen = new Set(); const results = [];
  $('a.item[href*="/watch/"]').each((_, node) => {
    const url = new URL($(node).attr('href'), providerOrigin).toString();
    if (seen.has(url)) return; seen.add(url);
    const metaItems = $(node).find('.meta').first().children().map((_, child) => ({
      text: cleanText($(child).text()),
      classes: String($(child).attr('class') ?? ''),
    })).get();
    const rating = metaItems.find((item) => /(?:^|\s)rating(?:\s|$)/i.test(item.classes))?.text ?? null;
    const scoreText = metaItems.find((item) => /(?:^|\s)text-gray2(?:\s|$)/i.test(item.classes))?.text ?? '';
    const score = /^\d+(?:\.\d+)?$/.test(scoreText) ? Number(scoreText) : null;
    const mediaType = metaItems.map((item) => item.text).find((item) => /^(TV|Movie|ONA|OVA|Special)$/i.test(item)) ?? null;
    const yearText = metaItems.map((item) => item.text).find((item) => /^\d{4}$/.test(item)) ?? '';
    results.push({
      title: cleanText($(node).find('.name').first().text()) || 'Untitled', watchUrl: url,
      titleJp: cleanText($(node).find('.name').first().attr('data-jp')) || null,
      imageUrl: $(node).find('img').first().attr('src') ? absoluteUrl($(node).find('img').first().attr('src'), providerOrigin) : null,
      meta: cleanText($(node).find('.meta').text()),
      rating, score, mediaType, year: yearText ? Number(yearText) : null,
    });
  });
  return results;
}
async function latestUpdated(params) {
  const page = Math.max(1, Math.min(10000, Number.parseInt(params.get('page') || '1', 10) || 1));
  const season = params.get('season') || '', status = params.get('status') || '';
  const rating = params.get('rating') || '', mediaType = params.get('mediaType') || '', year = params.get('year') || '';
  const keyword = cleanText(params.get('q')).slice(0, 200);
  if (season && !['winter', 'spring', 'summer', 'fall'].includes(season)) throw new Error('Invalid season');
  if (status && !['finished-airing', 'currently-airing', 'not-yet-aired'].includes(status)) throw new Error('Invalid status');
  if (rating && !['G', 'PG', 'PG-13', 'R', 'R+', 'Rx'].includes(rating)) throw new Error('Invalid rating');
  if (mediaType && !['TV', 'Movie', 'ONA', 'OVA', 'Special'].includes(mediaType)) throw new Error('Invalid media type');
  if (year && !/^\d{4}$/.test(year)) throw new Error('Invalid year');
  const url = new URL(season || status || keyword || rating || mediaType || year ? '/filter' : '/latest-updated', providerOrigin);
  url.searchParams.set('page', String(page));
  if (season || status || keyword || rating || mediaType || year) {
    url.searchParams.set('sort', keyword ? 'default' : 'latest-updated');
    if (keyword) url.searchParams.set('keyword', keyword);
    if (season) url.searchParams.append('season[]', season);
    if (status) url.searchParams.append('status[]', status);
    if (rating) url.searchParams.append('rating[]', rating);
    if (mediaType) url.searchParams.append('term_type[]', mediaType);
    if (year) url.searchParams.append('year[]', year);
  }
  const response = await fetchWithTimeout(url, { headers: { Accept: 'text/html' } }, 15000, 'Latest catalog request');
  if (!response.ok) throw new Error(`Catalog HTTP ${response.status}`);
  const $ = load(await response.text()); const results = [];
  $('.ani.poster').each((_, node) => {
    const card = $(node).parent(), name = card.find('a.name.d-title').first();
    const href = name.attr('href') || $(node).find('a').first().attr('href');
    if (!href) return;
    const watch = requireProviderUrl(href); const episode = Number(watch.pathname.match(/\/ep-(\d+)\/?$/)?.[1]) || null;
    watch.pathname = watch.pathname.replace(/\/ep-\d+\/?$/, ''); watch.search = '';
    const src = $(node).find('img').first().attr('src');
    const scoreValue = Number(cleanText(card.find('.info .meta .rated span').first().text()));
    results.push({ title: cleanText(name.text()) || 'Untitled', titleJp: cleanText(name.attr('data-jp')) || null, watchUrl: watch.toString(), imageUrl: src ? absoluteUrl(src, providerOrigin) : null, meta: cleanText(card.find('.info .meta').text()), rating: null, score: scoreValue > 0 ? scoreValue : null, mediaType: cleanText($(node).find('.right').text()) || null, year: null, episode });
  });
  return { results, page, hasNext: $('a[rel=next]').length > 0 };
}
function normalizedTitle(value) {
  return cleanText(value)
    .normalize('NFD').replace(/\p{Diacritic}/gu, '')
    .toLowerCase().replace(/[^\p{Letter}\p{Number}]+/gu, ' ')
    .replace(/\s+/g, ' ').trim();
}
function seasonIdentity(title) {
  let base = cleanText(title); let seasonNumber = null;
  const patterns = [
    /\bseason\s*(\d+)\b/i,
    /\bs\s*(\d+)\b/i,
    /\b(\d+)(?:st|nd|rd|th)\s+season\b/i,
  ];
  for (const pattern of patterns) {
    const match = base.match(pattern);
    if (!match) continue;
    seasonNumber = Number(match[1]);
    base = cleanText(base.replace(pattern, ''));
    break;
  }
  return { base, baseKey: normalizedTitle(base), seasonNumber };
}
function seasonRecord(anime) {
  return { ...anime, seasonNumber: seasonIdentity(anime.title).seasonNumber ?? 1 };
}
async function discoverRelatedSeasons(series) {
  const identity = seasonIdentity(series.title);
  if (identity.baseKey.length < 3) return [seasonRecord(series)];
  try {
    const searchMarkup = (await providerJson(`/ajax/anime/search?keyword=${encodeURIComponent(identity.base)}`)).html ?? '';
    const candidates = parseSearch(searchMarkup).filter((candidate) => seasonIdentity(candidate.title).baseKey === identity.baseKey);
    if (!candidates.some((candidate) => candidate.watchUrl === series.watchUrl)) {
      candidates.push({ title: series.title, watchUrl: series.watchUrl, imageUrl: null, meta: '' });
    }
    const unique = [...new Map(candidates.map((candidate) => [candidate.watchUrl, seasonRecord(candidate)])).values()];
    return unique.sort((left, right) => left.seasonNumber - right.seasonNumber || left.title.localeCompare(right.title));
  } catch (error) {
    console.warn(`[bridge] Related season lookup failed: ${error.message}`);
    return [seasonRecord(series)];
  }
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
  const seasons = await discoverRelatedSeasons(series);
  const key = randomUUID(); seriesCache.set(key, { ...series, episodes, seasons, expiresAt: Date.now() + 20 * 60 * 1000 });
  console.info(`[bridge] Loaded ${series.title}: ${episodes.length} episode(s), ${seasons.length} related season(s)`);
  return { seriesKey: key, title: series.title, episodes: episodes.map(({ number, title }) => ({ number, title })), seasons };
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
async function createPlayback(seriesKey, episodeNumber, serverIndex, playbackOrigin, user) {
  const series = cachedSeries(seriesKey);
  if (!series.lastServers || series.lastServers.episodeNumber !== Number(episodeNumber)) await getServers(seriesKey, episodeNumber);
  const server = series.lastServers.servers.find((candidate) => candidate.index === Number(serverIndex)); if (!server) throw new Error('Server was not found');
  console.info(`[bridge] Resolving episode ${episodeNumber}, ${server.type.toUpperCase()} server ${server.name}`);
  const reply = await providerJson(`/ajax/server?get=${encodeURIComponent(server.linkId)}`);
  if (!reply?.url) throw new Error('Player URL was not returned');
  console.info('[bridge] Player URL returned; resolving public source metadata');
  const media = await resolvePlayerSource(reply.url);
  const id = randomUUID(); sources.set(id, { ...media, userId: user.userId, accessToken: user.token });
  const expiry = setTimeout(() => { sources.delete(id); }, 2 * 60 * 60 * 1000);
  expiry.unref();
  console.info(`[bridge] Playback ready with ${media.subtitles.length} subtitle track(s)`);
  return { playbackUrl: `${playbackOrigin}${protectedPath(`/watch/${id}/master.m3u8`, user.token)}`, subtitleTracks: media.subtitles.length, serverName: server.name, serverKind: server.type, intro: media.intro, outro: media.outro };
}

function rewriteUriLines(textValue, baseUrl, id, source) {
  return textValue.split(/\r?\n/).map((line) => {
    const value = line.trim(); if (!value) return line;
    if (!value.startsWith('#')) return mediaUrl(id, absoluteUrl(value, baseUrl), source.accessToken);
    return line.replace(/URI="([^"]+)"/g, (match, uri) => uri.startsWith('/subtitle/') ? match : `URI="${mediaUrl(id, absoluteUrl(uri, baseUrl), source.accessToken)}"`);
  }).join('\n');
}
function injectSubtitles(master, source, id) {
  const tracks = source.subtitles ?? []; if (!tracks.length || /TYPE=SUBTITLES/.test(master)) return master;
  const declarations = tracks.map((track, index) => `#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="bridge-subs",NAME="${track.name.replaceAll('"', '')}",LANGUAGE="${track.language.replaceAll('"', '')}",DEFAULT=${track.default ? 'YES' : 'NO'},AUTOSELECT=YES,URI="${protectedPath(`/subtitle/${id}/${index}.m3u8`, source.accessToken)}"`);
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
  let playlist = upstream.body.toString('utf8'); const manifestStart = playlist.indexOf('#EXTM3U'); if (manifestStart > 0) playlist = playlist.slice(manifestStart); if (inject) playlist = injectSubtitles(playlist, source, id); playlist = rewriteUriLines(playlist, upstream.url, id, source);
  text(response, 200, playlist, 'application/vnd.apple.mpegurl; charset=utf-8');
}
async function sendSingleVttPlaylist(response, track, id, source) {
  if (!track.duration) { const vtt = await fetchUpstream(track.vttUrl, source); const body = vtt.body.toString('utf8'); if (!/^WEBVTT(?:\r?\n|$)/.test(body)) throw new Error('Subtitle did not return WebVTT'); track.duration = durationFromVtt(body); }
  const duration = track.duration; const playlist = ['#EXTM3U', '#EXT-X-VERSION:3', `#EXT-X-TARGETDURATION:${duration}`, '#EXT-X-PLAYLIST-TYPE:VOD', `#EXTINF:${duration}.000,`, mediaUrl(id, track.vttUrl, source.accessToken), '#EXT-X-ENDLIST', ''].join('\n');
  text(response, 200, playlist, 'application/vnd.apple.mpegurl; charset=utf-8');
}

const server = http.createServer(async (request, response) => {
  const requestUrl = new URL(request.url, `http://${request.headers.host}`);
  try {
    if (requestUrl.pathname === '/health' || requestUrl.pathname.startsWith('/api/')) {
      console.info(`[bridge] ${request.method} ${requestUrl.pathname}`);
    }
    if (request.method === 'GET' && requestUrl.pathname === '/health') return json(response, 200, { ok: true });
    if (request.method === 'POST' && requestUrl.pathname === '/api/admin/users') {
      if (!bridgeAdminToken) return json(response, 503, { error: 'BRIDGE_ADMIN_TOKEN is not configured' });
      if (!isAdministrator(request)) return json(response, 401, { error: 'A valid bridge administrator token is required' });
      const body = JSON.parse(await readBody(request));
      try {
        const registered = await registerUser(cleanText(body.token), body.label);
        return json(response, 201, { userId: registered.userId, createdAt: registered.createdAt });
      } catch (error) {
        return json(response, /already registered/.test(error.message) ? 409 : 400, { error: error.message });
      }
    }
    const user = await authenticatedUser(request, requestUrl);
    if (!user) return json(response, 401, { error: 'A valid bridge access token is required' });
    if (request.method === 'GET' && requestUrl.pathname === '/api/search') {
      const results = parseSearch((await providerJson(`/ajax/anime/search?keyword=${encodeURIComponent(requestUrl.searchParams.get('q') ?? '')}`)).html ?? '');
      console.info(`[bridge] Search returned ${results.length} result(s)`);
      return json(response, 200, { results });
    }
    if (request.method === 'GET' && requestUrl.pathname === '/api/latest') return json(response, 200, await latestUpdated(requestUrl.searchParams));
    if (request.method === 'GET' && requestUrl.pathname === '/api/history') {
      return json(response, 200, await storedHistory(user.userId));
    }
    if (request.method === 'PUT' && requestUrl.pathname === '/api/history') {
      const body = JSON.parse(await readBody(request));
      return json(response, 200, await mergeHistory(user.userId, body));
    }
    if (request.method === 'POST' && requestUrl.pathname === '/api/series') return json(response, 200, await getSeries(JSON.parse(await readBody(request)).watchUrl));
    const serversRoute = requestUrl.pathname.match(/^\/api\/series\/([\w-]+)\/servers$/);
    if (request.method === 'GET' && serversRoute) return json(response, 200, await getServers(serversRoute[1], requestUrl.searchParams.get('episode')));
    if (request.method === 'POST' && requestUrl.pathname === '/api/play') { const body = JSON.parse(await readBody(request)); return json(response, 201, await createPlayback(body.seriesKey, body.episode, body.serverIndex, requestOrigin(request), user)); }
    const watch = requestUrl.pathname.match(/^\/watch\/([\w-]+)\/master\.m3u8$/);
    if (request.method === 'GET' && watch) { const source = sources.get(watch[1]); if (!source) return json(response, 404, { error: 'Unknown or expired source' }); if (source.userId !== user.userId) return json(response, 403, { error: 'Playback belongs to another user' }); return await sendUpstream(response, source.hlsUrl, watch[1], source, true, request.headers.range); }
    const subtitle = requestUrl.pathname.match(/^\/subtitle\/([\w-]+)\/(\d+)\.m3u8$/);
    if (request.method === 'GET' && subtitle) { const source = sources.get(subtitle[1]); const track = source?.subtitles[Number(subtitle[2])]; if (!track) return json(response, 404, { error: 'Unknown subtitle track' }); if (source.userId !== user.userId) return json(response, 403, { error: 'Playback belongs to another user' }); return track.playlistUrl ? await sendUpstream(response, track.playlistUrl, subtitle[1], source, false, request.headers.range) : await sendSingleVttPlaylist(response, track, subtitle[1], source); }
    const media = requestUrl.pathname.match(/^\/media\/([\w-]+)$/);
    if (request.method === 'GET' && media) {
      const source = sources.get(media[1]); const upstream = requestUrl.searchParams.get('url'); const signature = requestUrl.searchParams.get('sig');
      if (!source || !upstream) return json(response, 404, { error: 'Unknown media request' });
      if (source.userId !== user.userId) return json(response, 403, { error: 'Playback belongs to another user' });
      if (!sameSecret(signature, mediaUrlSignature(media[1], upstream))) return json(response, 403, { error: 'Invalid media request' });
      return await sendUpstream(response, new URL(upstream).toString(), media[1], source, false, request.headers.range);
    }
    json(response, 404, { error: 'Not found' });
  } catch (error) {
    console.error(`[bridge] ${request.method} ${requestUrl.pathname} failed: ${error.message}`);
    json(response, 502, { error: error.message });
  }
});
server.listen(port, host, () => console.log(`AirPlay Subtitle Bridge: http://${host}:${port}`));
