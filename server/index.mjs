import { createServer } from 'node:http';
import { randomUUID, randomInt } from 'node:crypto';
import { createReadStream, readFileSync, statSync, existsSync, mkdirSync, writeFileSync, renameSync } from 'node:fs';
import { resolve, join } from 'node:path';
import WebSocket, { WebSocketServer } from 'ws';
import { searchItunes, matchItunes, topSongs, chorusPosition } from './external.mjs';

const rooms = new Map();
const profiles = new Map();
const DATA_DIR = process.env.DATA_DIR ? resolve(process.env.DATA_DIR) : null;
const DATA_FILE = DATA_DIR ? join(DATA_DIR, 'state.json') : null;
if (DATA_FILE && existsSync(DATA_FILE)) {
  try {
    const saved = JSON.parse(readFileSync(DATA_FILE, 'utf8'));
    for (const room of saved.rooms || []) {
      room.pushed = new Set(room.pushed || []); room.skipped = new Set(room.skipped || []);
      room.readyIds = new Set(room.readyIds || []);
      room.assetsReadyIds = new Set(room.assetsReadyIds || []);
      room.answers ||= room.answeringPlayerID ? [{ playerId: room.answeringPlayerID,
        progress: room.answerProgress || '', letterIndex: room.letterIndex || 0,
        deadline: room.answerDeadline, options: room.options || [], status: 'active' }] : [];
      room.pushAttempts ||= [...room.pushed].map(playerId => ({ playerId,
        pushTimeMS: room.answers.find(answer => answer.playerId === playerId)?.pushTimeMS ?? null }));
      room.pausedAt ||= null;
      room.pausedPositionMS ||= null;
      room.pushClosed ||= false;
      room.audioStoppedAt ||= null;
      room.correctPlayerIDs ||= room.correctPlayerID ? [room.correctPlayerID] : [];
      rooms.set(room.id, room);
    }
    for (const profile of saved.profiles || []) profiles.set(profile.id, profile);
  } catch (error) { console.error('Saved state could not be loaded:', error); }
}
let saveTimer;
export function saveStateNow() {
  if (!DATA_FILE) return;
  mkdirSync(DATA_DIR, { recursive: true });
  const temporary = `${DATA_FILE}.tmp`;
  writeFileSync(temporary, JSON.stringify({ rooms: [...rooms.values()].map(room => ({ ...room, pushed: [...room.pushed], skipped: [...room.skipped], readyIds: [...room.readyIds], assetsReadyIds: [...room.assetsReadyIds] })), profiles: [...profiles.values()] }));
  renameSync(temporary, DATA_FILE);
}
function persist() {
  if (!DATA_FILE || saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try { saveStateNow(); } catch (error) { console.error('State save failed:', error); }
  }, 500);
  saveTimer.unref();
}
const catalog = JSON.parse(readFileSync(new URL('./catalog.json', import.meta.url), 'utf8'));
const seedTitles = ['famousSongs.json', 'famousSongsJapaneseExpansion.json', 'famousSongsJpop2015Plus.json', 'famousSongsChart2015Plus.json']
  .flatMap(file => JSON.parse(readFileSync(new URL(`./corpus/${file}`, import.meta.url), 'utf8')));
const PORT = Number(process.env.PORT ?? 3000);
const MAX_BODY = 256_000;
const GRACE = 5 * 60_000;
const STREAM_HEARTBEAT_MS = 15_000;
const MAX_LIVE_CONNECTIONS = 2_000; // 500 rooms x 4 players; one connection per player.
const streams = new Map();
const sockets = new Map();
const roomTimers = new Map();
const socketServer = new WebSocketServer({ noServer: true, perMessageDeflate: false, maxPayload: 8_192, clientTracking: false });
const socketActions = new Set(['assets-ready', 'assets-unready', 'ready', 'start', 'push', 'choose', 'skip', 'next', 'transfer']);
const forbidden = new Set([...'っゃゅょぁぃぅぇぉゎッャュョァィゥェォヮー']);
const pools = [
  [...'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん'],
  [...'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン'],
  [...'愛光音海風春夏秋冬君夢星夜花青空雨雪月道心時人世界日明白山川新未来恋歌声虹'],
  [...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'], [...'0123456789']
];
const visualGroups = [
  '日目白田','未末朱本','大犬太天','土士王工','人入八','青清晴静','花華芽草','歌唄謡語','空突穹室','夜液衣夢',
  '木本末未','口日目四','山出岳岩','川州順','水永氷泉','火灯炎災','金針銀鉄','月用明朋','雨雪雲雷','心必思忘',
  '春奏泰','夏復憂','秋愁愈','冬寒終','朝潮嘲','風鳳凰','海毎梅','光先元','星屋室','恋変愛',
  '道導首','音暗韻','声聖聞','新親薪','時待持','間問門','夢薫募','愛受優','君群郡','花化華',
  '高髙亮','島鳥嶋','楽薬栗','白自百','赤赦赫','青責清','黒墨黙','深探採','遠運達','近折所',
  '笑咲啖','泣涙流','走起赴','飛非悲','舞無夢','知和矢','手毛才','足是定','目貝見','耳取聞',
  '思恩忠','空室窓','石右岩','林森木','糸系紫','魚漁鮮','言計詩','女好妥','子字学','力刀功',
  '夜液掖','友反双','雪雲雷','花草葉','地池他','声唄歌','虹紅江','春椿秋','時詩持','道運遠'
];
const similar = {};
for (const group of visualGroups) for (const char of group) {
  similar[char] ||= [];
  similar[char].push(...[...group].filter(other => other !== char));
}

export function normalize(title) {
  return String(title).replace(/\([^)]*\)|（[^）]*）/g, '')
    .replace(/\s+(?:feat\.?|featuring)\s+.*$/i, '')
    .replace(/\s+-\s+.*$/, '')
    .normalize('NFKC').toUpperCase()
    .replace(/[^0-9A-Z\u3040-\u30ff\u3400-\u9fff\u3005\u3006]/g, '');
}
function kind(char) {
  const n = char.codePointAt(0);
  if (n >= 0x3040 && n <= 0x309f) return 0;
  if (n >= 0x30a0 && n <= 0x30ff) return 1;
  if (n >= 0x3400 && n <= 0x9fff || n === 0x3005 || n === 0x3006) return 2;
  if (n >= 65 && n <= 90) return 3;
  return 4;
}
function shuffled(array) {
  const copy = [...array];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = randomInt(i + 1); [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}
export function choices(answer, prefix, titles, artistTopTitles = []) {
  const type = kind(answer);
  const chars = titles.map(normalize).map(title => [...title]);
  const preferred = [];
  if (!prefix) for (const char of shuffled(artistTopTitles.slice(0, 7).map(title => [...normalize(title)][0]))) {
    if (char && char !== answer && !forbidden.has(char) && !preferred.includes(char)) preferred.push(char);
    if (preferred.length === 3) break;
  }
  const candidates = prefix ? [ ...(similar[answer] || []),
    ...chars.filter(c => c.join('').startsWith(prefix) && c.length > [...prefix].length).map(c => c[[...prefix].length]),
    ...chars.flatMap(c => c.slice(1).filter((_, i) => c[i] === [...prefix].at(-1)))
  ] : chars.map(c => c[0]);
  if (type === 2) candidates.push(...shuffled([...Array(1200)].map((_, index) => String.fromCodePoint(0x4e00 + index))));
  candidates.push(...shuffled(pools[type]));
  const fallback = [...new Set(candidates)].filter(c => c && c !== answer && kind(c) === type && !forbidden.has(c) && !preferred.includes(c));
  return shuffled([answer, ...[...preferred, ...fallback].slice(0, 3)]);
}
function clamp(value, min, max, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.max(min, Math.min(max, Math.round(number))) : fallback;
}
function settings(input = {}) {
  return {
    questionCount: clamp(input.questionCount, 1, 50, 10), answerSlots: clamp(input.answerSlots, 1, 4, 2),
    targetScore: clamp(input.targetScore, 0, 500, 50), correctPoints: clamp(input.correctPoints, 1, 50, 10),
    firstBonus: clamp(input.firstBonus, 0, 50, 10), wrongPenalty: clamp(input.wrongPenalty, 0, 50, 10),
    firstWrongPenalty: clamp(input.firstWrongPenalty, 0, 50, 10), lives: clamp(input.lives, 0, 10, 3),
    endless: Boolean(input.endless)
  };
}
function catalogSongs(origin) {
  return catalog.filter(song => typeof song.title === 'string' && normalize(song.title)
    && /^[A-Za-z0-9_-]+\.wav$/.test(song.audioFile))
    .map(({ audioFile, ...song }) => ({ ...song, artworkURL: song.artworkURL || null,
      previewURL: `${origin.replace(/\/$/, '')}/media/${encodeURIComponent(audioFile)}`,
      trackURL: song.trackURL || null }));
}
function artistTopTitles(value) {
  return Array.isArray(value) ? value.filter(t => typeof t === 'string' && normalize(t)).slice(0, 7).map(t => t.slice(0, 150)) : [];
}
function publicPlayer(player, room) {
  const attempt = room.answers.find(answer => answer.playerId === player.id);
  const push = room.pushAttempts.find(item => item.playerId === player.id);
  return { id: player.id, name: player.name, score: player.score, lives: player.lives,
    correctCount: player.correctCount ?? 0, wrongCount: player.wrongCount ?? 0,
    roundResults: player.roundResults || [],
    currentResult: ['correct', 'wrong'].includes(attempt?.status) ? attempt.status :
      player.roundResults?.[room.round] ?? null,
    pushTimeMS: attempt?.pushTimeMS ?? push?.pushTimeMS ?? null,
    disqualified: player.disqualified, connected: Date.now() - player.lastSeen < GRACE,
    isHost: player.id === room.hostId, joinedAt: player.joinedAt, badge: player.badge || null };
}
function currentSong(room) { return room.songs[room.round]; }
function reveal(room) {
  if (room.phase === 'reveal') return;
  const correct = new Set(room.correctPlayerIDs);
  room.correctPlayerIDs = [...room.pushed].filter(id => correct.has(id));
  room.correctPlayerID = room.correctPlayerIDs[0] ?? null;
  for (const player of room.players) {
    player.roundResults ||= [];
    player.roundResults[room.round] = correct.has(player.id) ? 'correct' :
      room.answers.some(answer => answer.playerId === player.id && answer.status === 'wrong') ? 'wrong' : null;
  }
  room.correctPlayerIDs.forEach((id, index) => {
    const player = room.players.find(item => item.id === id);
    if (player) {
      player.score += room.settings.correctPoints + (index === 0 ? room.settings.firstBonus : 0);
      player.correctCount = (player.correctCount ?? 0) + 1;
    }
  });
  room.pushClosed = true;
  room.phase = 'reveal'; room.pausedAt = null; room.pausedPositionMS = null;
  room.revealAt = Date.now();
}
function settleNormal(room, now = Date.now()) {
  if (now >= room.roundDeadline) {
    room.pushClosed = true;
    room.audioStoppedAt ??= now;
  }
  const eligible = room.players.some(player => !player.disqualified && !room.pushed.has(player.id) && now - player.lastSeen < GRACE);
  if (room.pushed.size >= room.settings.answerSlots || !eligible) room.pushClosed = true;
  const active = room.answers.some(answer => answer.status === 'active');
  if (room.pushClosed && !active) reveal(room);
  else room.phase = active ? 'answering' : 'listening';
}
function allEligiblePlayersSkipped(room, now = Date.now()) {
  return room.players.filter(player => !player.disqualified && now - player.lastSeen < GRACE &&
    !room.answers.some(answer => answer.playerId === player.id && answer.status === 'wrong'))
    .every(player => room.skipped.has(player.id));
}
function beginRound(room) {
  if (room.round + 1 >= room.songs.length || room.settings.targetScore > 0 && room.players.some(p => p.score >= room.settings.targetScore) || room.players.every(p => p.disqualified)) {
    room.phase = 'finished'; return;
  }
  room.round++;
  room.phase = 'preparing';
  room.prepareAt = Date.now();
  room.readyIds = new Set();
  room.startAt = null;
  room.roundDeadline = null;
  room.answers = [];
  room.pausedAt = null;
  room.pausedPositionMS = null;
  room.pushClosed = false;
  room.audioStoppedAt = null;
  room.pushed = new Set();
  room.pushAttempts = [];
  room.skipped = new Set();
  room.correctPlayerID = null;
  room.correctPlayerIDs = [];
  room.firstWrongDone = false;
}
function wrong(room, player, answer) {
  const s = room.settings;
  player.score = Math.max(0, player.score - s.wrongPenalty - (room.firstWrongDone ? 0 : s.firstWrongPenalty));
  player.wrongCount = (player.wrongCount ?? 0) + 1;
  room.firstWrongDone = true;
  if (s.lives > 0) {
    player.lives = Math.max(0, player.lives - 1);
    player.disqualified = player.lives === 0;
  }
  answer.status = 'wrong';
  answer.options = [];
  if (s.endless && room.pausedAt != null) {
    const pausedMS = Date.now() - room.pausedAt;
    room.startAt += pausedMS;
    room.roundDeadline += pausedMS;
    room.pausedAt = null;
    room.pausedPositionMS = null;
  }
  if (!s.endless) {
    if (allEligiblePlayersSkipped(room)) room.pushClosed = true;
    settleNormal(room);
    return;
  }
  if (allEligiblePlayersSkipped(room)) { reveal(room); return; }
  const active = room.answers.some(item => item.status === 'active');
  const eligible = room.players.some(p => !p.disqualified && !room.pushed.has(p.id) && Date.now() - p.lastSeen < GRACE);
  if (!active && (!eligible || Date.now() >= room.roundDeadline)) reveal(room);
  else room.phase = active ? 'answering' : 'listening';
}
function refresh(room) {
  const now = Date.now();
  room.players = room.players.filter(p => p.id === room.hostId || now - p.lastSeen < GRACE);
  const host = room.players.find(p => p.id === room.hostId);
  if (!host || now - host.lastSeen >= GRACE) {
    const next = room.players.filter(p => now - p.lastSeen < GRACE).sort((a,b) => a.joinedAt - b.joinedAt)[0];
    if (next) room.hostId = next.id;
  }
  if (room.phase === 'preparing') {
    const active = room.players.filter(p => now - p.lastSeen < GRACE);
    if (active.length && active.every(p => room.readyIds.has(p.id))) {
      room.phase = 'countdown'; room.startAt = now + 5000; room.roundDeadline = room.startAt + 30_000;
    }
  }
  if (room.phase === 'countdown' && now >= room.startAt) room.phase = 'listening';
  if (['listening', 'answering'].includes(room.phase)) {
    if (room.settings.endless) {
      if (room.pausedAt == null && now >= room.roundDeadline) reveal(room);
    } else settleNormal(room, now);
  }
  if (room.phase === 'answering') {
    for (const answer of room.answers.filter(item => item.status === 'active' && now >= item.deadline)) {
      const player = room.players.find(p => p.id === answer.playerId);
      if (player) wrong(room, player, answer);
      else {
        answer.status = 'wrong';
        if (room.settings.endless) reveal(room);
        else settleNormal(room, now);
      }
    }
  }
}
function snapshot(room, playerId) {
  refresh(room);
  room.snapshotSequence = (room.snapshotSequence || 0) + 1;
  const song = room.round >= 0 ? currentSong(room) : null;
  const disclosed = room.phase === 'reveal' || room.phase === 'finished';
  const ownAttempt = room.answers.find(answer => answer.playerId === playerId);
  const ownAnswer = ownAttempt?.status === 'active' ? ownAttempt : null;
  const watching = room.settings.endless || room.pushClosed ||
    room.pushed.has(playerId) || room.players.find(player => player.id === playerId)?.disqualified;
  return {
    id: room.id, mode: room.mode, hostId: room.hostId, phase: room.phase, round: room.round,
    sequence: room.snapshotSequence,
    totalRounds: room.songs.length,
    settings: room.settings, players: room.players.map(p => publicPlayer(p, room)),
    serverNow: Date.now(), startAt: room.startAt, roundDeadline: room.roundDeadline,
    pausedAt: room.pausedAt, pausedPositionMS: room.pausedPositionMS,
    pushClosed: room.pushClosed, audioStoppedAt: room.audioStoppedAt,
    answerDeadline: ownAnswer?.deadline ?? null,
    answerProgress: ownAnswer?.progress ?? '', answerStatus: ownAttempt?.status ?? null,
    options: ownAnswer?.options ?? [],
    activeAnswers: room.answers.filter(answer => answer.status === 'active').map(answer => ({
      playerId: answer.playerId, progress: watching ? answer.progress : '' })),
    pushedIds: [...room.pushed], skippedIds: [...room.skipped], readyIds: [...room.readyIds],
    pushOrderIds: room.pushAttempts.map(attempt => attempt.playerId),
    assetsReadyIds: [...(room.assetsReadyIds || [])],
    preload: room.phase === 'lobby' ? room.songs.map(({ id, artworkURL, previewURL }) => ({ id, artworkURL, previewURL })) : [],
    correctPlayerID: disclosed ? room.correctPlayerID : null,
    correctPlayerIDs: disclosed ? room.correctPlayerIDs : [],
    current: song ? {
      id: song.id, previewURL: song.previewURL,
      ...(disclosed ? { title: song.title, artist: song.artist, artworkURL: song.artworkURL,
        trackURL: song.trackURL, durationMS: song.durationMS, genre: song.genre,
        songleURL: song.songleURL || null, chorusMS: song.chorusMS ?? null } : {})
    } : null
  };
}
function fail(status, message) { return { status, body: { error: message } }; }
export function handle(method, path, body, query, authorization, origin = 'https://example.com') {
  if (method === 'GET' && path === '/health') return { status: 200, body: { ok: true } };
  if (method === 'POST' && path === '/profile') {
    const id = String(body.id || '');
    if (!/^[A-Za-z0-9-]{1,64}$/.test(id)) return fail(400, 'プロフィールIDが無効です');
    if (profiles.has(id)) return fail(409, '既存プロフィールです');
    const profile = { id, secret: randomUUID(), reviews: [], history: [], stats: null };
    profiles.set(id, profile);
    return { status: 201, body: { ...profile, token: profile.secret, secret: undefined } };
  }
  if ((method === 'GET' || method === 'PUT') && path === '/profile') {
    const id = String(method === 'GET' ? query.get('id') || '' : body.id || '');
    const profile = profiles.get(id);
    if (!profile || authorization?.replace(/^Bearer /, '') !== profile.secret) return fail(403, 'プロフィールを確認できません');
    if (method === 'PUT') {
      if (Array.isArray(body.history)) profile.history = body.history.slice(0, 5);
      if (Array.isArray(body.reviews)) {
        const items = body.reviews.filter(item => item && typeof item === 'object' && item.song?.id)
          .sort((a, b) => Number(b.savedAt || 0) - Number(a.savedAt || 0));
        profile.reviews = [...items.filter(item => !item.learned).slice(0, 50),
          ...items.filter(item => item.learned).slice(0, 50)];
      }
      if (body.stats && typeof body.stats === 'object') profile.stats = body.stats;
    }
    const { secret, ...safe } = profile;
    return { status: 200, body: safe };
  }
  if (method === 'GET' && path === '/catalog') {
    return { status: 200, body: { songs: catalogSongs(origin) } };
  }
  if (method === 'POST' && path === '/rooms') {
    if (rooms.size >= 500) return fail(503, 'ルーム数の上限に達しました');
    const mode = ['shared', 'spotify', 'applemusic', 'sabitro'].includes(body.mode) ? body.mode : 'shared';
    const supplied = Array.isArray(body.songs) ? body.songs.slice(0, 50).filter(song =>
      song && typeof song.title === 'string' && normalize(song.title) && typeof song.artist === 'string' &&
      ((mode === 'spotify' && /^spotify:[A-Za-z0-9]{22}$/.test(song.id)) ||
       (mode === 'applemusic' && /^applemusic:\d+$/.test(song.id)) ||
       (mode === 'sabitro' && /^itunes:\d+$/.test(song.id) && /^https:\/\//.test(song.previewURL || ''))))
      .map(song => ({ id: song.id, title: song.title.slice(0, 150), artist: song.artist.slice(0, 100),
        artistTopTitles: artistTopTitles(song.artistTopTitles),
        artworkURL: song.artworkURL || null, previewURL: mode === 'spotify' || mode === 'applemusic' ? null : song.previewURL,
        trackURL: song.trackURL || null, durationMS: Number(song.durationMS) || 180_000,
        genre: song.genre || 'その他', songleURL: song.songleURL || null, chorusMS: song.chorusMS || null })) : [];
    const suppliedTopTitles = new Map((Array.isArray(body.songs) ? body.songs : [])
      .filter(song => song && typeof song.id === 'string').map(song => [song.id, artistTopTitles(song.artistTopTitles)]));
    const songs = mode === 'shared' ? catalogSongs(origin).map(song => ({ ...song,
      artistTopTitles: suppliedTopTitles.get(song.id) || [] })) : supplied;
    if (!songs.length) return fail(400, '再生できる曲がありません');
    if (!/^[A-Za-z0-9-]{1,64}$/.test(String(body.playerId || '')) || !String(body.name || '').trim()) return fail(400, 'プレイヤー情報が必要です');
    let id; do { id = Array.from({length: 6}, () => 'ABCDEFGHJKLMNPQRSTUVWXYZ'[randomInt(24)]).join(''); } while (rooms.has(id));
    const s = settings(body.settings);
    if (songs.length < s.questionCount) return fail(400, `問題数分の曲がありません（利用可能: ${songs.length}曲）`);
    const room = { id, mode, settings: s, songs: shuffled(songs).slice(0, s.questionCount), corpus: [...new Set([...songs.map(song => song.title), ...seedTitles, ...(Array.isArray(body.corpus) ? body.corpus.filter(s => typeof s === 'string').slice(0, 500) : [])])], phase: 'lobby', round: -1,
      hostId: String(body.playerId), players: [{ id: String(body.playerId), secret: randomUUID(), name: String(body.name).trim().slice(0, 24),
        badge: String(body.badge || '').slice(0, 24), score: 0, correctCount: 0, wrongCount: 0,
        roundResults: [], lives: s.lives, disqualified: false, joinedAt: Date.now(), lastSeen: Date.now() }],
      pushed: new Set(), pushAttempts: [], skipped: new Set(), readyIds: new Set(), assetsReadyIds: new Set(), startAt: null, roundDeadline: null,
      pausedAt: null, pausedPositionMS: null, pushClosed: false, audioStoppedAt: null,
      answers: [], correctPlayerID: null, correctPlayerIDs: [], firstWrongDone: false };
    rooms.set(id, room);
    return { status: 201, body: { ...snapshot(room, String(body.playerId)), sessionToken: room.players[0].secret } };
  }
  const match = path.match(/^\/rooms\/([A-Z]{6})(?:\/(join|heartbeat|assets-ready|assets-unready|ready|start|push|choose|skip|next|leave|transfer))?$/);
  if (!match) return fail(404, '見つかりません');
  const room = rooms.get(match[1]); if (!room) return fail(404, 'ルームが見つかりません');
  refresh(room);
  const action = match[2];
  const playerId = String(method === 'GET' ? query.get('playerId') || '' : body.playerId || '');
  let player = room.players.find(p => p.id === playerId);
  let newlyJoined = false;
  if (action === 'join' && method === 'POST') {
    if (!player) {
      if (room.phase !== 'lobby') return fail(409, '開始後は参加できません');
      if (room.players.length >= 4) return fail(409, '満員です');
      if (!/^[A-Za-z0-9-]{1,64}$/.test(playerId)) return fail(400, 'プレイヤー情報が無効です');
      player = { id: playerId, secret: randomUUID(), name: String(body.name || 'プレイヤー').trim().slice(0, 24),
        badge: String(body.badge || '').slice(0, 24), score: 0, correctCount: 0, wrongCount: 0,
        roundResults: [], lives: room.settings.lives, disqualified: false, joinedAt: Date.now(), lastSeen: Date.now() };
      room.players.push(player);
      newlyJoined = true;
    }
  }
  if (!player) return fail(403, '参加していません');
  if (!newlyJoined && player.secret !== authorization?.replace(/^Bearer /, '')) return fail(403, 'セッションを確認できません');
  player.lastSeen = Date.now();
  if (action === 'start') {
    if (room.hostId !== playerId || room.phase !== 'lobby') return fail(403, 'ホストのみ開始できます');
    if (room.players.some(p => !room.assetsReadyIds?.has(p.id))) return fail(409, '全員の画像と音源の準備が終わるまでお待ちください');
    beginRound(room);
  } else if (action === 'assets-ready') {
    if (room.phase !== 'lobby') return fail(409, '開始前ではありません');
    room.assetsReadyIds ||= new Set();
    room.assetsReadyIds.add(playerId);
  } else if (action === 'assets-unready') {
    if (room.phase !== 'lobby') return fail(409, '開始前ではありません');
    room.assetsReadyIds?.delete(playerId);
  } else if (action === 'ready') {
    if (room.phase !== 'preparing') return fail(409, '準備中ではありません');
    room.readyIds.add(playerId);
  } else if (action === 'transfer') {
    const target = room.players.find(p => p.id === body.targetId);
    if (room.phase !== 'lobby' || room.hostId !== playerId || !target) return fail(403, 'ホスト変更は待機中のホストのみ行えます');
    room.hostId = target.id;
  } else if (action === 'push') {
    if (!['listening', 'answering'].includes(room.phase) || player.disqualified) {
      return { status: 409, body: { error: '解答権を取得できません', state: snapshot(room, playerId) } };
    }
    const pushedAt = Date.now();
    const pushTimeMS = Math.max(0, Math.min(30_000, pushedAt - room.startAt));
    if (!room.pushAttempts.some(attempt => attempt.playerId === playerId)) {
      room.pushAttempts.push({ playerId, pushTimeMS });
    }
    if (room.pushed.has(playerId) ||
        room.settings.endless && room.phase === 'answering' ||
        !room.settings.endless && room.pushClosed) {
      return { status: 409, body: { error: '解答権を取得できません', state: snapshot(room, playerId) } };
    }
    room.pushed.add(playerId); room.skipped.delete(playerId);
    room.answers.push({ playerId, progress: '', letterIndex: 0, deadline: pushedAt + 5000,
      pushTimeMS,
      options: choices([...normalize(currentSong(room).title)][0], '', room.corpus || room.songs.map(s => s.title), currentSong(room).artistTopTitles || []),
      status: 'active' });
    if (room.settings.endless) {
      room.pausedAt = Date.now();
      room.pausedPositionMS = Math.max(0, room.pausedAt - room.startAt);
    }
    room.phase = 'answering';
    if (!room.settings.endless) settleNormal(room);
  } else if (action === 'choose') {
    const attempt = room.answers.find(answer => answer.playerId === playerId && answer.status === 'active');
    if (room.phase !== 'answering' || !attempt) return fail(409, '解答権がありません');
    if (Date.now() >= attempt.deadline) wrong(room, player, attempt);
    else {
      const answer = [...normalize(currentSong(room).title)];
      if (String(body.choice) !== answer[attempt.letterIndex]) wrong(room, player, attempt);
      else {
        attempt.progress += answer[attempt.letterIndex]; attempt.letterIndex++;
        if (attempt.letterIndex === answer.length) {
          attempt.status = 'correct';
          attempt.options = [];
          room.correctPlayerIDs.push(playerId);
          if (room.settings.endless) reveal(room);
          else settleNormal(room);
        } else {
          attempt.options = choices(answer[attempt.letterIndex], attempt.progress, room.corpus || room.songs.map(s => s.title));
          attempt.deadline = Date.now() + 5000;
        }
      }
    }
  } else if (action === 'skip') {
    if (!['listening','answering'].includes(room.phase) || player.disqualified) return fail(409, '今はスキップできません');
    room.skipped.add(playerId);
    if (allEligiblePlayersSkipped(room)) {
      if (room.settings.endless) reveal(room);
      else { room.pushClosed = true; settleNormal(room); }
    }
  } else if (action === 'next') {
    if (room.hostId !== playerId || room.phase !== 'reveal') return fail(403, 'ホストのみ進められます');
    beginRound(room);
  } else if (action === 'leave') {
    const attempt = room.answers.find(answer => answer.playerId === playerId && answer.status === 'active');
    room.players = room.players.filter(p => p.id !== playerId);
    if (!room.players.length) rooms.delete(room.id);
    else {
      if (room.hostId === playerId) room.hostId = room.players.sort((a,b) => a.joinedAt - b.joinedAt)[0].id;
      if (attempt) wrong(room, player, attempt);
    }
    return { status: 200, body: { left: true } };
  } else if (action && action !== 'join' && action !== 'heartbeat') return fail(404, '見つかりません');
  return { status: 200, body: { ...snapshot(room, playerId), ...(action === 'join' ? { sessionToken: player.secret } : {}) } };
}
function send(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(body));
}

function roomSignature(room) {
  return JSON.stringify({
    phase: room.phase, round: room.round, hostId: room.hostId,
    players: room.players.map(({ id, score, lives, disqualified, correctCount, wrongCount, roundResults }) =>
      [id, score, lives, disqualified, correctCount, wrongCount, roundResults]),
    ready: [...room.readyIds], assetsReady: [...room.assetsReadyIds],
    pushed: [...room.pushed], pushAttempts: room.pushAttempts, skipped: [...room.skipped],
    answers: room.answers.map(({ playerId, progress, deadline, options, status }) =>
      [playerId, progress, deadline, options, status]),
    correct: room.correctPlayerIDs, startAt: room.startAt, roundDeadline: room.roundDeadline,
    pausedAt: room.pausedAt, pausedPositionMS: room.pausedPositionMS,
    pushClosed: room.pushClosed, audioStoppedAt: room.audioStoppedAt
  });
}

function waitForDrain(response) {
  response.backpressureAt = Date.now();
  response.once('drain', () => {
    response.backpressureAt = null;
    const pending = response.pendingState;
    response.pendingState = null;
    if (pending) writeEvent(response, pending);
  });
}

function writeEvent(response, state) {
  if (response.destroyed || response.writableEnded) return;
  if (response.writableNeedDrain) {
    response.pendingState = state; // Keep only the newest state for a slow connection.
    if (response.writableLength > 256_000) response.end();
    return;
  }
  if (!response.write(`data: ${JSON.stringify(state)}\n\n`)) waitForDrain(response);
}

function liveConnectionCount() {
  let count = 0;
  for (const clients of streams.values()) count += clients.size;
  for (const clients of sockets.values()) count += clients.size;
  return count;
}

function sendSocket(socket, message) {
  if (socket.readyState !== WebSocket.OPEN) return;
  if (socket.bufferedAmount > 256_000) { socket.terminate(); return; }
  socket.send(JSON.stringify(message));
}

function publishRoom(room, exceptPlayerId = null) {
  refresh(room);
  for (const [playerId, response] of streams.get(room.id) || []) {
    if (!room.players.some(player => player.id === playerId)) { response.end(); continue; }
    if (playerId === exceptPlayerId) continue;
    writeEvent(response, snapshot(room, playerId));
  }
  for (const [playerId, socket] of sockets.get(room.id) || []) {
    if (!room.players.some(player => player.id === playerId)) { socket.close(1000); continue; }
    if (playerId === exceptPlayerId) continue;
    sendSocket(socket, { type: 'state', state: snapshot(room, playerId) });
  }
}

function scheduleRoom(room) {
  clearTimeout(roomTimers.get(room.id));
  roomTimers.delete(room.id);
  if (rooms.get(room.id) !== room) return;
  const deadlines = [];
  if (room.phase === 'countdown') deadlines.push(room.startAt);
  if (['listening', 'answering'].includes(room.phase)) {
    if (!room.settings.endless || room.pausedAt == null) deadlines.push(room.roundDeadline);
    deadlines.push(...room.answers.filter(answer => answer.status === 'active').map(answer => answer.deadline));
  }
  const next = deadlines.filter(value => Number.isFinite(value) && value > Date.now()).sort((a, b) => a - b)[0];
  if (next == null) return;
  const timer = setTimeout(() => {
    roomTimers.delete(room.id);
    if (rooms.get(room.id) !== room) return;
    const before = roomSignature(room);
    refresh(room);
    if (roomSignature(room) !== before) { publishRoom(room); persist(); }
    scheduleRoom(room);
  }, Math.max(1, next - Date.now()));
  timer.unref();
  roomTimers.set(room.id, timer);
}

function closeRoomStreams(id) {
  clearTimeout(roomTimers.get(id));
  roomTimers.delete(id);
  for (const response of streams.get(id)?.values() || []) response.end();
  streams.delete(id);
  for (const socket of sockets.get(id)?.values() || []) socket.close(1000);
  sockets.delete(id);
}

function enrichSpotifyChorus(id) {
  const room = rooms.get(id);
  const song = room && currentSong(room);
  if (room?.mode === 'spotify' && song) {
    chorusPosition(song).then(position => { song.chorusMS = position; persist(); }).catch(() => {});
  }
}

export const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://localhost');
  if (request.method === 'GET' && url.pathname === '/spotify/callback') {
    const deepLink = new URL('intol://callback');
    for (const key of ['code', 'state', 'error']) if (url.searchParams.has(key)) deepLink.searchParams.set(key, url.searchParams.get(key));
    response.writeHead(302, { Location: deepLink.toString(), 'Cache-Control': 'no-store' }); response.end(); return;
  }
  if (!['GET', 'POST', 'PUT'].includes(request.method)) { send(response, 405, { error: 'Method not allowed' }); return; }
  const eventRoom = request.method === 'GET' && /^\/rooms\/([A-Z]{6})\/events$/.exec(url.pathname);
  if (eventRoom) {
    const id = eventRoom[1];
    const result = handle('GET', `/rooms/${id}`, {}, url.searchParams, request.headers.authorization);
    if (result.status !== 200) { send(response, result.status, result.body); return; }
    const room = rooms.get(id);
    const playerId = url.searchParams.get('playerId');
    let clients = streams.get(id);
    if (!clients) { clients = new Map(); streams.set(id, clients); }
    const previous = clients.get(playerId);
    const previousSocket = sockets.get(id)?.get(playerId);
    if (!previous && !previousSocket && liveConnectionCount() >= MAX_LIVE_CONNECTIONS) {
      send(response, 503, { error: '接続数の上限に達しました' }); return;
    }
    response.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      'X-Accel-Buffering': 'no', 'Connection': 'keep-alive'
    });
    response.flushHeaders();
    clients.set(playerId, response);
    previous?.end();
    previousSocket?.close(1000);
    response.on('close', () => {
      if (clients.get(playerId) === response) clients.delete(playerId);
      if (!clients.size) streams.delete(id);
    });
    writeEvent(response, result.body);
    publishRoom(room, playerId);
    scheduleRoom(room);
    return;
  }
  const media = url.pathname.match(/^\/media\/([A-Za-z0-9_-]+\.wav)$/);
  if (request.method === 'GET' && media && catalog.some(song => song.audioFile === media[1])) {
    const path = new URL(`./public/audio/${media[1]}`, import.meta.url);
    try {
      const size = statSync(path).size;
      const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range || '');
      const start = range ? Number(range[1]) : 0;
      const end = range && range[2] ? Math.min(size - 1, Number(range[2])) : size - 1;
      if (start >= size || start > end) {
        response.writeHead(416, { 'Content-Range': `bytes */${size}` }); response.end(); return;
      }
      const headers = {
        'Content-Type': 'audio/wav', 'Content-Length': end - start + 1,
        'Accept-Ranges': 'bytes', 'Cache-Control': 'public, max-age=86400'
      };
      if (range) headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
      response.writeHead(range ? 206 : 200, headers);
      createReadStream(path, { start, end }).pipe(response);
    } catch { send(response, 404, { error: 'Audio not found' }); }
    return;
  }
  try {
    const chunks = [];
    let bytes = 0;
    for await (const chunk of request) {
      bytes += chunk.length;
      if (bytes > MAX_BODY) { send(response, 413, { error: 'Too large' }); return; }
      chunks.push(chunk);
    }
    const input = Buffer.concat(chunks).toString('utf8');
    const body = input ? JSON.parse(input) : {};
    if (request.method === 'GET' && url.pathname === '/itunes/search') {
      send(response, 200, { songs: await searchItunes(url.searchParams.get('term') || '') }); return;
    }
    if (request.method === 'POST' && url.pathname === '/itunes/match') {
      send(response, 200, { song: await matchItunes(body) }); return;
    }
    if (request.method === 'GET' && url.pathname === '/itunes/top') {
      send(response, 200, { titles: await topSongs() }); return;
    }
    if (request.method === 'POST' && url.pathname === '/chorus') {
      send(response, 200, { positionMS: await chorusPosition(body) }); return;
    }
    if (request.method === 'POST' && url.pathname === '/profile/link') {
      const access = request.headers.authorization?.replace(/^Bearer /, '');
      if (!access) { send(response, 401, { error: 'Spotify 認証が必要です' }); return; }
      const verification = await fetch('https://api.spotify.com/v1/me', {
        headers: { Authorization: `Bearer ${access}` }, signal: AbortSignal.timeout(8000)
      });
      if (!verification.ok) { send(response, 403, { error: 'Spotify アカウントを確認できません' }); return; }
      const account = await verification.json();
      const accountID = account.account_id || account.id;
      if (!accountID || !/^[A-Za-z0-9_-]+$/.test(accountID)) { send(response, 403, { error: 'アカウントIDが無効です' }); return; }
      const id = `spotify:${accountID}`;
      let profile = profiles.get(id);
      if (!profile) {
        profile = { id, secret: randomUUID(), reviews: [], history: [], stats: null };
        profiles.set(id, profile); persist();
      }
      const { secret, ...safe } = profile;
      send(response, 200, { ...safe, token: secret }); return;
    }
    const origin = process.env.PUBLIC_BASE_URL || `${request.headers['x-forwarded-proto'] || 'http'}://${request.headers.host}`;
    const roomId = /^\/rooms\/([A-Z]{6})(?:\/|$)/.exec(url.pathname)?.[1];
    const before = roomId && rooms.has(roomId) ? roomSignature(rooms.get(roomId)) : null;
    const result = handle(request.method, url.pathname, body, url.searchParams, request.headers.authorization, origin);
    send(response, result.status, result.body);
    if (roomId) {
      const room = rooms.get(roomId);
      if (!room) closeRoomStreams(roomId);
      else {
        if (roomSignature(room) !== before) publishRoom(room);
        scheduleRoom(room);
      }
    }
    if (result.status === 201 && request.method === 'POST' && url.pathname === '/rooms' && result.body.mode === 'spotify') {
      const room = rooms.get(result.body.id);
      void (async () => {
        for (const song of room.songs) {
          if (rooms.get(room.id) !== room) return;
          try {
            const match = await matchItunes(song);
            if (rooms.get(room.id) === room && match?.genre) { song.genre = match.genre; persist(); }
          } catch { /* Genre enrichment must not block room creation. */ }
        }
      })();
    }
    if (result.status === 200 && request.method === 'POST' && /\/rooms\/[A-Z]{6}\/(start|next)$/.test(url.pathname)) {
      enrichSpotifyChorus(url.pathname.split('/')[2]);
    }
    if (request.method !== 'GET' || url.pathname.startsWith('/rooms/')) persist();
  } catch (error) { send(response, 400, { error: error instanceof Error ? error.message : 'Bad request' }); }
});

server.on('upgrade', (request, socket, head) => {
  let url;
  try { url = new URL(request.url, 'http://localhost'); }
  catch { socket.destroy(); return; }
  const match = /^\/rooms\/([A-Z]{6})\/socket$/.exec(url.pathname);
  if (!match) { socket.destroy(); return; }
  const id = match[1];
  const playerId = url.searchParams.get('playerId');
  const authorization = request.headers.authorization;
  const result = handle('GET', `/rooms/${id}`, {}, url.searchParams, authorization);
  if (result.status !== 200) {
    socket.end(`HTTP/1.1 ${result.status} Forbidden\r\nConnection: close\r\n\r\n`);
    return;
  }
  const previousSocket = sockets.get(id)?.get(playerId);
  const previousStream = streams.get(id)?.get(playerId);
  if (!previousSocket && !previousStream && liveConnectionCount() >= MAX_LIVE_CONNECTIONS) {
    socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');
    return;
  }
  socket.setNoDelay(true);
  socketServer.handleUpgrade(request, socket, head, connection => {
    let clients = sockets.get(id);
    if (!clients) { clients = new Map(); sockets.set(id, clients); }
    clients.set(playerId, connection);
    previousSocket?.close(1000);
    previousStream?.end();
    connection.isAlive = true;
    connection.on('error', () => {});
    connection.on('close', () => {
      if (clients.get(playerId) === connection) clients.delete(playerId);
      if (!clients.size) sockets.delete(id);
    });
    connection.on('pong', () => {
      connection.isAlive = true;
      const player = rooms.get(id)?.players.find(item => item.id === playerId);
      if (player) player.lastSeen = Date.now();
    });
    sendSocket(connection, { type: 'state', state: result.body });
    publishRoom(rooms.get(id), playerId);
    scheduleRoom(rooms.get(id));

    connection.on('message', (raw, isBinary) => {
      if (clients.get(playerId) !== connection) { connection.close(1000); return; }
      if (isBinary) { connection.close(1003); return; }
      let message;
      try { message = JSON.parse(raw.toString()); }
      catch { connection.close(1007); return; }
      if (message?.type !== 'action' || typeof message.id !== 'string' || message.id.length > 64 ||
          !socketActions.has(message.action) || !message.payload ||
          typeof message.payload !== 'object' || Array.isArray(message.payload)) {
        sendSocket(connection, { type: 'error', id: message?.id, status: 400, error: '操作が無効です' });
        return;
      }
      try {
        const room = rooms.get(id);
        if (!room) { connection.close(1000); return; }
        const before = roomSignature(room);
        const answer = handle('POST', `/rooms/${id}/${message.action}`,
          { ...message.payload, playerId }, new URLSearchParams(), authorization);
        if (answer.status === 200) {
          sendSocket(connection, { type: 'result', id: message.id, state: answer.body });
        } else {
          sendSocket(connection, { type: 'error', id: message.id, status: answer.status,
            error: answer.body.error, state: answer.body.state });
        }
        if (rooms.get(id) !== room) { closeRoomStreams(id); return; }
        const changed = roomSignature(room) !== before;
        if (changed) publishRoom(room, answer.status === 200 || answer.body.state ? playerId : null);
        scheduleRoom(room);
        if (answer.status === 200 && ['start', 'next'].includes(message.action)) enrichSpotifyChorus(id);
        if (answer.status === 200 || changed) persist();
      } catch {
        sendSocket(connection, { type: 'error', id: message.id, status: 400, error: '操作に失敗しました' });
      }
    });
  });
});

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  server.listen(PORT, '0.0.0.0', () => console.log(`IntoL room server listening on ${server.address().port}`));
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
    try { saveStateNow(); } catch (error) { console.error('Final state save failed:', error); }
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}

setInterval(() => {
  const now = Date.now();
  for (const [id, clients] of streams) {
    const room = rooms.get(id);
    if (!room) { closeRoomStreams(id); continue; }
    const before = roomSignature(room);
    for (const [playerId, response] of clients) {
      const player = room.players.find(item => item.id === playerId);
      if (!player || response.destroyed || response.writableEnded ||
          response.backpressureAt && now - response.backpressureAt > 30_000) {
        response.end(); continue;
      }
      player.lastSeen = now;
      if (!response.writableNeedDrain && !response.write(': keepalive\n\n')) waitForDrain(response);
    }
    refresh(room);
    if (roomSignature(room) !== before) { publishRoom(room); scheduleRoom(room); persist(); }
  }
  for (const [id, clients] of sockets) {
    const room = rooms.get(id);
    if (!room) { closeRoomStreams(id); continue; }
    const before = roomSignature(room);
    for (const connection of clients.values()) {
      if (connection.readyState !== WebSocket.OPEN || !connection.isAlive) {
        connection.terminate(); continue;
      }
      connection.isAlive = false;
      connection.ping();
    }
    refresh(room);
    if (roomSignature(room) !== before) { publishRoom(room); scheduleRoom(room); persist(); }
  }
}, STREAM_HEARTBEAT_MS).unref();

setInterval(() => {
  const now = Date.now();
  for (const [id, room] of rooms) {
    if (room.players.every(player => now - player.lastSeen >= GRACE)) {
      rooms.delete(id);
      closeRoomStreams(id);
    }
  }
  persist();
}, 60_000).unref();
