import test from 'node:test';
import assert from 'node:assert/strict';
import { matchItunes, topSongs, chorusPosition, fallbackChorus } from './external.mjs';

test('iTunes matching requires the title and artist, and Songle starts before the chorus', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async url => {
    const address = String(url);
    if (address.includes('itunes.apple.com/search')) return new Response(JSON.stringify({ results: [
      { trackId: 1, trackName: '怪獣の花唄', artistName: '別の人', previewUrl: 'https://audio.example/1.m4a' },
      { trackId: 2, trackName: '怪獣の花唄', artistName: 'Vaundy', previewUrl: 'https://audio.example/2.m4a',
        trackTimeMillis: 220000, primaryGenreName: 'J-Pop' }
    ] }), { status: 200 });
    if (address.includes('rss.applemarketingtools.com')) return new Response(JSON.stringify({ feed: { results: [{ name: '群青' }] } }), { status: 200 });
    if (address.includes('song/chorus.json')) return new Response(JSON.stringify({ chorusSegments: [
      { isChorus: true, repeats: [{ start: 65125.6 }] }
    ] }), { status: 200 });
    throw new Error(`Unexpected URL: ${address}`);
  };
  try {
    const match = await matchItunes({ title: '怪獣の花唄 (Live)', artist: 'Vaundy' });
    assert.equal(match.id, 'itunes:2');
    assert.equal(match.genre, 'J-Pop');
    assert.deepEqual(await topSongs(), ['群青']);
    assert.equal(await chorusPosition({ durationMS: 220000, songleURL: 'https://www.youtube.com/watch?v=abc' }), 63626);
    assert.equal(fallbackChorus(180000), 56100);
    assert.equal(fallbackChorus(181234), 56495);
  } finally { globalThis.fetch = original; }
});

test('Songle search uses the original video permalink for a revealed Apple Music song', async () => {
  const original = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async url => {
    const address = new URL(url);
    requests.push(address);
    if (address.pathname.endsWith('/songs/search.json')) return new Response(JSON.stringify([
      { title: '青い空', artist: { name: '別の人' }, permalink: 'http://www.youtube.com/watch?v=wrong' },
      { title: '青い空', artist: { name: '歌手' }, duration: 400000,
        permalink: 'http://www.youtube.com/watch?v=other-version' },
      { title: '青い空', artist: { name: '歌手' },
        duration: 210100,
        url: 'https://songle.jp/songs/www.youtube.com%2Fwatch%3Fv%3Dcorrect',
        permalink: 'http://www.youtube.com/watch?v=correct' }
    ]), { status: 200 });
    if (address.pathname.endsWith('/song/chorus.json')) return new Response(JSON.stringify({
      chorusSegments: [{ isChorus: true, repeats: [{ start: 64000 }] }]
    }), { status: 200 });
    throw new Error(`Unexpected URL: ${address}`);
  };
  try {
    assert.equal(await chorusPosition({ title: '青い空', artist: '歌手', durationMS: 210000 }), 62500);
    assert.equal(requests.length, 2);
    assert.equal(requests[1].searchParams.get('url'), 'www.youtube.com/watch?v=correct');
  } finally { globalThis.fetch = original; }
});

test('Songle page URLs resolve to their original video', async () => {
  const original = globalThis.fetch;
  let sourceURL;
  globalThis.fetch = async url => {
    sourceURL = new URL(url).searchParams.get('url');
    return new Response(JSON.stringify({ chorusSegments: [{ isChorus: true, repeats: [{ start: 50000 }] }] }), { status: 200 });
  };
  try {
    assert.equal(await chorusPosition({ durationMS: 180000,
      songleURL: 'https://songle.jp/songs/www.nicovideo.jp%2Fwatch%2Fsm123' }), 48500);
    assert.equal(sourceURL, 'www.nicovideo.jp/watch/sm123');
  } finally { globalThis.fetch = original; }
});

test('missing Songle chorus stays missing so the client can try a preview', async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({ chorusSegments: [] }), { status: 200 });
  try {
    assert.equal(await chorusPosition({ durationMS: 180000,
      songleURL: 'https://www.youtube.com/watch?v=no-chorus' }), null);
  } finally { globalThis.fetch = original; }
});
