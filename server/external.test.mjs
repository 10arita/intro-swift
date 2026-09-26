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
  } finally { globalThis.fetch = original; }
});
