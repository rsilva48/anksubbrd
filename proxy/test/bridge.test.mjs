import assert from 'node:assert/strict';
import { test } from 'node:test';

process.env.BRIDGE_NO_LISTEN = '1';
process.env.PROVIDER_ORIGIN = 'https://catalog.example';
// Identities created by the tests go to a throwaway store.
process.env.BRIDGE_USER_STORE_PATH = (await import('node:path')).join((await import('node:os')).tmpdir(), `anksubbrd-users-${process.pid}-${Date.now()}.json`);
process.env.BRIDGE_ADMIN_TOKEN = 'admin-secret';
const { approvePairing, completeSetup, createIdentity, liveContainerLinks, setupForm, createAnkProvider, listDevices, reportDevice, sendCommand, waitForCommands, fetchUpstream, injectRenditions, pairingStatus, startPairing, normalizePreferences, normalizeHistoryEntry, subtitleTracks, transportStreamStartPts, withTimestampMap } = await import('../server.mjs');

// One 188-byte MPEG-TS packet starting a PES with only a PTS.
function pesPacket(streamId, pts) {
  const packet = Buffer.alloc(188, 0xff);
  packet.set([0x47, 0x40, 0x100 & 0xff, 0x10, 0x00, 0x00, 0x01, streamId, 0x00, 0x00, 0x80, 0x80, 0x05]);
  packet.set([0x21 | ((pts >>> 29) & 0x0e), (pts >>> 22) & 0xff, ((pts >>> 14) & 0xfe) | 1, (pts >>> 7) & 0xff, ((pts << 1) & 0xfe) | 1], 13);
  return packet;
}

const master = [
  '#EXTM3U',
  '#EXT-X-VERSION:3',
  '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720',
  'index-720.m3u8',
  '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080',
  'index-1080.m3u8',
  '',
].join('\n');
const subtitles = [
  { name: 'English', language: 'en', default: true },
  { name: 'Spanish', language: 'es', default: false },
];

test('Sub sources declare Japanese muxed audio and the subtitle group', () => {
  const playlist = injectRenditions(master, { kind: 'sub', subtitles, accessToken: '' }, 'abc');
  assert.match(playlist, /^#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="bridge-audio",NAME="Japanese",LANGUAGE="ja",DEFAULT=YES,AUTOSELECT=YES\n/);
  assert.doesNotMatch(playlist, /TYPE=AUDIO[^\n]*URI=/);
  assert.match(playlist, /NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="\/subtitle\/abc\/0\.m3u8"/);
  assert.match(playlist, /NAME="Spanish",LANGUAGE="es",DEFAULT=NO/);
  for (const line of playlist.split('\n').filter((value) => value.startsWith('#EXT-X-STREAM-INF:'))) {
    assert.match(line, /,AUDIO="bridge-audio",SUBTITLES="bridge-subs"$/);
  }
});

test('Dub sources declare English audio', () => {
  const playlist = injectRenditions(master, { kind: 'dub', subtitles: [], accessToken: '' }, 'abc');
  assert.match(playlist, /NAME="English",LANGUAGE="en",DEFAULT=YES/);
  assert.doesNotMatch(playlist, /TYPE=SUBTITLES/);
});

test('Forced tracks are flagged and never the default; repeated names get a number', () => {
  const vtt = (file) => ({ kind: 'captions', label: '', file: `https://cdn.example/subs/${file}` });
  const tracks = subtitleTracks([
    vtt('track_0_Forced_eng.vtt'), vtt('track_1_eng.vtt'), vtt('track_2_Dubtitle_eng.vtt'),
    vtt('track_13_Latin_American__Forced__spa.vtt'), vtt('track_14_Latin_American_spa.vtt'),
    vtt('spa-1.vtt'), vtt('spa-2.vtt'),
  ], 'https://cdn.example/');
  assert.deepEqual(tracks.map(({ name, language, forced, default: isDefault }) => [name, language, forced, isDefault]), [
    ['English (Forced)', 'en', true, false],
    ['English', 'en', false, true],
    ['English (Dubtitle)', 'en', false, false],
    ['Spanish (Latin American, Forced)', 'es-419', true, false],
    ['Spanish (Latin American)', 'es-419', false, false],
    ['Spanish', 'es', false, false],
    ['Spanish 2', 'es', false, false],
  ]);
  const playlist = injectRenditions(master, { kind: 'sub', subtitles: tracks, accessToken: '' }, 'abc');
  assert.match(playlist, /NAME="English \(Forced\)",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,FORCED=YES,URI=/);
  assert.match(playlist, /NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI=/);
  assert.doesNotMatch(playlist, /NAME="English",[^\n]*FORCED/);
});

test('The audio declaration can be switched off', () => {
  const playlist = injectRenditions(master, { kind: 'sub', declareAudio: false, subtitles, accessToken: '' }, 'abc');
  assert.doesNotMatch(playlist, /TYPE=AUDIO|AUDIO="/);
  assert.match(playlist, /TYPE=SUBTITLES/);
});

test('Stream start is the earliest audio/video PTS of the first segment', () => {
  const segment = Buffer.concat([pesPacket(0xe0, 16290), pesPacket(0xc0, 9090), pesPacket(0xe0, 19890)]);
  assert.equal(transportStreamStartPts(segment), 9090);
  assert.equal(transportStreamStartPts(Buffer.from('not a transport stream')), null);
});

test('WebVTT gets a timestamp map anchored to the stream start', () => {
  const vtt = 'WEBVTT\n\n00:20.240 --> 00:29.210\nHello\n';
  assert.equal(withTimestampMap(vtt, 9090), 'WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:9090,LOCAL:00:00:00.000\n\n00:20.240 --> 00:29.210\nHello\n');
  assert.equal(withTimestampMap(vtt, null), vtt);
  const mapped = 'WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n';
  assert.equal(withTimestampMap(mapped, 9090), mapped);
});

test('Existing audio renditions only receive a missing language', () => {
  const withAudio = master.replace('#EXT-X-VERSION:3', '#EXT-X-VERSION:3\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Main",DEFAULT=YES,URI="audio.m3u8"');
  const playlist = injectRenditions(withAudio, { kind: 'sub', subtitles: [], accessToken: '' }, 'abc');
  assert.match(playlist, /GROUP-ID="aac",NAME="Main",DEFAULT=YES,URI="audio\.m3u8",LANGUAGE="ja"/);
  assert.doesNotMatch(playlist, /bridge-audio/);
});

test('Media playlists are returned unchanged', () => {
  const media = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nsegment0.ts\n#EXT-X-ENDLIST\n';
  assert.equal(injectRenditions(media, { kind: 'sub', subtitles, accessToken: '' }, 'abc'), media);
});

test('Preferences are coerced to the supported values', () => {
  const swiftEpoch = 978307200;
  const value = normalizePreferences({ titleLanguage: 'jp', defaultTrackType: 'dub', subtitleLanguage: 'es-419', autoNext: false, autoSkipIntro: 'yes', updatedAt: 1000 });
  assert.deepEqual(value, {
    titleLanguage: 'jp', defaultTrackType: 'dub', subtitleLanguage: 'es-419', autoNext: false, autoSkipIntro: false, autoSkipOutro: false, hideAdult: false,
    updatedAt: new Date((1000 + swiftEpoch) * 1000).toISOString(),
  });
  assert.equal(normalizePreferences({ titleLanguage: 'fr' }).titleLanguage, 'en');
  assert.equal(normalizePreferences({ subtitleLanguage: 'off' }).subtitleLanguage, 'off');
  assert.equal(normalizePreferences({ subtitleLanguage: '<script>' }).subtitleLanguage, '');
  assert.throws(() => normalizePreferences(null));
});

test('ANK watch URLs are rebased onto the configured origin', () => {
  const provider = createAnkProvider('https://new-domain.example/');
  assert.equal(provider.type, 'ANK');
  assert.equal(provider.origin, 'https://new-domain.example');
  assert.equal(provider.watchUrl('https://old-domain.example/watch/series-1?ep=3'), 'https://new-domain.example/watch/series-1');
  assert.equal(provider.watchUrl('/watch/series-1'), 'https://new-domain.example/watch/series-1');
  assert.throws(() => provider.watchUrl('https://new-domain.example/user/settings'), /Only catalog watch URLs/);
});

test('Recent episodes come from the card badges, not the /ep-1 link', async (context) => {
  const card = (slug, badges) => `<div class="item"><div class="ani poster tip"><a href="/watch/${slug}/ep-1"><img src="/p.jpg"><div class="meta"><div class="inner"><div class="left">${badges}</div><div class="right">TV</div></div></div></a></div><div class="info"><div class="b1"><a class="name d-title" href="/watch/${slug}/ep-1" data-jp="JP ${slug}">Title ${slug}</a></div><div class="meta"><div class="m-item rated"><span>7.5</span></div></div></div></div>`;
  const html = card('alpha-1', '<span class="ep-status sub"><span> 32</span></span><span class="ep-status total"><span>34</span></span>')
    + card('beta-2', '<span class="ep-status sub"><span>4</span></span><span class="ep-status dub"><span>6</span></span>')
    + card('gamma-3', '');
  context.mock.method(globalThis, 'fetch', async () => new Response(html, { status: 200 }));
  const { results } = await createAnkProvider('https://catalog.example').latest(new URLSearchParams());
  assert.deepEqual(results.map(({ watchUrl, episode, subEpisodes, dubEpisodes, totalEpisodes }) => ({ watchUrl, episode, subEpisodes, dubEpisodes, totalEpisodes })), [
    { watchUrl: 'https://catalog.example/watch/alpha-1', episode: 32, subEpisodes: 32, dubEpisodes: null, totalEpisodes: 34 },
    { watchUrl: 'https://catalog.example/watch/beta-2', episode: 6, subEpisodes: 4, dubEpisodes: 6, totalEpisodes: null },
    { watchUrl: 'https://catalog.example/watch/gamma-3', episode: 1, subEpisodes: null, dubEpisodes: null, totalEpisodes: null },
  ]);
});

test('History saved before a domain move keeps resuming', () => {
  const entry = normalizeHistoryEntry({ watchUrl: 'https://old-domain.example/watch/series-1', episode: 2, positionSeconds: 90 });
  assert.equal(entry.watchUrl, 'https://catalog.example/watch/series-1');
});

test('History rows keep a valid server kind only', () => {
  const base = { watchUrl: '/watch/example-1', episode: 3, positionSeconds: 12 };
  assert.equal(normalizeHistoryEntry({ ...base, serverKind: 'dub' }).serverKind, 'dub');
  assert.equal(normalizeHistoryEntry({ ...base, serverKind: 'raw' }).serverKind, null);
});

test('History rows keep completion details for the Continue screen', () => {
  const base = { watchUrl: '/watch/example-1', episode: 12, positionSeconds: 1400 };
  const entry = normalizeHistoryEntry({ ...base, durationSeconds: 1420, completed: true, totalEpisodes: 12 });
  assert.deepEqual([entry.durationSeconds, entry.completed, entry.totalEpisodes], [1420, true, 12]);
  const legacy = normalizeHistoryEntry(base);
  assert.deepEqual([legacy.durationSeconds, legacy.completed, legacy.totalEpisodes], [null, false, null]);
  assert.equal(normalizeHistoryEntry({ ...base, completed: 'yes', totalEpisodes: -1 }).completed, false);
});

test('Sub and Dub recents use the home widgets and flag adult cards', async (context) => {
  const html = '<div class="item"><div class="ani poster"><a href="/watch/delta-4/ep-9"><img src="/p.jpg"><div class="meta"><div class="inner"><div class="left"><span class="ep-status sub"><span> 9</span></span><span class="ep-status dub"><span> 8</span></span></div></div></div></a><div class="adult"></div></div><div class="info"><a class="name d-title" href="/watch/delta-4/ep-9">Delta</a></div></div>';
  const requested = [];
  context.mock.method(globalThis, 'fetch', async (url) => { requested.push(String(url)); return Response.json({ status: 200, result: html }); });
  const { results, hasNext } = await createAnkProvider('https://catalog.example').latest(new URLSearchParams({ language: 'dub', page: '2' }));
  assert.equal(requested[0], 'https://catalog.example/ajax/home/widget/updated-dub?page=2');
  assert.deepEqual(results.map(({ episode, adult }) => ({ episode, adult })), [{ episode: 8, adult: true }]);
  assert.equal(hasNext, false);
});

test('The schedule lists one entry per series, episode and kind with its airing time', async (context) => {
  const day = '<div class="sc-grp" data-airing="1793896080"><a class="sc-card" href="https://x.example/watch/delta-4/ep-5?type=sub" data-type="sub"><img src="/p.jpg"><span class="sc-tt"><div class="sc-name d-title" data-jp="Delta JP">Delta</div><div class="sc-meta"><span class="sc-ep">Episode 5</span></div></span><span class="sc-go"><span class="sc-cd" data-airing="1793896080"></span></span></a></div>';
  context.mock.method(globalThis, 'fetch', async () => Response.json({ status: 200, result: day }));
  const entries = await createAnkProvider('https://catalog.example').schedule();
  assert.deepEqual(entries, [{ watchUrl: 'https://catalog.example/watch/delta-4', title: 'Delta', titleJp: 'Delta JP', imageUrl: 'https://catalog.example/p.jpg', episode: 5, kind: 'sub', airingAt: 1793896080 }]);
});

test('Upstream requests re-sign CDN tokens that are missing or about to expire', () => {
  const provider = createAnkProvider('https://catalog.example');
  const path = `https://cdn.example/${'a'.repeat(32)}/${'b'.repeat(32)}/master.m3u8`;
  const source = { hlsUrl: path };
  const expiry = (url) => Number(Buffer.from(new URL(url).searchParams.get('token').split('.')[0], 'base64url').toString('utf8').split('|')[0]);
  const now = Date.now() / 1000;
  const stale = `${path}?token=${Buffer.from(`${Math.floor(now) - 5}|x`).toString('base64url')}.sig`;
  assert.ok(expiry(provider.signUpstream(stale, source)) > now + 60);
  const fresh = provider.signUpstream(path, source);
  assert.ok(expiry(fresh) > now + 60);
  assert.equal(provider.signUpstream(fresh, source), fresh);
  assert.equal(provider.signUpstream('https://other.example/seg-1.ts', source), 'https://other.example/seg-1.ts');
});

test('Rate-limited playlists are retried after Retry-After and then served from cache', async (context) => {
  let calls = 0;
  context.mock.method(globalThis, 'fetch', async () => {
    calls += 1;
    return calls === 1
      ? new Response('slow down', { status: 429, headers: { 'retry-after': '1' } })
      : new Response('#EXTM3U\nseg-1.ts\n', { status: 200, headers: { 'content-type': 'application/vnd.apple.mpegurl' } });
  });
  const source = { hlsUrl: 'https://cdn.example/master.m3u8', requestHeaders: {} };
  const first = await fetchUpstream('https://cdn.example/index.m3u8', source, null, 10000);
  const second = await fetchUpstream('https://cdn.example/index.m3u8', source, null, 10000);
  assert.equal(first.body.toString(), '#EXTM3U\nseg-1.ts\n');
  assert.equal(second.body.toString(), first.body.toString());
  assert.equal(calls, 2);
});

test('A 429 that persists after the retries becomes a temporary 503', async (context) => {
  context.mock.method(globalThis, 'fetch', async () => new Response('', { status: 429, headers: { 'retry-after': '1' } }));
  await assert.rejects(fetchUpstream('https://cdn.example/seg.ts', { hlsUrl: 'https://cdn.example/m.m3u8', requestHeaders: {} }, null, 3000), (error) => error.status === 503);
});

test('Catalog filters accept several values per category', async (context) => {
  const requested = [];
  context.mock.method(globalThis, 'fetch', async (url) => { requested.push(new URL(String(url))); return new Response('', { status: 200 }); });
  const params = new URLSearchParams([['season', 'fall'], ['season', 'summer'], ['year', '2026'], ['year', '2025'], ['status', 'finished-airing'], ['status', 'currently-airing'], ['language', 'sub']]);
  await createAnkProvider('https://catalog.example').latest(params);
  const url = requested[0];
  assert.equal(url.pathname, '/filter');
  assert.deepEqual(url.searchParams.getAll('season[]'), ['fall', 'summer']);
  assert.deepEqual(url.searchParams.getAll('year[]'), ['2026', '2025']);
  assert.deepEqual(url.searchParams.getAll('status[]'), ['finished-airing', 'currently-airing']);
  assert.deepEqual(url.searchParams.getAll('language[]'), ['sub']);
  await assert.rejects(createAnkProvider('https://catalog.example').latest(new URLSearchParams([['season', 'fall'], ['season', 'monsoon']])), (error) => error.status === 400);
});

test('Genre, source, sort and episode-count filters reach the catalog', async (context) => {
  const requested = [];
  context.mock.method(globalThis, 'fetch', async (url) => { requested.push(new URL(String(url))); return new Response('', { status: 200 }); });
  const provider = createAnkProvider('https://catalog.example');
  const genre = provider.filters.genres.find((option) => option.label === 'Comedia').id;
  await provider.latest(new URLSearchParams([['genre', genre], ['genre', '1'], ['source', 'manga'], ['sort', 'score'], ['mediaType', 'TV Special'], ['minEpisodes', '12'], ['maxEpisodes', '26']]));
  const url = requested[0];
  assert.equal(url.pathname, '/filter');
  assert.deepEqual(url.searchParams.getAll('genre[]'), [genre, '1']);
  assert.deepEqual(url.searchParams.getAll('source[]'), ['manga']);
  assert.deepEqual(url.searchParams.getAll('term_type[]'), ['TV Special']);
  assert.equal(url.searchParams.get('sort'), 'score');
  assert.equal(url.searchParams.get('ep_min'), '12');
  assert.equal(url.searchParams.get('ep_max'), '26');
  assert.ok(provider.filters.genres.find((option) => option.label === 'Hentai').adult);
  await assert.rejects(provider.latest(new URLSearchParams([['genre', '99999']])), (error) => error.status === 400);
  await assert.rejects(provider.latest(new URLSearchParams([['minEpisodes', '0']])), (error) => error.status === 400);
});

test('Preferences keep the hide-adult setting', () => {
  assert.equal(normalizePreferences({ hideAdult: true }).hideAdult, true);
  assert.equal(normalizePreferences({}).hideAdult, false);
});

test('QR pairing hands the approving identity to the TV exactly once', () => {
  const { pairingId, code } = startPairing();
  assert.equal(pairingStatus(pairingId).status, 'pending');
  assert.throws(() => approvePairing('wrong-code', 'Sala', { token: 'abc' }), (error) => error.status === 404);
  assert.deepEqual(approvePairing(code, 'Sala', { token: 'abc' }), { ok: true });
  assert.throws(() => approvePairing(code, 'Otra', { token: 'xyz' }), (error) => error.status === 404 || error.status === 409);
  assert.deepEqual(pairingStatus(pairingId), { status: 'approved', token: 'abc', label: 'Sala' });
  assert.equal(pairingStatus(pairingId).status, 'expired');
  assert.equal(pairingStatus('unknown').status, 'expired');
});

test('Remote control: a TV reports itself and receives commands from the same identity', async () => {
  const { EventEmitter } = await import('node:events');
  const tv = { userId: 'remote-user', token: 't' };
  const other = { userId: 'someone-else', token: 'o' };
  const deviceId = 'tv-0123456789';
  reportDevice(tv, deviceId, { name: 'Sala', canOpen: true, state: { status: 'playing', seriesTitle: 'Delta', episode: 3, position: 61.5, duration: 1440, kind: 'sub' } });
  assert.deepEqual(listDevices(tv).devices.map(({ id, name, state, canOpen }) => [id, name, state.status, state.episode, canOpen]), [[deviceId, 'Sala', 'playing', 3, true]]);
  assert.ok(listDevices(tv).devices[0].stateAge >= 0);
  assert.equal(listDevices(other).devices.length, 0);
  assert.throws(() => sendCommand(other, deviceId, { type: 'pause' }), (error) => error.status === 404);
  assert.throws(() => sendCommand(tv, deviceId, { type: 'explode' }), (error) => error.status === 400);
  assert.throws(() => sendCommand(tv, deviceId, { type: 'seek' }), (error) => error.status === 400);

  // A waiting long poll is answered as soon as a command arrives.
  const response = Object.assign(new EventEmitter(), { destroyed: false, writableEnded: false });
  const pending = waitForCommands(tv, deviceId, response, 5000);
  sendCommand(tv, deviceId, { type: 'seek', seconds: -10 });
  const reply = await pending;
  assert.deepEqual(reply.commands.map(({ type, seconds }) => [type, seconds]), [['seek', -10]]);

  // Scrubbing sends an absolute position.
  sendCommand(tv, deviceId, { type: 'seek', position: 754.2 });
  const scrub = await waitForCommands(tv, deviceId, Object.assign(new EventEmitter(), { destroyed: false, writableEnded: false }), 50);
  assert.deepEqual(scrub.commands.map(({ type, position, seconds }) => [type, position, seconds]), [['seek', 754.2, undefined]]);

  // The phone's volume buttons send volume steps.
  assert.throws(() => sendCommand(tv, deviceId, { type: 'volume', steps: 0 }), (error) => error.status === 400);
  sendCommand(tv, deviceId, { type: 'volume', steps: -2 });
  const volume = await waitForCommands(tv, deviceId, Object.assign(new EventEmitter(), { destroyed: false, writableEnded: false }), 50);
  assert.deepEqual(volume.commands.map(({ type, steps }) => [type, steps]), [['volume', -2]]);

  // Subtitle tracks: the TV lists them, the phone picks one (or "off").
  reportDevice(tv, deviceId, { name: 'Sala', state: { status: 'playing', subtitles: [{ id: '2:0', label: 'English' }, { id: 'x', label: 'bad' }], subtitle: '2:0' } });
  assert.deepEqual(listDevices(tv).devices[0].state.subtitles, [{ id: '2:0', label: 'English' }]);
  assert.equal(listDevices(tv).devices[0].state.subtitle, '2:0');
  assert.throws(() => sendCommand(tv, deviceId, { type: 'subtitles', track: '../x' }), (error) => error.status === 400);
  sendCommand(tv, deviceId, { type: 'subtitles', track: '3:1' });
  sendCommand(tv, deviceId, { type: 'subtitles' });
  const subtitles = await waitForCommands(tv, deviceId, Object.assign(new EventEmitter(), { destroyed: false, writableEnded: false }), 50);
  assert.deepEqual(subtitles.commands.map(({ track }) => track), ['3:1', 'off']);

  // Acknowledged delivery: a command answered to a poll stays queued until a
  // later poll acknowledges it (a TV restarted behind a proxy loses nothing).
  const fresh = () => Object.assign(new EventEmitter(), { destroyed: false, writableEnded: false });
  sendCommand(tv, deviceId, { type: 'pause' });
  const first = await waitForCommands(tv, deviceId, fresh(), 50, 0);
  assert.deepEqual(first.commands.map(({ type }) => type), ['pause']);
  const again = await waitForCommands(tv, deviceId, fresh(), 50, 0);
  assert.deepEqual(again.commands.map(({ seq }) => seq), first.commands.map(({ seq }) => seq));
  const acknowledged = await waitForCommands(tv, deviceId, fresh(), 50, first.commands.at(-1).seq);
  assert.deepEqual(acknowledged.commands, []);

  // Commands queued while the TV is away are delivered on its next poll.
  sendCommand(tv, deviceId, { type: 'play', watchUrl: '/watch/delta-4', episode: 5, kind: 'dub' });
  const next = await waitForCommands(tv, deviceId, Object.assign(new EventEmitter(), { destroyed: false, writableEnded: false }), 50);
  assert.deepEqual(next.commands.map(({ type, watchUrl, episode, kind }) => [type, watchUrl, episode, kind]), [['play', 'https://catalog.example/watch/delta-4', 5, 'dub']]);
});

test('A profile creates profiles, and a TV is set up from the browser page', async () => {
  const parent = { userId: 'parent-user', token: 'a'.repeat(64) };
  const created = await createIdentity(parent, 'Sala');
  assert.match(created.token, /^[a-f0-9]{64}$/);
  await assert.rejects(createIdentity({ userId: 'local', token: '' }, 'Sala'), (error) => error.status === 409);

  // First setup with the administrator token creates the TV's identity.
  const first = startPairing();
  await assert.rejects(completeSetup({ code: first.code, mode: 'create', adminToken: 'wrong', label: 'Ana' }), (error) => error.status === 401);
  await completeSetup({ code: first.code, mode: 'create', adminToken: 'admin-secret', label: 'Ana' });
  const approved = pairingStatus(first.pairingId);
  assert.equal(approved.label, 'Ana');
  assert.match(approved.token, /^[a-f0-9]{64}$/);

  // An existing identity's token links the TV to that identity.
  const second = startPairing();
  await assert.rejects(completeSetup({ code: second.code, mode: 'existing', token: 'b'.repeat(64) }), (error) => error.status === 401);
  await completeSetup({ code: second.code, mode: 'existing', token: created.token, label: 'Sala' });
  assert.equal(pairingStatus(second.pairingId).token, created.token);

  // A code allows a few attempts.
  const third = startPairing();
  for (let attempt = 0; attempt < 5; attempt += 1) await assert.rejects(completeSetup({ code: third.code, mode: 'existing', token: 'c'.repeat(64) }), (error) => error.status === 401);
  await assert.rejects(completeSetup({ code: third.code, mode: 'existing', token: created.token }), (error) => error.status === 429);
  await assert.rejects(completeSetup({ code: third.code, mode: 'existing', token: created.token }), (error) => error.status === 404);

  // Each identity creates at most five profiles an hour.
  for (let count = 1; count < 5; count += 1) await createIdentity(parent, `Perfil ${count}`);
  await assert.rejects(createIdentity(parent, 'Uno más'), (error) => error.status === 429);
});

test('The setup page opens the app directly or through LiveContainer', () => {
  const app = 'anksubbrd://pair?bridge=https%3A%2F%2Fbridge.example&code=abc_-1';
  const links = liveContainerLinks(app);
  // LiveContainer decodes standard Base64 after URL decoding the query.
  const decode = (link, name) => Buffer.from(new URL(link).searchParams.get(name), 'base64').toString('utf8');
  assert.match(links.byScheme, /^livecontainer:\/\/open-url\?url=/);
  assert.equal(decode(links.byScheme, 'url'), app);
  assert.match(links.byName, /^livecontainer:\/\/livecontainer-launch\?bundle-name=com\.personal\.airplaysubtitleplayer\.app&open-url=/);
  assert.equal(decode(links.byName, 'open-url'), app);

  const { code } = startPairing();
  const request = { headers: { host: 'bridge.example', 'x-forwarded-proto': 'https' }, socket: {} };
  const page = setupForm(request, code);
  assert.ok(page.includes(`href="anksubbrd://pair?bridge=`));
  assert.ok(page.includes('href="livecontainer://open-url?url='));
  assert.ok(page.includes('href="livecontainer://livecontainer-launch?bundle-name='));
});

test('Cast links open one playback without the identity token and can be revoked', async () => {
  const { castSource, revokeCast, rewriteUriLines, shareForCast, sources } = await import('../server.mjs');
  const owner = { userId: 'cast-owner', token: 'd'.repeat(64) };
  sources.set('cast-source-1', {
    hlsUrl: 'https://cdn.example/master.m3u8', userId: owner.userId, accessToken: owner.token, expiresAt: Date.now() + 60_000,
    subtitles: [{ name: 'English', language: 'en', default: true, forced: false, vttUrl: 'https://cdn.example/en.vtt' }, { name: 'Signs', language: 'en', default: false, forced: true, vttUrl: 'https://cdn.example/signs.vtt' }],
  });
  const playbackUrl = `https://bridge.example/watch/cast-source-1/master.m3u8?access_token=${owner.token}`;
  assert.throws(() => shareForCast({ userId: 'someone-else', token: 'e'.repeat(64) }, playbackUrl, 'https://bridge.example'), (error) => error.status === 403);
  assert.throws(() => shareForCast(owner, 'https://bridge.example/watch/missing/master.m3u8', 'https://bridge.example'), (error) => error.status === 404);

  const share = shareForCast(owner, playbackUrl, 'https://bridge.example');
  assert.match(share.url, /^https:\/\/bridge\.example\/cast\/[\w-]{32}\/master\.m3u8$/);
  assert.ok(!JSON.stringify(share).includes(owner.token));
  assert.deepEqual(share.subtitles.map((track) => [track.id, track.language, track.forced, track.default]), [[1, 'en', false, true], [2, 'en', true, false]]);
  assert.equal(share.subtitles[0].url, `https://bridge.example/cast/${share.id}/subtitle/0.vtt`);
  assert.equal(castSource(share.id).id, 'cast-source-1');

  // Segments and nested playlists become token-free cast links.
  const castLink = (upstream) => `/cast/${share.id}/media?url=${encodeURIComponent(upstream)}`;
  const rewritten = rewriteUriLines('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI="audio.m3u8"\nseg-1.ts\n', 'https://cdn.example/v/index.m3u8', 'cast-source-1', sources.get('cast-source-1'), castLink);
  assert.ok(!rewritten.includes('access_token'));
  assert.ok(rewritten.includes(`URI="/cast/${share.id}/media?url=${encodeURIComponent('https://cdn.example/v/audio.m3u8')}"`));
  assert.ok(rewritten.includes(`/cast/${share.id}/media?url=${encodeURIComponent('https://cdn.example/v/seg-1.ts')}`));
  // Without a link builder the app's own playlists keep the token.
  assert.ok(rewriteUriLines('seg-1.ts', 'https://cdn.example/v/index.m3u8', 'cast-source-1', sources.get('cast-source-1')).includes('access_token='));

  // Another identity cannot revoke it; its owner can.
  revokeCast({ userId: 'someone-else' }, share.id);
  assert.ok(castSource(share.id));
  revokeCast(owner, share.id);
  assert.equal(castSource(share.id), null);

  // A link stops working when its playback expires.
  const second = shareForCast(owner, playbackUrl, 'https://bridge.example');
  sources.delete('cast-source-1');
  assert.equal(castSource(second.id), null);
});

test('Cast routes answer the receiver with CORS, without the identity token', async (context) => {
  const http = await import('node:http');
  const { server, shareForCast, sources } = await import('../server.mjs');
  const vtt = 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n';
  const upstream = http.createServer((request, response) => { response.writeHead(200, { 'content-type': 'text/vtt' }); response.end(vtt); });
  await new Promise((done) => upstream.listen(0, '127.0.0.1', done));
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  context.after(() => { upstream.close(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const owner = { userId: 'cast-http', token: 'f'.repeat(64) };
  sources.set('cast-source-2', {
    hlsUrl: 'https://cdn.example/master.m3u8', userId: owner.userId, accessToken: owner.token, expiresAt: Date.now() + 60_000,
    subtitles: [{ name: 'English', language: 'en', default: true, forced: false, vttUrl: `http://127.0.0.1:${upstream.address().port}/en.vtt` }],
  });
  const share = shareForCast(owner, `${base}/watch/cast-source-2/master.m3u8`, base);

  const preflight = await fetch(`${base}/cast/${share.id}/master.m3u8`, { method: 'OPTIONS' });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('access-control-allow-origin'), '*');
  assert.match(preflight.headers.get('access-control-allow-headers'), /Range/);

  const subtitle = await fetch(share.subtitles[0].url);
  assert.equal(subtitle.status, 200);
  assert.equal(subtitle.headers.get('access-control-allow-origin'), '*');
  assert.match(subtitle.headers.get('content-type'), /text\/vtt/);
  // Side-loaded tracks keep the provider's timing (no HLS timestamp map).
  assert.equal(await subtitle.text(), vtt);

  const forged = await fetch(`${base}/cast/${share.id}/media?url=${encodeURIComponent('https://elsewhere.example/a.ts')}&sig=nope`);
  assert.equal(forged.status, 403);
  const unknown = await fetch(`${base}/cast/${'x'.repeat(32)}/master.m3u8`);
  assert.equal(unknown.status, 404);
  assert.equal(unknown.headers.get('access-control-allow-origin'), '*');
  sources.delete('cast-source-2');
});
