import { createAnonymousReportHandler } from './anonymous-reports.mjs';

const sources = {
  manual_database: 'サビDB（手動確認済み）',
  songle_database: 'サビDB（Songle取得済み）',
  song_metadata: '曲データのサビ位置（旧データでは取得元不明）',
  songle: 'Songle',
  itunes_preview: 'プレビュー音源の冒頭',
  duration_estimate: '曲の長さから推定した位置'
};
const audioSources = { apple_music: 'Apple Music フル音源', full_audio: '共有・デモのフル音源', itunes_preview: 'iTunes プレビュー音源' };
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

export function createChorusReportHandler(options = {}) {
  return createAnonymousReportHandler({ webhookURL: () => process.env.DISCORD_CHORUS_WEBHOOK_URL,
    ...options, normalizeReport, discordReport,
    receiptName: 'chorus-reports.json' });
}
