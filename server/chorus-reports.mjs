import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const sources = {
  manual_database: 'サビDB（手動確認済み）',
  song_metadata: '曲データのサビ位置（旧データでは取得元不明）',
  songle: 'Songle',
  itunes_preview: 'プレビュー音源の冒頭',
  duration_estimate: '曲の長さから推定した位置'
};
const audioSources = { apple_music: 'Apple Music フル音源', full_audio: '共有・デモのフル音源', itunes_preview: 'iTunes プレビュー音源' };
const retentionMS = 30 * 24 * 60 * 60 * 1000;
const failure = (status, error) => ({ status, body: { error } });
const isObject = value => value && typeof value === 'object' && !Array.isArray(value);
function text(value, maximum, required = true) {
  if (typeof value !== 'string' || value.length > maximum || (required && !value.trim())) throw new Error('invalid');
  return value.trim();
}
function timestamp(value) {
  if (!Number.isInteger(value) || value < 0 || value > 86_400_000) throw new Error('invalid');
  return value;
}

export function normalizeReport(input) {
  if (!isObject(input) || !isObject(input.song) || !isObject(input.playback)) throw new Error('invalid');
  const id = text(input.id, 36).toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) throw new Error('invalid');
  const source = text(input.playback.source, 40);
  const audioSource = text(input.playback.audioSource, 40);
  if (!Object.hasOwn(sources, source) || !Object.hasOwn(audioSources, audioSource)) throw new Error('invalid');
  const startPositionMS = timestamp(input.playback.startPositionMS);
  if ((source === 'itunes_preview') !== (audioSource === 'itunes_preview') ||
      (source === 'itunes_preview' && startPositionMS !== 0)) throw new Error('invalid');
  if (!['solo', 'room'].includes(input.playMode)) throw new Error('invalid');
  let trackURL = null;
  if (input.song.trackURL != null) {
    const url = new URL(text(input.song.trackURL, 1024));
    if (url.protocol !== 'https:' || url.username || url.password) throw new Error('invalid');
    // Music links do not need a query string; discard tracking/identity parameters.
    url.search = ''; url.hash = '';
    trackURL = url.href;
  }
  // Never spread the request: extra identity fields are discarded at every level.
  return { id, song: { id: text(input.song.id, 200), title: text(input.song.title, 300),
    artist: text(input.song.artist, 300), durationMS: timestamp(input.song.durationMS),
    genre: text(input.song.genre, 100, false), trackURL },
    playback: { source, audioSource, startPositionMS }, playMode: input.playMode,
    appVersion: text(input.appVersion, 40), appBuild: text(input.appBuild, 40) };
}

const time = milliseconds => `${(milliseconds / 1000).toFixed(3)}秒`;
export function discordReport(report, receivedAt) {
  return {
    allowed_mentions: { parse: [] },
    embeds: [{ title: 'サビ位置の相違 · 匿名報告', color: 0xB44B37,
      fields: [
        { name: '曲名', value: report.song.title },
        { name: 'アーティスト', value: report.song.artist },
        { name: '曲ID', value: report.song.id },
        { name: '正解曲が流れた処理', value: sources[report.playback.source] },
        { name: '再生音源', value: audioSources[report.playback.audioSource], inline: true },
        { name: '再生開始位置', value: time(report.playback.startPositionMS), inline: true },
        { name: '曲の長さ', value: time(report.song.durationMS), inline: true },
        { name: 'ジャンル', value: report.song.genre || '未設定', inline: true },
        { name: 'プレイ', value: report.playMode === 'room' ? '対戦' : 'ソロ', inline: true },
        { name: 'アプリ', value: `${report.appVersion} (${report.appBuild})`, inline: true },
        ...(report.song.trackURL ? [{ name: '曲のリンク', value: report.song.trackURL }] : [])
      ], footer: { text: `匿名 · 報告ID: ${report.id}` }, timestamp: new Date(receivedAt).toISOString() }]
  };
}

function webhookAddress(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password ||
        !['discord.com', 'discordapp.com', 'canary.discord.com', 'ptb.discord.com'].includes(url.hostname) ||
        !/^\/api(?:\/v\d+)?\/webhooks\/\d+\/[A-Za-z0-9._-]+$/.test(url.pathname)) return null;
    url.searchParams.set('wait', 'true');
    return url;
  } catch { return null; }
}

export function createChorusReportHandler({ dataDir = null,
  webhookURL = () => process.env.DISCORD_CHORUS_WEBHOOK_URL,
  fetchImpl = (...args) => fetch(...args), now = () => Date.now() } = {}) {
  const delivered = new Map();
  const pending = new Map();
  const file = dataDir ? join(dataDir, 'chorus-reports.json') : null;
  let windowStartedAt = 0;
  let deliveriesInWindow = 0;
  if (file && existsSync(file)) {
    try {
      for (const item of JSON.parse(readFileSync(file, 'utf8'))) {
        if (Number.isFinite(item.receivedAt) && now() - item.receivedAt < retentionMS) {
          const report = normalizeReport(item.report);
          delivered.set(report.id, { report, receivedAt: item.receivedAt });
        }
      }
    } catch { console.error('Anonymous chorus report receipts could not be loaded'); }
  }
  function prune() {
    for (const [id, item] of delivered) if (now() - item.receivedAt >= retentionMS) delivered.delete(id);
    while (delivered.size > 5000) delivered.delete(delivered.keys().next().value);
  }
  function persist() {
    if (!file) return;
    try {
      mkdirSync(dataDir, { recursive: true });
      writeFileSync(`${file}.tmp`, JSON.stringify([...delivered.values()]));
      renameSync(`${file}.tmp`, file);
    } catch { console.error('Anonymous chorus report receipts could not be saved'); }
  }
  return async input => {
    let report;
    try { report = normalizeReport(input); }
    catch { return failure(400, '報告の内容を確認できませんでした。'); }
    prune();
    const existing = delivered.get(report.id) ?? pending.get(report.id);
    if (existing) {
      if (JSON.stringify(existing.report) !== JSON.stringify(report)) return failure(409, 'この報告IDは使用済みです。');
      return existing.promise ?? { status: 200, body: { delivered: true, reportID: report.id } };
    }
    const url = webhookAddress(webhookURL());
    if (!url) return failure(503, '報告の受付は現在利用できません。しばらくしてから再試行してください。');
    if (now() - windowStartedAt >= 60_000) { windowStartedAt = now(); deliveriesInWindow = 0; }
    if (deliveriesInWindow >= 30) return failure(429, '報告が混み合っています。1分ほど待ってから再試行してください。');
    deliveriesInWindow++;
    const promise = (async () => {
      const receivedAt = now();
      try {
        const response = await fetchImpl(url, { method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(discordReport(report, receivedAt)), signal: AbortSignal.timeout(10_000), redirect: 'error' });
        if (!response.ok) return failure(response.status === 429 ? 429 : 502,
          '報告を送信できませんでした。しばらくしてから再試行してください。');
        // wait=true must return the created message; a bare 204 does not confirm delivery.
        const message = await response.json();
        if (typeof message.id !== 'string' || !message.id) throw new Error('Unconfirmed delivery');
        delivered.set(report.id, { report, receivedAt });
        prune(); persist();
        return { status: 200, body: { delivered: true, reportID: report.id } };
      } catch {
        // Do not expose the webhook token, Discord response, or network details.
        return failure(502, '報告を送信できませんでした。接続を確認して再試行してください。');
      }
    })();
    pending.set(report.id, { report, promise });
    try { return await promise; }
    finally { pending.delete(report.id); }
  };
}
