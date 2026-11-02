import http from 'node:http';
import { createDecipheriv, createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { load } from 'cheerio';

const host = process.env.BRIDGE_HOST ?? '0.0.0.0';
const port = Number(process.env.BRIDGE_PORT ?? 8787);
// Kept in sync with version.txt by scripts/version.mjs; reported by /health.
const bridgeVersion = (() => {
  try { return JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')).version ?? null; } catch { return null; }
})();
// DECLARE_AUDIO_LANGUAGE=false stops announcing the audio language in the
// master playlist (useful to compare subtitle timing with and without it).
const declareAudioLanguage = process.env.DECLARE_AUDIO_LANGUAGE !== 'false';
const sources = new Map();
const seriesCache = new Map();
// Episode counts per series for the Continue screen, refreshed every 15 minutes.
const seriesSummaries = new Map();
const bridgeUsers = configuredBridgeUsers();
const bridgeAdminToken = cleanText(process.env.BRIDGE_ADMIN_TOKEN);
const historyStorePath = resolve(process.env.HISTORY_STORE_PATH ?? `${process.cwd()}/data/history.json`);
const userStorePath = resolve(process.env.BRIDGE_USER_STORE_PATH ?? `${process.cwd()}/data/users.json`);
// Stored next to the history file by default so an existing data volume keeps it.
const preferencesStorePath = resolve(process.env.PREFERENCES_STORE_PATH ?? join(dirname(historyStorePath), 'preferences.json'));
const mediaUrlSigningKey = randomUUID();
let historyUsers;
let historyMutation = Promise.resolve();
let persistedUsers;
let userMutation = Promise.resolve();
let preferenceUsers;
let preferencesMutation = Promise.resolve();

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
// Serialises writes per store. A failed write rejects only its own caller; the
// queue keeps accepting later writes instead of staying rejected forever.
function enqueue(queue, task) {
  const run = queue.then(task);
  return { run, queue: run.catch(() => {}) };
}
async function writeJsonAtomically(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const temporaryPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
  await writeFile(temporaryPath, JSON.stringify(value), 'utf8');
  await rename(temporaryPath, path);
}

// The catalog site is a pluggable provider. PROVIDER_TYPE selects the
// implementation and PROVIDER_ORIGIN its domain: a site that moves domain but
// keeps the same structure only needs a new origin; a different site needs a
// new provider type registered here. Every provider implements:
//   watchUrl(value)        canonical `${origin}/watch/…` URL; rebases other origins
//   search(keyword)        → [catalog item]
//   latest(searchParams)   → { results, page, hasNext }
//   series(watchUrl)       → { title, titleJp, watchUrl, episodes: [{ number, title, ref }], seasons }
//   servers(episodeRef)    → [{ index, name, type: 'sub' | 'dub', ref }]
//   source(serverRef)      → { hlsUrl, intro, outro, requestHeaders, subtitles }
//   segment(url, body)     → body, after any transport fix-up the player needs
// Catalog items: { title, titleJp, watchUrl, imageUrl, meta, rating, score, mediaType, year, episode? }.
const providerTypes = { ANK: createAnkProvider };
const provider = createProvider(process.env.PROVIDER_TYPE, process.env.PROVIDER_ORIGIN);
function createProvider(type, origin) {
  const name = cleanText(type).toUpperCase() || 'ANK';
  const factory = providerTypes[name];
  if (!factory) throw new Error(`Unknown PROVIDER_TYPE "${name}". Supported: ${Object.keys(providerTypes).join(', ')}`);
  return factory(cleanText(origin));
}

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
  const { run, queue } = enqueue(userMutation, async () => {
    const users = await loadPersistedUsers();
    if (bridgeUsers.some((user) => sameSecret(token, user.token))) throw new Error('This token is reserved by bridge configuration');
    const existing = users.find((user) => sameSecret(user.tokenHash, tokenHash(token, user.salt)));
    if (existing) return existing;
    if (users.length >= 1000) throw new Error('User limit reached');
    const user = { userId: randomUUID(), salt: randomBytes(16).toString('hex'), tokenHash: '', label: historyText(label, 'Private user', 80), createdAt: new Date().toISOString() };
    user.tokenHash = tokenHash(token, user.salt);
    users.push(user);
    await writeJsonAtomically(userStorePath, { version: 1, users });
    return user;
  });
  userMutation = queue;
  return run;
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
function paddedKey(value, length) {
  const result = Buffer.alloc(length); Buffer.from(value, 'utf8').copy(result); return result;
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
  // Forced tracks only carry signs and songs; Dubtitle tracks follow the dub script.
  const kind = { forced: qualifiers.includes('Forced'), dubtitle: qualifiers.includes('Dubtitle') };
  const named = (name, language, extra = []) => {
    const descriptors = [...extra, ...qualifiers];
    return { name: descriptors.length ? `${name} (${descriptors.join(', ')})` : name, language, ...kind };
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
  return { name: usableLabel || `Subtitles ${index + 1}`, language: 'und', ...kind };
}
// Subtitle tracks from a player: readable, unique names, BCP-47 tags and a
// full English track as default (never a Forced one, which is nearly empty).
function subtitleTracks(tracks, baseUrl) {
  const subtitles = (Array.isArray(tracks) ? tracks : [])
    .filter((track) => /^(captions|subtitles)$/i.test(cleanText(track?.kind)))
    .map((track, index) => ({ ...subtitleDetails(track, index), vttUrl: absoluteUrl(track?.file ?? '', baseUrl) }))
    .filter((track) => track.vttUrl && new URL(track.vttUrl).pathname.toLowerCase().endsWith('.vtt'));
  const seen = new Map();
  for (const track of subtitles) {
    const count = (seen.get(track.name) ?? 0) + 1;
    seen.set(track.name, count);
    if (count > 1) track.name = `${track.name} ${count}`;
  }
  const preferences = [
    (track) => track.language === 'en' && !track.forced && !track.dubtitle,
    (track) => track.language === 'en' && !track.forced,
    (track) => !track.forced,
  ];
  const defaultTrack = preferences.map((matches) => subtitles.find(matches)).find(Boolean) ?? subtitles[0];
  subtitles.forEach((track) => { track.default = track === defaultTrack; });
  return subtitles;
}
function validSkipRange(value) {
  const start = Number(value?.start), end = Number(value?.end);
  return value && Number.isFinite(start) && Number.isFinite(end) && start >= 0 && end > start ? { start, end } : null;
}
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
// History keeps the provider's watch URL rebased onto the current origin, so
// entries saved before a domain move still resume after PROVIDER_ORIGIN changes.
function normalizeHistoryEntry(value) {
  const watchUrl = provider.watchUrl(historyText(value?.watchUrl, '', 2000));
  const episode = Number(value?.episode);
  if (!Number.isInteger(episode) || episode < 1 || episode > 100000) throw new Error('History episode is invalid');
  const position = Number(value?.positionSeconds);
  const duration = Number(value?.durationSeconds ?? NaN);
  const totalEpisodes = Number(value?.totalEpisodes ?? NaN);
  return {
    seriesTitle: historyText(value?.seriesTitle, 'Untitled'),
    titleJp: value?.titleJp ? historyText(value.titleJp, '', 500) : null,
    watchUrl,
    imageUrl: value?.imageUrl ? historyText(value.imageUrl, '', 2000) : null,
    episode,
    episodeTitle: historyText(value?.episodeTitle, `Episode ${episode}`),
    serverName: historyText(value?.serverName, ''),
    serverKind: ['sub', 'dub'].includes(value?.serverKind) ? value.serverKind : null,
    positionSeconds: Number.isFinite(position) ? Math.max(0, position) : 0,
    durationSeconds: Number.isFinite(duration) && duration > 0 ? duration : null,
    completed: value?.completed === true,
    totalEpisodes: Number.isInteger(totalEpisodes) && totalEpisodes > 0 ? totalEpisodes : null,
    updatedAt: historyDate(value?.updatedAt).toISOString(),
  };
}
function normalizeHistoryDeletion(value) {
  return {
    watchUrl: provider.watchUrl(historyText(value?.watchUrl, '', 2000)),
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
  const { run, queue } = enqueue(historyMutation, async () => {
    const users = await loadHistory(); const existing = users.get(userId) ?? historyState();
    const merged = historyState([...existing.entries, ...incomingEntries], [...existing.deletions, ...incomingDeletions]);
    users.set(userId, merged);
    await writeJsonAtomically(historyStorePath, { version: 4, users: Object.fromEntries(users) });
    return merged;
  });
  historyMutation = queue;
  return serializeHistoryState(await run);
}

// Catalog and playback preferences follow the user token, like the history.
// The newest `updatedAt` wins so every device converges on the same values.
function normalizePreferences(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new HttpError(400, 'Preferences payload is invalid');
  const subtitleLanguage = cleanText(value.subtitleLanguage).slice(0, 35);
  return {
    titleLanguage: value.titleLanguage === 'jp' ? 'jp' : 'en',
    defaultTrackType: value.defaultTrackType === 'dub' ? 'dub' : 'sub',
    // Empty follows the device languages, `off` disables, otherwise a BCP-47 tag.
    subtitleLanguage: /^(?:off|[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*)$/.test(subtitleLanguage) ? subtitleLanguage : '',
    autoNext: value.autoNext !== false,
    autoSkipIntro: value.autoSkipIntro === true,
    autoSkipOutro: value.autoSkipOutro === true,
    updatedAt: historyDate(value.updatedAt).toISOString(),
  };
}
function serializePreferences(preferences) {
  return preferences ? { ...preferences, updatedAt: historyTimestamp(preferences.updatedAt) } : null;
}
async function loadPreferences() {
  if (preferenceUsers) return preferenceUsers;
  preferenceUsers = new Map();
  try {
    const parsed = JSON.parse(await readFile(preferencesStorePath, 'utf8'));
    for (const [userId, value] of Object.entries(parsed?.users ?? {})) {
      try { preferenceUsers.set(normalizedUserId(userId), normalizePreferences(value)); } catch { /* Ignore corrupted preference rows. */ }
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') console.warn(`[bridge] Preferences store could not be read: ${error.message}`);
  }
  return preferenceUsers;
}
async function storedPreferences(userId) {
  await preferencesMutation; const users = await loadPreferences();
  return { preferences: serializePreferences(users.get(userId)) };
}
async function mergePreferences(userId, payload) {
  const incoming = normalizePreferences(payload?.preferences);
  const { run, queue } = enqueue(preferencesMutation, async () => {
    const users = await loadPreferences(); const existing = users.get(userId);
    if (!existing || new Date(incoming.updatedAt) > new Date(existing.updatedAt)) {
      users.set(userId, incoming);
      await writeJsonAtomically(preferencesStorePath, { version: 1, users: Object.fromEntries(users) });
    }
    return users.get(userId);
  });
  preferencesMutation = queue;
  return { preferences: serializePreferences(await run) };
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
  // "Title II" style sequels.
  const roman = seasonNumber === null ? base.match(/\s+(II|III|IV|V|VI|VII|VIII|IX|X)$/) : null;
  if (roman) {
    seasonNumber = ['II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X'].indexOf(roman[1]) + 2;
    base = cleanText(base.slice(0, roman.index));
  }
  return { base, baseKey: normalizedTitle(base), seasonNumber };
}
function seasonRecord(anime) {
  return { ...anime, seasonNumber: seasonIdentity(anime.title).seasonNumber ?? 1 };
}

async function getSeries(watchUrl) {
  const series = await provider.series(provider.watchUrl(watchUrl));
  if (!series.episodes.length) throw new Error('No episodes were returned');
  const key = randomUUID(); seriesCache.set(key, { ...series, expiresAt: Date.now() + 20 * 60 * 1000 });
  rememberSummary(series);
  console.info(`[bridge] Loaded ${series.title}: ${series.episodes.length} episode(s), ${series.seasons.length} related season(s)`);
  const { synopsis, rating, adult, status, mediaType, score, totalEpisodes, imageUrl, nextEpisodeAt } = series;
  return {
    seriesKey: key, title: series.title, titleJp: series.titleJp, synopsis, rating, adult, status, mediaType, score, totalEpisodes, imageUrl, nextEpisodeAt,
    episodes: series.episodes.map(({ number, title, sub, dub }) => ({ number, title, sub, dub })), seasons: series.seasons,
  };
}
// The newest Sub and Dub episode, the announced total and the season that
// follows in the watch order: enough for the app to tell a finished series
// from one waiting for its next episode.
function seriesSummary(series) {
  const latest = (kind) => series.episodes.reduce((newest, episode) => (episode[kind] ? Math.max(newest, episode.number) : newest), 0) || null;
  const index = series.seasons.findIndex((season) => season.watchUrl === series.watchUrl);
  const following = index >= 0 ? series.seasons.slice(index + 1) : [];
  const nextSeason = following.find((season) => !/\b(?:specials?|mini anime|recap|ova|oad|movie|film)\b/i.test(season.title)) ?? following[0] ?? null;
  return { watchUrl: series.watchUrl, totalEpisodes: series.totalEpisodes, status: series.status, latestSub: latest('sub'), latestDub: latest('dub'), nextSeason, nextEpisodeAt: series.nextEpisodeAt ?? null };
}
function rememberSummary(series) {
  const summary = seriesSummary(series);
  seriesSummaries.set(series.watchUrl, { summary, expiresAt: Date.now() + 15 * 60 * 1000 });
  return summary;
}
async function getSeriesStatuses(watchUrls) {
  if (!Array.isArray(watchUrls)) throw new HttpError(400, 'watchUrls must be an array');
  const urls = [...new Set(watchUrls.slice(0, 50).map((value) => { try { return provider.watchUrl(String(value)); } catch { return null; } }).filter(Boolean))];
  const statuses = []; let next = 0;
  // A few at a time so a long Continue list does not flood the catalog.
  async function worker() {
    while (next < urls.length) {
      const url = urls[next++]; const cached = seriesSummaries.get(url);
      if (cached && cached.expiresAt > Date.now()) { statuses.push(cached.summary); continue; }
      try { statuses.push(rememberSummary(await provider.series(url))); } catch (error) { console.warn(`[bridge] Status lookup failed: ${error.message}`); }
    }
  }
  await Promise.all(Array.from({ length: Math.min(4, urls.length) }, worker));
  return { statuses };
}
function cachedSeries(key) {
  const series = seriesCache.get(key);
  // 410 lets the app reload the series transparently and retry once.
  if (!series || series.expiresAt < Date.now()) { seriesCache.delete(key); throw new HttpError(410, 'Series session expired; search again'); }
  return series;
}
async function getServers(seriesKey, episodeNumber) {
  const series = cachedSeries(seriesKey); const episode = series.episodes.find((candidate) => candidate.number === Number(episodeNumber));
  if (!episode) throw new Error('Episode was not found');
  const servers = await provider.servers(episode.ref);
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
  const media = await provider.source(server.ref);
  console.info(`[bridge] Public source metadata returned ${media.subtitles.length} subtitle track(s)`);
  console.info(`[bridge] HLS candidate: ${playlistDescriptor(media.hlsUrl)}`);
  // Dub audio is English, so no subtitle is forced on; Sub keeps its default track.
  if (server.type === 'dub') media.subtitles.forEach((track) => { track.default = false; });
  const id = randomUUID(); sources.set(id, { ...media, kind: server.type, declareAudio: declareAudioLanguage, userId: user.userId, accessToken: user.token });
  const expiry = setTimeout(() => { sources.delete(id); }, 2 * 60 * 60 * 1000);
  expiry.unref();
  console.info(`[bridge] Playback ready with ${media.subtitles.length} subtitle track(s)`);
  return { playbackUrl: `${playbackOrigin}${protectedPath(`/watch/${id}/master.m3u8`, user.token)}`, subtitleTracks: media.subtitles.length, serverName: server.name, serverKind: server.type, intro: media.intro, outro: media.outro };
}

// ANK provider: AJAX catalog endpoints, `/watch/<slug>` series pages and an
// embedded player whose source metadata is AES-encrypted.
function createAnkProvider(configuredOrigin) {
  const providerOrigin = new URL(configuredOrigin || Buffer.from('aHR0cHM6Ly9hbmlrb3RvdHYudG8=', 'base64').toString('utf8')).origin;
  const cdnTokenSecret = 'MpCdnT0k3n!9f2K#xQ7vL5mR8wN1pY4s';
  const sourceEncKey = 'i?LMTAx0Q6,:}50U';
  const sourceEncIv = "W0;27ToaUpl_P%'c";
  const playerUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0';

  function watchUrl(value) {
    const url = new URL(value, providerOrigin);
    if (!url.pathname.startsWith('/watch/')) throw new HttpError(400, 'Only catalog watch URLs are accepted');
    return new URL(url.pathname, providerOrigin).toString();
  }
  async function providerJson(path) {
    const response = await fetchWithTimeout(new URL(path, providerOrigin), { headers: { Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest' } }, 15000, 'Provider request');
    if (!response.ok) throw new Error(`Provider HTTP ${response.status}`);
    const payload = await response.json();
    if (Number(payload.status) !== 200) throw new Error(payload.message || 'Provider did not return a successful result');
    return payload.result;
  }
  function isAdultRating(rating) { return ['R+', 'Rx'].includes(rating); }
  function parseSearch(html) {
    const $ = load(html); const seen = new Set(); const results = [];
    $('a.item[href*="/watch/"]').each((_, node) => {
      let url;
      try { url = watchUrl($(node).attr('href')); } catch { return; }
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
        rating, score, mediaType, year: yearText ? Number(yearText) : null, adult: isAdultRating(rating),
      });
    });
    return results;
  }
  async function search(keyword) {
    return parseSearch((await providerJson(`/ajax/anime/search?keyword=${encodeURIComponent(cleanText(keyword).slice(0, 200))}`)).html ?? '');
  }
  async function latest(params) {
    const page = Math.max(1, Math.min(10000, Number.parseInt(params.get('page') || '1', 10) || 1));
    const season = params.get('season') || '', status = params.get('status') || '';
    const rating = params.get('rating') || '', mediaType = params.get('mediaType') || '', year = params.get('year') || '';
    const keyword = cleanText(params.get('q')).slice(0, 200), language = params.get('language') || 'all';
    if (!['sub', 'dub', 'all'].includes(language)) throw new HttpError(400, 'Invalid language');
    if (season && !['winter', 'spring', 'summer', 'fall'].includes(season)) throw new HttpError(400, 'Invalid season');
    if (status && !['finished-airing', 'currently-airing', 'not-yet-aired'].includes(status)) throw new HttpError(400, 'Invalid status');
    if (rating && !['G', 'PG', 'PG-13', 'R', 'R+', 'Rx'].includes(rating)) throw new HttpError(400, 'Invalid rating');
    if (mediaType && !['TV', 'Movie', 'ONA', 'OVA', 'Special'].includes(mediaType)) throw new HttpError(400, 'Invalid media type');
    if (year && !/^\d{4}$/.test(year)) throw new HttpError(400, 'Invalid year');
    const filtered = Boolean(season || status || keyword || rating || mediaType || year);
    // Plain Sub or Dub recents come from the home widgets, which order series
    // by their newest episode of that kind (12 per page, no pager).
    if (!filtered && language !== 'all') {
      const result = await providerJson(`/ajax/home/widget/updated-${language}?page=${page}`);
      const results = parseCards(load(typeof result === 'string' ? result : result?.html ?? ''), language);
      return { results, page, hasNext: results.length >= 12 && page < 100 };
    }
    const url = new URL(filtered || language !== 'all' ? '/filter' : '/latest-updated', providerOrigin);
    url.searchParams.set('page', String(page));
    if (filtered || language !== 'all') {
      url.searchParams.set('sort', keyword ? 'default' : 'latest-updated');
      if (keyword) url.searchParams.set('keyword', keyword);
      if (season) url.searchParams.append('season[]', season);
      if (status) url.searchParams.append('status[]', status);
      if (rating) url.searchParams.append('rating[]', rating);
      if (mediaType) url.searchParams.append('term_type[]', mediaType);
      if (year) url.searchParams.append('year[]', year);
      if (language !== 'all') url.searchParams.append('language[]', language);
    }
    const response = await fetchWithTimeout(url, { headers: { Accept: 'text/html' } }, 15000, 'Latest catalog request');
    if (!response.ok) throw new Error(`Catalog HTTP ${response.status}`);
    const $ = load(await response.text());
    return { results: parseCards($, language), page, hasNext: $('a[rel=next]').length > 0 };
  }
  function parseCards($, language) {
    const results = [];
    $('.ani.poster').each((_, node) => {
      const card = $(node).parent(), name = card.find('a.name.d-title').first();
      const href = name.attr('href') || $(node).find('a').first().attr('href');
      if (!href) return;
      let watch;
      try { watch = new URL(watchUrl(href)); } catch { return; }
      // Card links always point at /ep-1; the newest episode is in the
      // `ep-status` badges (Sub, Dub and total counts).
      const count = (kind) => Number(cleanText($(node).find(`.ep-status.${kind}`).first().text())) || null;
      const subEpisodes = count('sub'), dubEpisodes = count('dub'), totalEpisodes = count('total');
      const newest = language === 'sub' ? subEpisodes : language === 'dub' ? dubEpisodes : Math.max(subEpisodes ?? 0, dubEpisodes ?? 0);
      const episode = newest || Number(watch.pathname.match(/\/ep-(\d+)\/?$/)?.[1]) || null;
      watch.pathname = watch.pathname.replace(/\/ep-\d+\/?$/, '');
      const src = $(node).find('img').first().attr('src');
      const scoreValue = Number(cleanText(card.find('.info .meta .rated span').first().text()));
      results.push({ title: cleanText(name.text()) || 'Untitled', titleJp: cleanText(name.attr('data-jp')) || null, watchUrl: watch.toString(), imageUrl: src ? absoluteUrl(src, providerOrigin) : null, meta: cleanText(card.find('.info .meta').text()), rating: null, score: scoreValue > 0 ? scoreValue : null, mediaType: cleanText($(node).find('.right').text()) || null, year: null, episode, subEpisodes, dubEpisodes, totalEpisodes, adult: $(node).find('.adult').length > 0 });
    });
    return results;
  }
  // The franchise watch order lists every related entry chronologically
  // (sequels named "II" included); the curated season strip only adds labels
  // such as "Season 1, Part 2". Entries that only link to a search are skipped.
  async function relatedSeasons(series, animeId) {
    const [order, curated] = await Promise.all([
      providerJson(`/api/watch-order/${animeId}`).catch(() => null),
      providerJson(`/api/seasons/${animeId}`).catch(() => null),
    ]);
    const labels = new Map(); const curatedSeasons = [];
    if (typeof curated === 'string') {
      const $ = load(curated);
      $('.season a[href]').each((_, node) => {
        let url;
        try { url = watchUrl($(node).attr('href')); } catch { return; }
        const label = cleanText($(node).find('.name').text()) || null;
        labels.set(url, label); curatedSeasons.push({ title: label ?? series.title, titleJp: null, watchUrl: url, imageUrl: null, meta: '', label });
      });
    }
    const entries = [];
    if (typeof order === 'string') {
      const $ = load(order);
      $('.item').each((_, node) => {
        const link = $(node).find('a.name[href], .poster a[href]').first(); let url;
        try { url = watchUrl(link.attr('href')); } catch { return; }
        const name = $(node).find('a.name').first(); const src = $(node).find('.poster img').first().attr('src');
        const meta = cleanText($(node).find('.meta').text()).replace(/^\?$/, '');
        entries.push({
          title: cleanText(name.text()) || 'Untitled', titleJp: cleanText(name.attr('data-jp')) || null, watchUrl: url,
          imageUrl: src ? absoluteUrl(src, providerOrigin) : null, meta, mediaType: meta.match(/^(TV|Movie|ONA|OVA|Special)\b/i)?.[1] ?? null, label: labels.get(url) ?? null,
        });
      });
    }
    for (const season of curatedSeasons) if (!entries.some((entry) => entry.watchUrl === season.watchUrl)) entries.push(season);
    if (entries.length) {
      if (!entries.some((entry) => entry.watchUrl === series.watchUrl)) entries.push({ title: series.title, titleJp: series.titleJp, watchUrl: series.watchUrl, imageUrl: series.imageUrl, meta: '', label: labels.get(series.watchUrl) ?? null });
      return [...new Map(entries.map((entry) => [entry.watchUrl, seasonRecord(entry)])).values()];
    }
    return searchedSeasons(series);
  }
  // Fallback for series without a watch order: same base title in a search.
  async function searchedSeasons(series) {
    const identity = seasonIdentity(series.title);
    if (identity.baseKey.length < 3) return [seasonRecord(series)];
    try {
      const candidates = (await search(identity.base)).filter((candidate) => seasonIdentity(candidate.title).baseKey === identity.baseKey);
      if (!candidates.some((candidate) => candidate.watchUrl === series.watchUrl)) {
        candidates.push({ title: series.title, titleJp: series.titleJp, watchUrl: series.watchUrl, imageUrl: null, meta: '' });
      }
      const unique = [...new Map(candidates.map((candidate) => [candidate.watchUrl, seasonRecord(candidate)])).values()];
      return unique.sort((left, right) => left.seasonNumber - right.seasonNumber || left.title.localeCompare(right.title));
    } catch (error) {
      console.warn(`[bridge] Related season lookup failed: ${error.message}`);
      return [seasonRecord(series)];
    }
  }
  async function series(url) {
    const page = await fetchWithTimeout(url, { headers: { Accept: 'text/html' } }, 15000, 'Provider page request');
    if (!page.ok) throw new Error(`Provider page HTTP ${page.status}`);
    const $ = load(await page.text()); const animeId = $('#watch-main').attr('data-id');
    if (!animeId || !/^\d+$/.test(animeId)) throw new Error('Series identifier was not found');
    // "Label: value" rows of the details block (Type, Status, Episodes, MAL…).
    const details = new Map();
    $('#w-info .bmeta .meta > div').each((_, node) => {
      const match = cleanText($(node).text()).match(/^([^:]+):\s*(.*)$/);
      if (match && !details.has(match[1].toLowerCase())) details.set(match[1].toLowerCase(), match[2]);
    });
    const total = Number(details.get('episodes')), score = Number(details.get('mal'));
    const statusText = (details.get('status') ?? '').toLowerCase();
    const rating = cleanText($('#w-info .meta.icons .rating').first().text()) || null;
    const poster = $('#w-info .poster img').first().attr('src');
    // "The next episode is predicted to arrive on …" countdown (Unix seconds).
    const nextEpisodeAt = Number($('.alert.next-episode .count-down').first().attr('data-target'));
    const info = {
      title: cleanText($('#w-info h1, #w-info .film-name, h1').first().text()) || 'Untitled',
      titleJp: cleanText($('#w-info [data-jp], h1[data-jp], .d-title[data-jp]').first().attr('data-jp')) || null,
      watchUrl: url,
      synopsis: cleanText($('#w-info .synopsis .content').first().text()) || null,
      rating, adult: isAdultRating(rating),
      status: /finished/.test(statusText) ? 'finished' : /currently|airing/.test(statusText) ? 'airing' : /not yet/.test(statusText) ? 'upcoming' : null,
      mediaType: details.get('type') || null,
      score: score > 0 ? score : null,
      totalEpisodes: Number.isInteger(total) && total > 0 ? total : null,
      imageUrl: poster ? absoluteUrl(poster, providerOrigin) : null,
      nextEpisodeAt: Number.isFinite(nextEpisodeAt) && nextEpisodeAt > 0 ? nextEpisodeAt : null,
    };
    const $episodes = load(await providerJson(`/ajax/episode/list/${animeId}`)); const episodes = [];
    $episodes('[data-ids]').each((_, node) => {
      const element = $episodes(node); const number = Number(element.attr('data-num')); const ids = element.attr('data-ids');
      if (!Number.isFinite(number) || !ids) return;
      // Older markup has no flags: every episode was assumed to have Sub only.
      const sub = element.attr('data-sub') === undefined ? true : element.attr('data-sub') === '1';
      episodes.push({ number, title: cleanText(element.text()).replace(/^\d+\s*/, '') || `Episode ${number}`, ref: ids, sub, dub: element.attr('data-dub') === '1' });
    });
    episodes.sort((a, b) => a.number - b.number);
    return { ...info, episodes, seasons: await relatedSeasons(info, animeId) };
  }
  async function servers(episodeRef) {
    const $ = load(await providerJson(`/ajax/server/list?servers=${encodeURIComponent(episodeRef)}`)); const result = [];
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
      result.push({ index, name: cleanText(item.text()) || `Server ${index + 1}`, type, ref: linkId });
    });
    return result;
  }
  // Estimated airing times for the next days (one schedule page per UTC
  // day), cached for 30 minutes. Each card is one episode of one kind.
  let scheduleCache = null;
  async function schedule() {
    if (scheduleCache && scheduleCache.expiresAt > Date.now()) return scheduleCache.entries;
    const today = Math.floor(Date.now() / 86400000) * 86400;
    const pages = await Promise.all(Array.from({ length: 8 }, (_, day) => providerJson(`/ajax/schedule/page/date?tz=0&time=${today + day * 86400}`).catch(() => null)));
    const entries = new Map();
    for (const html of pages) {
      if (typeof html !== 'string') continue;
      const $ = load(html);
      $('.sc-grp').each((_, group) => {
        const groupAiring = Number($(group).attr('data-airing'));
        $(group).find('.sc-card[href]').each((_, node) => {
          const card = $(node); let watch;
          try { watch = new URL(watchUrl(card.attr('href'))); } catch { return; }
          const episode = Number(cleanText(card.find('.sc-ep').text()).match(/\d+/)?.[0] ?? watch.pathname.match(/\/ep-(\d+)\/?$/)?.[1]);
          const airingAt = Number(card.find('.sc-cd').attr('data-airing')) || groupAiring;
          if (!Number.isInteger(episode) || !Number.isFinite(airingAt) || airingAt <= 0) return;
          watch.pathname = watch.pathname.replace(/\/ep-\d+\/?$/, '');
          const kind = card.attr('data-type') === 'dub' ? 'dub' : 'sub';
          const name = card.find('.sc-name').first(); const src = card.find('img').first().attr('src');
          entries.set(`${watch}#${episode}#${kind}`, {
            watchUrl: watch.toString(), title: cleanText(name.text()) || 'Untitled', titleJp: cleanText(name.attr('data-jp')) || null,
            imageUrl: src ? absoluteUrl(src, providerOrigin) : null, episode, kind, airingAt,
          });
        });
      });
    }
    const sorted = [...entries.values()].sort((left, right) => left.airingAt - right.airingAt);
    if (pages.some((html) => typeof html === 'string')) scheduleCache = { entries: sorted, expiresAt: Date.now() + 30 * 60 * 1000 };
    return sorted;
  }
  // The CDN token lasts 90 seconds. Players read the master playlist right
  // away, but offline downloads (a separate iOS process that may queue the
  // episode) and long sessions come back later, so every upstream request
  // on the stream's host re-signs a token that is missing or about to expire.
  function signUpstream(value, source) {
    const url = new URL(value);
    if (url.hostname !== new URL(source.hlsUrl).hostname) return url.toString();
    let expiresAt = 0;
    try { expiresAt = Number(Buffer.from(String(url.searchParams.get('token') ?? '').split('.')[0], 'base64url').toString('utf8').split('|')[0]); } catch { /* unreadable: re-sign */ }
    if (url.searchParams.has('token') && expiresAt - Date.now() / 1000 > 20) return url.toString();
    url.searchParams.delete('token');
    return attachCdnToken(url.toString());
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
  function decryptPlayerSources(value) {
    const encoded = String(value).replace(/-/g, '+').replace(/_/g, '/');
    const encrypted = Buffer.from(encoded + '='.repeat((4 - (encoded.length % 4)) % 4), 'base64');
    const decipher = createDecipheriv('aes-256-cbc', paddedKey(sourceEncKey, 32), paddedKey(sourceEncIv, 16));
    return JSON.parse(Buffer.concat([decipher.update(encrypted), decipher.final()]).toString('utf8'));
  }
  async function source(serverRef) {
    const reply = await providerJson(`/ajax/server?get=${encodeURIComponent(serverRef)}`);
    if (!reply?.url) throw new Error('Player URL was not returned');
    console.info('[bridge] Player URL returned; resolving public source metadata');
    const embedUrl = reply.url;
    const page = await fetchWithTimeout(embedUrl, { headers: { Accept: 'text/html', Referer: `${providerOrigin}/`, 'User-Agent': playerUserAgent } }, 15000, 'Player page request');
    if (!page.ok) throw new Error(`Player page HTTP ${page.status}`);
    const $ = load(await page.text()); const episodeId = $('#megaplay-player').first().attr('data-id');
    if (!episodeId) throw new Error('Player episode identifier was not found');
    const playerOrigin = new URL(embedUrl).origin;
    const sourceUrl = new URL('/stream/getSources', playerOrigin); sourceUrl.searchParams.set('id', episodeId);
    console.info('[bridge] Loading public player source metadata');
    const sourceResponse = await fetchWithTimeout(sourceUrl, {
      headers: { Accept: 'application/json, text/javascript, */*; q=0.01', Referer: embedUrl, Origin: playerOrigin, 'User-Agent': playerUserAgent, 'X-Requested-With': 'XMLHttpRequest' },
    }, 15000, 'Player source request');
    if (!sourceResponse.ok) throw new Error(`Player source HTTP ${sourceResponse.status}`);
    const sourcePayload = await sourceResponse.json();
    const file = resolveStreamFile(sourcePayload.enc ? decryptPlayerSources(sourcePayload.enc) : sourcePayload.sources);
    if (!file) throw new Error('Player source did not include an HLS file');
    return {
      hlsUrl: attachCdnToken(absoluteUrl(file, playerOrigin)),
      intro: validSkipRange(sourcePayload.intro),
      outro: validSkipRange(sourcePayload.outro),
      requestHeaders: { Referer: `${playerOrigin}/`, Origin: playerOrigin, 'User-Agent': playerUserAgent, Accept: '*/*', 'Accept-Language': 'en-US,en;q=0.9' },
      subtitles: subtitleTracks(sourcePayload.tracks, playerOrigin),
    };
  }
  function segment(url, body) {
    // This mirrors the public player's SegmentStrip behavior for the affected
    // CDNs. It removes only its documented fixed transport prefix, never media
    // content, credentials, or DRM data.
    const hostname = new URL(url).hostname;
    return /(?:ibyteimg\.com|tiktokcdn\.com|ipstatp\.com|yoot\.akirax\.buzz)$/i.test(hostname) && body.length > 252 ? body.subarray(252) : body;
  }

  return { type: 'ANK', origin: providerOrigin, watchUrl, search, latest, series, schedule, servers, source, segment, signUpstream };
}

function rewriteUriLines(textValue, baseUrl, id, source) {
  return textValue.split(/\r?\n/).map((line) => {
    const value = line.trim(); if (!value) return line;
    if (!value.startsWith('#')) return mediaUrl(id, absoluteUrl(value, baseUrl), source.accessToken);
    return line.replace(/URI="([^"]+)"/g, (match, uri) => uri.startsWith('/subtitle/') ? match : `URI="${mediaUrl(id, absoluteUrl(uri, baseUrl), source.accessToken)}"`);
  }).join('\n');
}
function withStreamAttribute(playlist, name, value) {
  return playlist.replace(/#EXT-X-STREAM-INF:([^\r\n]*)/g, (line, attrs) => new RegExp(`(?:^|,)${name}=`).test(attrs) ? line : `#EXT-X-STREAM-INF:${attrs},${name}="${value}"`);
}
// Declares the audio language and the VTT subtitle renditions in the master
// playlist. AVPlayer only auto-enables subtitles when it knows the audio is in
// another language, so Sub sources announce Japanese and Dub sources English.
// An AUDIO rendition without URI describes the audio muxed into each variant.
function injectRenditions(master, source, id) {
  if (!/#EXT-X-STREAM-INF:/.test(master)) return master;
  const audio = source.kind === 'dub' ? { name: 'English', language: 'en' } : { name: 'Japanese', language: 'ja' };
  const declarations = [];
  let playlist = master;
  if (source.declareAudio === false) {
    // DECLARE_AUDIO_LANGUAGE=false: leave the audio as the provider sent it.
  } else if (/TYPE=AUDIO/.test(playlist)) {
    playlist = playlist.replace(/^#EXT-X-MEDIA:([^\r\n]*)$/gm, (line, attrs) => /(?:^|,)TYPE=AUDIO(?:,|$)/.test(attrs) && !/(?:^|,)LANGUAGE=/.test(attrs) ? `${line},LANGUAGE="${audio.language}"` : line);
  } else {
    declarations.push(`#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="bridge-audio",NAME="${audio.name}",LANGUAGE="${audio.language}",DEFAULT=YES,AUTOSELECT=YES`);
    playlist = withStreamAttribute(playlist, 'AUDIO', 'bridge-audio');
  }
  const tracks = source.subtitles ?? [];
  if (tracks.length && !/TYPE=SUBTITLES/.test(playlist)) {
    // FORCED=YES makes Apple players treat signs/songs tracks as forced
    // subtitles: shown automatically when needed, not listed as a choice.
    declarations.push(...tracks.map((track, index) => `#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="bridge-subs",NAME="${track.name.replaceAll('"', '')}",LANGUAGE="${track.language.replaceAll('"', '')}",DEFAULT=${track.default && !track.forced ? 'YES' : 'NO'},AUTOSELECT=YES,${track.forced ? 'FORCED=YES,' : ''}URI="${protectedPath(`/subtitle/${id}/${index}.m3u8`, source.accessToken)}"`));
    playlist = withStreamAttribute(playlist, 'SUBTITLES', 'bridge-subs');
  }
  return declarations.length ? playlist.replace(/^#EXTM3U\s*$/m, '#EXTM3U\n' + declarations.join('\n')) : playlist;
}
function secondsInVttTimestamp(match) { return Number(match[1] ?? 0) * 3600 + Number(match[2]) * 60 + Number(match[3]); }
function durationFromVtt(vtt) {
  const pattern = /^(?:(\d+):)?(\d{2}):(\d{2}\.\d{3})\s+-->\s+(?:(\d+):)?(\d{2}):(\d{2}\.\d{3})/gm; let duration = 1;
  for (const match of vtt.matchAll(pattern)) duration = Math.max(duration, secondsInVttTimestamp([, match[4], match[5], match[6]]));
  return Math.ceil(duration);
}
// The CDN rate limits each client IP across all of its hosts: a steady
// sequential stream (about 8 requests per second) is never refused, but
// parallel bursts get 429 with a Retry-After of up to 10 s. Offline downloads
// fetch in parallel, so every upstream request goes through one bridge-wide
// queue: a few at a time, started at a paced rate, and a 429 pauses the whole
// queue for its Retry-After before the request is retried. VOD playlists are
// fetched once per source.
const upstreamConcurrency = Math.max(1, Number(process.env.UPSTREAM_CONCURRENCY ?? 4));
const upstreamRate = Math.max(1, Number(process.env.UPSTREAM_RATE ?? 6));
const upstreamQueue = { active: 0, waiting: [], nextStart: 0, pausedUntil: 0 };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function withUpstreamSlot(task) {
  if (upstreamQueue.active >= upstreamConcurrency) await new Promise((resolve) => upstreamQueue.waiting.push(resolve));
  upstreamQueue.active += 1;
  try {
    const start = Math.max(Date.now(), upstreamQueue.nextStart, upstreamQueue.pausedUntil);
    upstreamQueue.nextStart = start + 1000 / upstreamRate;
    if (start > Date.now()) await sleep(start - Date.now());
    return await task();
  } finally {
    upstreamQueue.active -= 1;
    upstreamQueue.waiting.shift()?.();
  }
}
function upstreamCacheKey(value) {
  const url = new URL(value); url.searchParams.delete('token');
  return url.toString();
}
// The timeout covers the headers and the body of each attempt, counted from
// when it leaves the queue: a stalled CDN must fail the request (so the player
// can report it and retry) instead of hanging forever.
async function fetchUpstream(value, source, range, timeoutMs = 30000) {
  const cacheKey = range ? null : upstreamCacheKey(value);
  const cached = cacheKey ? source.playlistCache?.get(cacheKey) : null;
  // Copies: callers replace the body (segment strip) of what they receive.
  if (cached && cached.expiresAt > Date.now()) return { ...cached.response };
  const headers = { ...source.requestHeaders, ...(range ? { range } : {}) };
  for (let attempt = 0; ; attempt += 1) {
    const url = provider.signUpstream ? provider.signUpstream(value, source) : value;
    const result = await withUpstreamSlot(async () => {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetch(url, { redirect: 'follow', headers, signal: controller.signal });
        if (!response.ok) {
          await response.body?.cancel().catch(() => {});
          return { status: response.status, retryAfter: Number(response.headers.get('retry-after')) };
        }
        return { status: response.status, response: { url: response.url || url, type: response.headers.get('content-type') ?? '', body: Buffer.from(await response.arrayBuffer()) } };
      } catch (error) {
        if (error?.name === 'AbortError') throw new Error(`Upstream request timed out after ${timeoutMs / 1000} seconds`);
        throw error;
      } finally {
        clearTimeout(timeout);
      }
    });
    if (result.response) {
      if (cacheKey && isPlaylist(result.response.url, result.response.type)) {
        source.playlistCache ??= new Map();
        source.playlistCache.set(cacheKey, { response: { ...result.response }, expiresAt: Date.now() + 10 * 60 * 1000 });
      }
      return result.response;
    }
    if (result.status === 429) {
      const wait = Math.min(15, result.retryAfter > 0 ? result.retryAfter : 2 ** attempt) * 1000;
      upstreamQueue.pausedUntil = Math.max(upstreamQueue.pausedUntil, Date.now() + wait);
      if (attempt < 3) {
        console.warn(`[bridge] ${new URL(url).hostname} is rate limiting; pausing upstream requests for ${wait / 1000}s`);
        continue;
      }
      // 503 tells the client the failure is temporary.
      throw new HttpError(503, 'Upstream is rate limiting requests (429)');
    }
    throw new Error(`Upstream responded ${result.status}`);
  }
}
// First presentation timestamp (90 kHz ticks) among the audio/video PES
// packets of an MPEG-TS segment, or null for other containers.
function transportStreamStartPts(buffer) {
  let start = null;
  for (let offset = 0; offset + 188 <= buffer.length && offset < 188 * 2000; offset += 188) {
    if (buffer[offset] !== 0x47) return start;
    if (!(buffer[offset + 1] & 0x40)) continue;
    const adaptation = (buffer[offset + 3] >> 4) & 0x3;
    const payload = offset + 4 + (adaptation >= 2 ? 1 + buffer[offset + 4] : 0);
    if (adaptation === 2 || payload + 14 > offset + 188) continue;
    const isPes = buffer[payload] === 0 && buffer[payload + 1] === 0 && buffer[payload + 2] === 1;
    const streamId = buffer[payload + 3];
    if (!isPes || streamId < 0xc0 || streamId > 0xef || !(buffer[payload + 7] & 0x80)) continue;
    const b = buffer.subarray(payload + 9, payload + 14);
    const pts = ((b[0] >> 1) & 0x07) * 2 ** 30 + (((b[1] << 8) | b[2]) >> 1) * 2 ** 15 + (((b[3] << 8) | b[4]) >> 1);
    start = start === null ? pts : Math.min(start, pts);
  }
  return start;
}
// Apple players place WebVTT cues by timestamp: without X-TIMESTAMP-MAP a cue
// at 0 is pinned to PTS 0, while the provider's web player measures cues from
// the first frame. Mapping LOCAL 0 to the stream's first PTS matches it.
function withTimestampMap(vtt, startPts) {
  if (startPts === null || /X-TIMESTAMP-MAP/.test(vtt) || !/^﻿?WEBVTT/.test(vtt)) return vtt;
  return vtt.replace(/^(﻿?WEBVTT[^\r\n]*)/, `$1\nX-TIMESTAMP-MAP=MPEGTS:${startPts},LOCAL:00:00:00.000`);
}
// Started while serving the master playlist, whose CDN token is still fresh.
async function detectStartPts(source, masterUrl, masterText) {
  try {
    const firstUri = (text) => text.split(/\r?\n/).map((line) => line.trim()).find((line) => line && !line.startsWith('#'));
    const master = masterText === undefined ? await fetchUpstream(source.hlsUrl, source, null, 15000) : null;
    let playlistUrl = master ? master.url : masterUrl;
    let playlist = master ? master.body.toString('utf8') : masterText;
    if (/#EXT-X-STREAM-INF:/.test(playlist)) {
      playlistUrl = absoluteUrl(firstUri(playlist), playlistUrl);
      const variant = await fetchUpstream(playlistUrl, source, null, 15000);
      playlistUrl = variant.url; playlist = variant.body.toString('utf8');
    }
    const segment = await fetchUpstream(absoluteUrl(firstUri(playlist), playlistUrl), source, 'bytes=0-262143', 15000);
    return transportStreamStartPts(provider.segment(segment.url, segment.body));
  } catch (error) {
    console.warn(`[bridge] Stream start time unavailable: ${error.message}`);
    return null;
  }
}
async function sendUpstream(response, upstreamUrl, id, source, inject, range) {
  const upstream = await fetchUpstream(upstreamUrl, source, range); upstream.body = provider.segment(upstream.url, upstream.body); const type = upstream.type;
  const isVtt = upstream.url.toLowerCase().includes('.vtt') || /text\/vtt/i.test(type);
  if (isVtt) {
    source.startPts ??= detectStartPts(source);
    text(response, 200, withTimestampMap(upstream.body.toString('utf8'), await source.startPts), 'text/vtt; charset=utf-8');
    return;
  }
  if (!isPlaylist(upstream.url, type)) { response.writeHead(200, { 'content-type': type || 'application/octet-stream' }); response.end(upstream.body); return; }
  let playlist = upstream.body.toString('utf8'); const manifestStart = playlist.indexOf('#EXTM3U'); if (manifestStart > 0) playlist = playlist.slice(manifestStart);
  if (inject) {
    source.startPts ??= detectStartPts(source, upstream.url, playlist);
    playlist = injectRenditions(playlist, source, id);
  }
  playlist = rewriteUriLines(playlist, upstream.url, id, source);
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
    if (request.method === 'GET' && requestUrl.pathname === '/health') return json(response, 200, { ok: true, provider: provider.type, version: bridgeVersion });
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
      const results = await provider.search(requestUrl.searchParams.get('q') ?? '');
      console.info(`[bridge] Search returned ${results.length} result(s)`);
      return json(response, 200, { results });
    }
    if (request.method === 'GET' && requestUrl.pathname === '/api/latest') return json(response, 200, await provider.latest(requestUrl.searchParams));
    if (request.method === 'GET' && requestUrl.pathname === '/api/schedule') return json(response, 200, { entries: await provider.schedule() });
    if (request.method === 'GET' && requestUrl.pathname === '/api/history') {
      return json(response, 200, await storedHistory(user.userId));
    }
    if (request.method === 'PUT' && requestUrl.pathname === '/api/history') {
      const body = JSON.parse(await readBody(request));
      return json(response, 200, await mergeHistory(user.userId, body));
    }
    if (request.method === 'GET' && requestUrl.pathname === '/api/preferences') return json(response, 200, await storedPreferences(user.userId));
    if (request.method === 'PUT' && requestUrl.pathname === '/api/preferences') return json(response, 200, await mergePreferences(user.userId, JSON.parse(await readBody(request))));
    if (request.method === 'POST' && requestUrl.pathname === '/api/series') return json(response, 200, await getSeries(JSON.parse(await readBody(request)).watchUrl));
    if (request.method === 'POST' && requestUrl.pathname === '/api/series/status') return json(response, 200, await getSeriesStatuses(JSON.parse(await readBody(request)).watchUrls));
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
    json(response, error instanceof HttpError ? error.status : 502, { error: error.message });
  }
});
// Tests import the pure helpers without opening a port.
if (!process.env.BRIDGE_NO_LISTEN) server.listen(port, host, () => console.log(`AirPlay Subtitle Bridge: http://${host}:${port}`));

export { createAnkProvider, fetchUpstream, injectRenditions, normalizePreferences, normalizeHistoryEntry, subtitleDetails, subtitleTracks, transportStreamStartPts, withTimestampMap };
