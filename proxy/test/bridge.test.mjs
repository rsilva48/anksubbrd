import assert from 'node:assert/strict';
import { test } from 'node:test';

process.env.BRIDGE_NO_LISTEN = '1';
process.env.PROVIDER_ORIGIN = 'https://catalog.example';
const { createAnkProvider, injectRenditions, normalizePreferences, normalizeHistoryEntry, subtitleTracks, transportStreamStartPts, withTimestampMap } = await import('../server.mjs');

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
    titleLanguage: 'jp', defaultTrackType: 'dub', subtitleLanguage: 'es-419', autoNext: false, autoSkipIntro: false, autoSkipOutro: false,
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
