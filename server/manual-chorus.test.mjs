import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { manualChorusPosition, manualChorusIndex } from './manual-chorus.mjs';
import { chorusPosition } from './external.mjs';

test('all 600 manually confirmed recordings apply across albums without calling Songle', async () => {
  const catalog = JSON.parse(readFileSync(new URL('./manual-chorus.json', import.meta.url)));
  assert.equal(catalog.records.length, 600);
  assert.equal(manualChorusIndex.size, 600);
  const original = globalThis.fetch;
  globalThis.fetch = () => { throw new Error('Registered songs must not request Songle'); };
  try {
    for (const entry of catalog.records) {
      const song = { id: 'applemusic:different-album', title: entry.title, artist: entry.artist,
        album: 'Compilation', durationMS: entry.durationMS, chorusMS: 12345 };
      assert.equal(await chorusPosition(song), Math.max(0, entry.chorusStartMS - 1500));
      assert.equal(manualChorusPosition({ ...song, artist: 'Different artist' }), null);
      assert.equal(manualChorusPosition({ ...song, title: `${song.title} (Live)` }), null);
      assert.equal(await chorusPosition({ ...song, id: 'itunes:preview' }), null);
    }
  } finally { globalThis.fetch = original; }
});
