import assert from 'node:assert/strict';
import { test } from 'node:test';

process.env.BRIDGE_NO_LISTEN = '1';
process.env.PROVIDER_ORIGIN = 'https://catalog.example';
const { createAnkProvider, injectRenditions, normalizePreferences, normalizeHistoryEntry } = await import('../server.mjs');

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

test('History saved before a domain move keeps resuming', () => {
  const entry = normalizeHistoryEntry({ watchUrl: 'https://old-domain.example/watch/series-1', episode: 2, positionSeconds: 90 });
  assert.equal(entry.watchUrl, 'https://catalog.example/watch/series-1');
});

test('History rows keep a valid server kind only', () => {
  const base = { watchUrl: '/watch/example-1', episode: 3, positionSeconds: 12 };
  assert.equal(normalizeHistoryEntry({ ...base, serverKind: 'dub' }).serverKind, 'dub');
  assert.equal(normalizeHistoryEntry({ ...base, serverKind: 'raw' }).serverKind, null);
});
