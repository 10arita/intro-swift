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
      if (!['shared', 'applemusic', 'sabitro'].includes(room.mode)) continue;
      room.pushed = new Set(room.pushed || []); room.skipped = new Set(room.skipped || []);
      room.settings.handicaps ||= {};
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
      room.playedSongIDs ||= room.songs.slice(0, Math.max(0, room.round + 1)).map(song => song.id);
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
const socketActions = new Set(['assets-ready', 'assets-unready', 'ready', 'start', 'push', 'choose', 'skip', 'next', 'rematch', 'transfer', 'handicaps', 'friend-request', 'invite']);
const forbidden = new Set([...'っゃゅょぁぃぅぇぉゎッャュョァィゥェォヮー']);
const pools = [
  [...'あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん'],
  [...'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン'],
  [...'愛光音海風春夏秋冬君夢星夜花青空雨雪月道心時人世界日明白山川新未来恋歌声虹'],
  [...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'], [...'0123456789']
];
export function normalize(title) {
  return String(title).normalize('NFKC').split(/(?:(?<![A-Za-z])-|-(?![A-Za-z])|\(|[~〜]|(?<![A-Za-z])feat(?![A-Za-z]))/i, 1)[0]
    .toUpperCase().replace(/[^0-9A-Z\u3040-\u30fa\u30fc-\u30ff\u3400-\u9fff\u3005\u3006-]/g, '');
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
function uniqueSongs(songs) {
  return [...new Map(songs.map(song => [song.id, song])).values()];
}
export function choices(answer, prefix, titles, artistTopTitles = [], currentTitle = '') {
  const type = kind(answer);
  const distractors = [];
  const add = candidates => {
    for (const char of candidates) {
      if (char && char !== answer && !forbidden.has(char) && !distractors.includes(char)) distractors.push(char);
      if (distractors.length === 3) break;
    }
  };
  if (!prefix) {
    add(shuffled(artistTopTitles.slice(0, 6).filter(title => normalize(title) !== normalize(currentTitle))
      .map(title => [...normalize(title)][0])));
  } else {
    const chars = titles.map(normalize).map(title => [...title]);
    const used = [...prefix].length;
    add(shuffled(chars.filter(c => c.length > used && c.slice(0, used).join('') === prefix).map(c => c[used])));
    if (distractors.length < 3) {
      const frequency = new Map();
      const prev = [...prefix].at(-1);
      for (const title of chars) for (let i = 0; i < title.length - 1; i++) {
        if (title[i] === prev) frequency.set(title[i + 1], (frequency.get(title[i + 1]) || 0) + 1);
      }
      add(shuffled([...frequency.keys()]).sort((a, b) => frequency.get(b) - frequency.get(a)));
    }
  }
  if (distractors.length < 3) add(shuffled(pools[type]));
  return shuffled([answer, ...distractors]);
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
    endless: Boolean(input.endless), handicaps: {}
  };
}
function catalogSongs(origin) {
  return catalog.filter(song => typeof song.title === 'string' && normalize(song.title)
    && /^[A-Za-z0-9_-]+\.wav$/.test(song.audioFile))
    .map(({ audioFile, ...song }) => ({ ...song, artworkURL: song.artworkURL || null,
      previewURL: `${origin.replace(/\/$/, '')}/media/${encodeURIComponent(audioFile)}`,
      trackURL: song.trackURL || null }));
}
function suppliedSongs(value, mode) {
  return Array.isArray(value) ? value.slice(0, 50).filter(song =>
    song && typeof song.title === 'string' && normalize(song.title) && typeof song.artist === 'string' &&
    ((mode === 'applemusic' && /^applemusic:\d+$/.test(song.id)) ||
     (mode === 'sabitro' && /^itunes:\d+$/.test(song.id) && /^https:\/\//.test(song.previewURL || ''))))
    .map(song => ({ id: song.id, title: song.title.slice(0, 150), artist: song.artist.slice(0, 100),
      artistTopTitles: artistTopTitles(song.artistTopTitles),
      artworkURL: song.artworkURL || null, previewURL: mode === 'applemusic' ? null : song.previewURL,
      trackURL: song.trackURL || null, durationMS: Number(song.durationMS) || 180_000,
      genre: song.genre || 'その他', songleURL: song.songleURL || null,
      chorusMS: Number.isFinite(song.chorusMS) ? song.chorusMS : null })) : [];
}
function artistTopTitles(value) {
  return Array.isArray(value) ? value.filter(t => typeof t === 'string' && normalize(t)).slice(0, 6).map(t => t.slice(0, 150)) : [];
}
function playerAvatar(value) {
  if (typeof value !== 'string' || value.length > 85_336 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return null;
  const bytes = Buffer.from(value, 'base64');
  return bytes.length <= 64_000 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff
    ? value : null;
}
function publicPlayer(player, room, viewer) {
  const attempt = room.answers.find(answer => answer.playerId === player.id);
  const push = room.pushAttempts.find(item => item.playerId === player.id);
  const owner = profiles.get(viewer?.profileId);
  const target = profiles.get(player.profileId);
  const friendStatus = !owner || !target || owner.id === target.id ? null :
    (owner.friends || []).includes(target.id) ? 'friend' :
    (owner.friendRequests || []).some(item => item.fromId === target.id) ? 'incoming' :
    (target.friendRequests || []).some(item => item.fromId === owner.id) ? 'outgoing' : 'available';
  return { id: player.id, name: player.name, score: player.score, lives: player.lives,
    correctCount: player.correctCount ?? 0, wrongCount: player.wrongCount ?? 0,
    roundResults: player.roundResults || [],
    currentResult: ['correct', 'wrong'].includes(attempt?.status) ? attempt.status :
      player.roundResults?.[room.round] ?? null,
    pushTimeMS: attempt?.pushTimeMS ?? push?.pushTimeMS ?? null,
    disqualified: player.disqualified, connected: Date.now() - player.lastSeen < GRACE,
    isHost: player.id === room.hostId, joinedAt: player.joinedAt, badge: player.badge || null,
    avatar: player.avatar || null, friendStatus,
    friendProfileId: friendStatus === 'friend' ? target.id : null };
}
function currentSong(room) { return room.songs[room.round]; }
function profileFrom(id, secret) {
  const profile = profiles.get(String(id || ''));
  return profile && profile.secret === secret ? profile : null;
}
function authorizedProfile(body, authorization) {
  return profileFrom(body.profileId, authorization?.replace(/^Bearer /, ''));
}
function profileIdentity(body) {
  return profileFrom(body.profileId, body.profileToken)?.id || null;
}
function publicFriends(profile) {
  return {
    friends: (profile.friends || []).map(id => profiles.get(id)).filter(Boolean)
      .map(friend => ({ id: friend.id, name: friend.name || friend.id, avatar: friend.avatar || null })),
    requests: (profile.friendRequests || []).filter(item => profiles.has(item.fromId)),
    invites: (profile.invites || []).filter(item => {
      const room = rooms.get(item.roomId);
      return room?.phase === 'lobby' && room.players.some(player => player.profileId === item.fromId);
    }).map(item => ({ ...item, mode: rooms.get(item.roomId).mode })),
    sentInvites: (profile.friends || []).flatMap(targetId =>
      (profiles.get(targetId)?.invites || []).filter(item => {
        const room = rooms.get(item.roomId);
        return item.fromId === profile.id && room?.phase === 'lobby' &&
          room.players.some(player => player.profileId === profile.id);
      }).map(item => ({ roomId: item.roomId, targetId })))
  };
}
function publicAveragePush(stats) {
  if (!Number.isSafeInteger(stats?.attempts) || stats.attempts <= 0) return null;
  const average = Number.isFinite(stats.averagePush) ? stats.averagePush :
    Number.isFinite(stats.totalPushSeconds) ? stats.totalPushSeconds / stats.attempts : NaN;
  return Number.isFinite(average) && average >= 0 && average <= 30 ? average : null;
}
function publicProfile(profile, player = null) {
  const stats = profile?.publicStats ?? profile?.stats;
  return {
    name: player?.name || profile?.name || 'プレイヤー',
    avatar: player?.avatar || profile?.avatar || null,
    badge: player?.badge || stats?.selectedBadge || profile?.badge || null,
    stats: stats && typeof stats === 'object' ? {
      games: Number.isFinite(stats.games) ? stats.games : 0,
      attempts: Number.isFinite(stats.attempts) ? stats.attempts : 0,
      correct: Number.isFinite(stats.correct) ? stats.correct : 0,
      averagePush: publicAveragePush(stats),
      selectedBadge: typeof stats.selectedBadge === 'string' ? stats.selectedBadge : null,
      badges: Array.isArray(stats.badges) ? stats.badges.filter(badge => typeof badge === 'string') : []
    } : null,
    roomScore: player?.score ?? null,
    roomCorrect: player?.correctCount ?? null,
    roomWrong: player?.wrongCount ?? null
  };
}
function addPlayer(room, body, profileId) {
  const player = { id: String(body.playerId), secret: randomUUID(), profileId,
    name: String(body.name || 'プレイヤー').trim().slice(0, 24),
    badge: String(body.badge || '').slice(0, 24), avatar: playerAvatar(body.avatar), score: 0,
    correctCount: 0, wrongCount: 0, roundResults: [], lives: room.settings.lives,
    disqualified: false, joinedAt: Date.now(), lastSeen: Date.now() };
  room.players.push(player);
  if (profileId) {
    const profile = profiles.get(profileId);
    profile.name = player.name;
    profile.avatar = player.avatar;
    profile.badge = player.badge;
  }
  return player;
}
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
  room.correctPlayerIDs.forEach(id => {
    const player = room.players.find(item => item.id === id);
    if (player) {
      player.score += room.settings.correctPoints + (id === room.correctPlayerID ? room.settings.firstBonus : 0);
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
  if (room.pushed.size >= room.settings.answerSlots || !eligible || allEligiblePlayersSkipped(room, now)) room.pushClosed = true;
  const active = room.answers.some(answer => answer.status === 'active');
  if (room.pushClosed && !active) reveal(room);
  else room.phase = active ? 'answering' : 'listening';
}
function allEligiblePlayersSkipped(room, now = Date.now()) {
  return room.players.filter(player => !player.disqualified && now - player.lastSeen < GRACE &&
    !room.answers.some(answer => answer.playerId === player.id && ['correct', 'wrong'].includes(answer.status)))
    .every(player => room.skipped.has(player.id));
}
function beginRound(room) {
  if (room.round + 1 >= room.songs.length || room.settings.targetScore > 0 && room.players.some(p => p.score >= room.settings.targetScore) || room.players.every(p => p.disqualified)) {
    room.phase = 'finished'; return;
  }
  room.round++;
  room.playedSongIDs = [...new Set([...(room.playedSongIDs || []), room.songs[room.round].id])];
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
}
function beginAnswer(room, playerId, pushTimeMS, now = Date.now()) {
  room.pushed.add(playerId);
  room.skipped.delete(playerId);
  room.answers.push({ playerId, progress: '', letterIndex: 0, deadline: now + 5000,
    pushTimeMS, options: choices([...normalize(currentSong(room).title)][0], '',
      room.corpus || room.songs.map(song => song.title), currentSong(room).artistTopTitles || [],
      currentSong(room).title), status: 'active' });
  if (room.settings.endless) {
    room.pausedPositionMS ??= Math.max(0, now - room.startAt);
    room.pausedAt ??= now;
  }
  room.phase = 'answering';
}
function continueEndlessAfterWrong(room, now = Date.now()) {
  const next = room.pushAttempts.find(attempt => !room.pushed.has(attempt.playerId) &&
    !room.skipped.has(attempt.playerId) && room.players.some(player => player.id === attempt.playerId &&
      !player.disqualified && now - player.lastSeen < GRACE));
  if (next) {
    // The song remains paused while queued players answer in PUSH order.
    beginAnswer(room, next.playerId, next.pushTimeMS, now);
    return;
  }
  if (room.pausedAt != null) {
    const pausedMS = now - room.pausedAt;
    room.startAt += pausedMS;
    room.roundDeadline += pausedMS;
    room.pausedAt = null;
    room.pausedPositionMS = null;
  }
  if (allEligiblePlayersSkipped(room) ||
      !room.players.some(player => !player.disqualified && !room.pushed.has(player.id) &&
        now - player.lastSeen < GRACE) || now >= room.roundDeadline) reveal(room);
  else room.phase = 'listening';
}
function wrong(room, player, answer) {
  const s = room.settings;
  const firstPusherID = room.pushed.values().next().value;
  player.score = Math.max(0, player.score - s.wrongPenalty -
    (player.id === firstPusherID ? s.firstWrongPenalty : 0));
  player.wrongCount = (player.wrongCount ?? 0) + 1;
  if (s.lives > 0) {
    player.lives = Math.max(0, player.lives - 1);
    player.disqualified = player.lives === 0;
  }
  answer.status = 'wrong';
  answer.options = [];
  if (!s.endless) {
    if (allEligiblePlayersSkipped(room)) room.pushClosed = true;
    settleNormal(room);
    return;
  }
  continueEndlessAfterWrong(room);
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
      if (allEligiblePlayersSkipped(room, now) || room.pausedAt == null && now >= room.roundDeadline) reveal(room);
    } else settleNormal(room, now);
  }
  if (room.phase === 'answering') {
    for (const answer of room.answers.filter(item => item.status === 'active' && now >= item.deadline)) {
      const player = room.players.find(p => p.id === answer.playerId);
      if (player) wrong(room, player, answer);
      else {
        answer.status = 'wrong';
        if (room.settings.endless) continueEndlessAfterWrong(room, now);
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
    gameNumber: room.gameNumber || 0,
    supportsChoiceRetry: true,
    sequence: room.snapshotSequence,
    totalRounds: room.songs.length,
    settings: room.settings, players: room.players.map(p => publicPlayer(p, room, room.players.find(item => item.id === playerId))),
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
    playedSongIDs: [...(room.playedSongIDs || [])],
    correctPlayerID: disclosed ? room.correctPlayerID : null,
    correctPlayerIDs: disclosed ? room.correctPlayerIDs : [],
    current: song ? {
      id: song.id, previewURL: song.previewURL,
      ...(disclosed ? { title: song.title, artist: song.artist, artworkURL: song.artworkURL,
        trackURL: song.trackURL, durationMS: song.durationMS, genre: song.genre,
        songleURL: song.songleURL || null,
        chorusMS: Number.isFinite(song.chorusMS) ? Math.round(song.chorusMS) : null } : {})
    } : null
  };
}
function fail(status, message) { return { status, body: { error: message } }; }
export function handle(method, path, body, query, authorization, origin = 'https://example.com') {
  if (method === 'GET' && path === '/health') return { status: 200, body: { ok: true } };
  if (method === 'POST' && path === '/profile') {
    const id = String(body.id || '');
    if (!/^[A-Za-z0-9-]{1,64}$/.test(id)) return fail(400, 'プロフィールIDが無効です');
    const registrationToken = body.registrationToken;
    if (registrationToken !== undefined &&
        (typeof registrationToken !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(registrationToken))) {
      return fail(400, '登録情報が無効です');
    }
    const existing = profiles.get(id);
    if (existing) {
      if (!registrationToken || existing.secret !== registrationToken) return fail(409, '既存プロフィールです');
      return { status: 200, body: { ...existing, token: existing.secret, secret: undefined } };
    }
    const profile = { id, secret: registrationToken ?? randomUUID(), reviews: [], history: [], stats: null };
    profiles.set(id, profile);
    return { status: 201, body: { ...profile, token: profile.secret, secret: undefined } };
  }
  if ((method === 'GET' || method === 'PUT') && path === '/profile') {
    const id = String(method === 'GET' ? query.get('id') || '' : body.id || '');
    const profile = profiles.get(id);
    if (!profile || authorization?.replace(/^Bearer /, '') !== profile.secret) return fail(403, 'プロフィールを確認できません');
    if (method === 'PUT') {
      if (typeof body.name === 'string') profile.name = body.name.trim().slice(0, 24) || 'プレイヤー';
      if (typeof body.avatar === 'string') profile.avatar = playerAvatar(body.avatar);
      if (body.publicStats && typeof body.publicStats === 'object') {
        const stats = body.publicStats;
        const count = value => Number.isSafeInteger(value) && value >= 0 ? value : 0;
        profile.publicStats = {
          games: count(stats.games), attempts: count(stats.attempts), correct: count(stats.correct),
          averagePush: publicAveragePush(stats),
          selectedBadge: typeof stats.selectedBadge === 'string' ? stats.selectedBadge.slice(0, 24) : null,
          badges: Array.isArray(stats.badges) ? [...new Set(stats.badges.filter(value => typeof value === 'string')
            .map(value => value.slice(0, 24)))].slice(0, 8) : []
        };
      }
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
  if (method === 'GET' && path === '/player-profile') {
    const room = rooms.get(query.get('roomId'));
    if (room) {
      const viewer = room.players.find(player => player.id === query.get('playerId'));
      if (!viewer || viewer.secret !== authorization?.replace(/^Bearer /, '')) return fail(403, 'セッションを確認できません');
      const target = room.players.find(player => player.id === query.get('targetPlayerId'));
      return target ? { status: 200, body: publicProfile(profiles.get(target.profileId), target) }
        : fail(404, 'プレイヤーが見つかりません');
    }
    const viewer = profileFrom(query.get('profileId'), authorization?.replace(/^Bearer /, ''));
    if (!viewer) return fail(403, 'プロフィールを確認できません');
    const target = profiles.get(query.get('friendId'));
    if (!target || !(viewer.friends || []).includes(target.id) || !(target.friends || []).includes(viewer.id)) {
      return fail(404, 'フレンドが見つかりません');
    }
    return { status: 200, body: publicProfile(target) };
  }
  if (path === '/friends' && method === 'GET') {
    const profile = profileFrom(query.get('profileId'), authorization?.replace(/^Bearer /, ''));
    return profile ? { status: 200, body: publicFriends(profile) } : fail(403, 'プロフィールを確認できません');
  }
  if (path === '/friends/accept' && method === 'POST') {
    const profile = authorizedProfile(body, authorization);
    if (!profile) return fail(403, 'プロフィールを確認できません');
    const request = (profile.friendRequests || []).find(item => item.id === body.requestId);
    const sender = request && profiles.get(request.fromId);
    if (!sender) return fail(404, 'フレンド申請が見つかりません');
    profile.friendRequests = profile.friendRequests.filter(item => item.id !== request.id);
    profile.friends = [...new Set([...(profile.friends || []), sender.id])];
    sender.friends = [...new Set([...(sender.friends || []), profile.id])];
    return { status: 200, body: publicFriends(profile) };
  }
  if (path === '/friends/decline' && method === 'POST') {
    const profile = authorizedProfile(body, authorization);
    if (!profile) return fail(403, 'プロフィールを確認できません');
    profile.friendRequests = (profile.friendRequests || []).filter(item => item.id !== body.requestId);
    return { status: 200, body: publicFriends(profile) };
  }
  if (path === '/friends/invites/join' && method === 'POST') {
    const profile = authorizedProfile(body, authorization);
    if (!profile) return fail(403, 'プロフィールを確認できません');
    const invite = (profile.invites || []).find(item => item.id === body.inviteId);
    const room = invite && rooms.get(invite.roomId);
    if (!room || room.phase !== 'lobby' || !room.players.some(player => player.profileId === invite.fromId))
      return fail(409, '招待されたルームには参加できません');
    if (room.players.length >= 4) return fail(409, '満員です');
    const id = String(body.playerId || '');
    if (!/^[A-Za-z0-9-]{1,64}$/.test(id)) return fail(400, 'プレイヤー情報が無効です');
    if (room.players.some(player => player.id === id)) return fail(409, '既に参加しています');
    const player = addPlayer(room, body, profile.id);
    profile.invites = profile.invites.filter(item => item.id !== invite.id);
    return { status: 200, body: { ...snapshot(room, id), sessionToken: player.secret } };
  }
  if (method === 'GET' && path === '/catalog') {
    return { status: 200, body: { songs: catalogSongs(origin) } };
  }
  if (method === 'POST' && path === '/rooms') {
    if (rooms.size >= 500) return fail(503, 'ルーム数の上限に達しました');
    const mode = body.mode ?? 'shared';
    if (!['shared', 'applemusic', 'sabitro'].includes(mode)) return fail(400, 'この音源モードは利用できません');
    const supplied = suppliedSongs(body.songs, mode);
    const suppliedTopTitles = new Map((Array.isArray(body.songs) ? body.songs : [])
      .filter(song => song && typeof song.id === 'string').map(song => [song.id, artistTopTitles(song.artistTopTitles)]));
    const deferred = body.deferQuestions === true;
    const songs = uniqueSongs(mode === 'shared' ? catalogSongs(origin).map(song => ({ ...song,
      artistTopTitles: suppliedTopTitles.get(song.id) || [] })) : supplied);
    if (!deferred && !songs.length) return fail(400, '再生できる曲がありません');
    if (!/^[A-Za-z0-9-]{1,64}$/.test(String(body.playerId || '')) || !String(body.name || '').trim()) return fail(400, 'プレイヤー情報が必要です');
    let id; do { id = Array.from({length: 6}, () => 'ABCDEFGHJKLMNPQRSTUVWXYZ'[randomInt(24)]).join(''); } while (rooms.has(id));
    const s = settings(deferred ? {} : body.settings);
    if (!deferred && songs.length < s.questionCount) return fail(400, `問題数分の曲がありません（利用可能: ${songs.length}曲）`);
    const room = { id, mode, settings: s, songs: deferred ? [] : shuffled(songs).slice(0, s.questionCount), playedSongIDs: [], corpus: [...new Set([...songs.map(song => song.title), ...seedTitles, ...(Array.isArray(body.corpus) ? body.corpus.filter(s => typeof s === 'string').slice(0, 500) : [])])], phase: 'lobby', round: -1, gameNumber: 0,
      hostId: String(body.playerId), players: [{ id: String(body.playerId), secret: randomUUID(), profileId: profileIdentity(body), name: String(body.name).trim().slice(0, 24),
        badge: String(body.badge || '').slice(0, 24), avatar: playerAvatar(body.avatar), score: 0, correctCount: 0, wrongCount: 0,
        roundResults: [], lives: s.lives, disqualified: false, joinedAt: Date.now(), lastSeen: Date.now() }],
      pushed: new Set(), pushAttempts: [], skipped: new Set(), readyIds: new Set(), assetsReadyIds: new Set(), startAt: null, roundDeadline: null,
      pausedAt: null, pausedPositionMS: null, pushClosed: false, audioStoppedAt: null,
      answers: [], correctPlayerID: null, correctPlayerIDs: [] };
    rooms.set(id, room);
    if (room.players[0].profileId) {
      const profile = profiles.get(room.players[0].profileId);
      profile.name = room.players[0].name;
      profile.avatar = room.players[0].avatar;
      profile.badge = room.players[0].badge;
    }
    return { status: 201, body: { ...snapshot(room, String(body.playerId)), sessionToken: room.players[0].secret } };
  }
  const match = path.match(/^\/rooms\/([A-Z]{6})(?:\/(join|heartbeat|assets-ready|assets-unready|ready|start|push|choose|skip|next|rematch|leave|transfer|handicaps|bind-profile|friend-request|invite))?$/);
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
      player = addPlayer(room, body, profileIdentity(body));
      newlyJoined = true;
    }
  }
  if (!player) return fail(403, '参加していません');
  if (!newlyJoined && player.secret !== authorization?.replace(/^Bearer /, '')) return fail(403, 'セッションを確認できません');
  player.lastSeen = Date.now();
  if (action === 'bind-profile') {
    const profile = profileFrom(body.profileId, body.profileToken);
    if (!profile) return fail(403, 'プロフィールを確認できません');
    player.profileId = profile.id;
    profile.name = player.name;
    profile.avatar = player.avatar;
    profile.badge = player.badge;
  } else if (action === 'friend-request') {
    const sender = profiles.get(player.profileId);
    const targetPlayer = room.players.find(item => item.id === body.targetId);
    const target = profiles.get(targetPlayer?.profileId);
    if (!sender || !target || sender.id === target.id) return fail(400, '申請先を確認できません');
    if ((sender.friends || []).includes(target.id)) return fail(409, '既にフレンドです');
    if ((target.friendRequests || []).some(item => item.fromId === sender.id)) return fail(409, '申請済みです');
    target.friendRequests ||= [];
    target.friendRequests.push({ id: randomUUID(), fromId: sender.id, fromName: player.name,
      roomId: room.id, createdAt: Date.now() });
    target.friendRequests = target.friendRequests.slice(-50);
  } else if (action === 'invite') {
    const sender = profiles.get(player.profileId);
    const target = profiles.get(String(body.targetProfileId || ''));
    if (!sender || !target || !(sender.friends || []).includes(target.id)) return fail(403, 'フレンドのみ招待できます');
    if (room.phase !== 'lobby') return fail(409, 'ルーム作成後、開始前に招待できます');
    if (room.players.length >= 4) return fail(409, '満員です');
    if (room.players.some(item => item.profileId === target.id)) return fail(409, '既に同じルームにいます');
    target.invites ||= [];
    if (target.invites.some(item => item.fromId === sender.id && item.roomId === room.id)) return fail(409, '招待済みです');
    target.invites.push({ id: randomUUID(), fromId: sender.id, fromName: player.name,
      roomId: room.id, createdAt: Date.now() });
    target.invites = target.invites.slice(-50);
  } else if (action === 'start') {
    if (room.hostId !== playerId || room.phase !== 'lobby') return fail(403, 'ホストのみ開始できます');
    if (room.songs.length > 0 && room.players.some(p => !room.assetsReadyIds?.has(p.id))) {
      return fail(409, '全員の画像と音源の準備が終わるまでお待ちください');
    }
    if (room.songs.length === 0) {
      const nextSettings = settings(body.settings);
      const candidates = uniqueSongs(room.mode === 'shared' ? catalogSongs(origin) : suppliedSongs(body.songs, room.mode));
      if (candidates.length < nextSettings.questionCount) return fail(409, `問題数分の曲がありません（利用可能: ${candidates.length}曲）`);
      const played = new Set(room.playedSongIDs || []);
      const fresh = shuffled(candidates.filter(song => !played.has(song.id)));
      room.songs = [...fresh, ...shuffled(candidates.filter(song => played.has(song.id)))].slice(0, nextSettings.questionCount);
      room.settings = { ...nextSettings, handicaps: room.settings.handicaps || {} };
      for (const participant of room.players) {
        participant.lives = nextSettings.lives;
        participant.disqualified = false;
      }
      room.corpus = [...new Set([...candidates.map(song => song.title), ...seedTitles,
        ...(Array.isArray(body.corpus) ? body.corpus.filter(value => typeof value === 'string').slice(0, 500) : [])])];
    }
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
  } else if (action === 'handicaps') {
    if (room.phase !== 'lobby' || room.hostId !== playerId) return fail(403, '待機中のホストのみハンデを設定できます');
    const values = body.handicaps;
    if (!values || typeof values !== 'object' || Array.isArray(values) ||
        Object.entries(values).some(([id, seconds]) =>
          !room.players.some(item => item.id === id) || !Number.isInteger(seconds) || seconds < 0 || seconds > 30)) {
      return fail(400, 'ハンデの対象または秒数が無効です');
    }
    room.settings.handicaps = Object.fromEntries(Object.entries(values).filter(([, seconds]) => seconds > 0));
  } else if (action === 'push') {
    if (!['listening', 'answering'].includes(room.phase) || player.disqualified) {
      return { status: 409, body: { error: '解答権を取得できません', state: snapshot(room, playerId) } };
    }
    const pushedAt = Date.now();
    if (pushedAt < room.startAt + (room.settings.handicaps?.[playerId] || 0) * 1000) {
      return { status: 409, body: { error: 'ハンデ時間中は解答できません', state: snapshot(room, playerId) } };
    }
    // Keep each player's first arrival time, including PUSHes queued while playback is paused.
    const pushTimeMS = room.pushAttempts.find(attempt => attempt.playerId === playerId)?.pushTimeMS ??
      Math.max(0, Math.min(30_000, pushedAt - room.startAt));
    if (!room.pushAttempts.some(attempt => attempt.playerId === playerId)) {
      room.pushAttempts.push({ playerId, pushTimeMS });
    }
    if (room.pushed.has(playerId) ||
        room.settings.endless && room.phase === 'answering' ||
        !room.settings.endless && room.pushClosed) {
      return { status: 409, body: { error: '解答権を取得できません', state: snapshot(room, playerId) } };
    }
    beginAnswer(room, playerId, pushTimeMS, pushedAt);
    if (!room.settings.endless) settleNormal(room);
  } else if (action === 'choose') {
    const actionId = body.actionId;
    if (actionId !== undefined && (typeof actionId !== 'string' || !/^[A-Za-z0-9-]{1,64}$/.test(actionId))) {
      return fail(400, '回答IDが無効です');
    }
    if (actionId && (typeof body.choice !== 'string' || body.choice.length > 8)) return fail(400, '選択肢が無効です');
    room.processedChoices ||= [];
    const previous = actionId && room.processedChoices.find(item => item.playerId === playerId && item.actionId === actionId);
    if (previous) {
      if (previous.choice !== body.choice) return fail(400, '回答IDが重複しています');
      return { status: 200, body: snapshot(room, playerId) };
    }
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
    if (actionId) {
      room.processedChoices.push({ playerId, actionId, choice: body.choice });
      if (room.processedChoices.length > 32) room.processedChoices.shift();
    }
  } else if (action === 'skip') {
    if (!['listening','answering'].includes(room.phase) || player.disqualified) return fail(409, '今はスキップできません');
    if (room.answers.some(answer => answer.playerId === playerId && ['correct', 'wrong'].includes(answer.status))) {
      return fail(409, '解答済みのため投票は不要です');
    }
    room.skipped.add(playerId);
    if (allEligiblePlayersSkipped(room)) {
      if (room.settings.endless) reveal(room);
      else { room.pushClosed = true; settleNormal(room); }
    }
  } else if (action === 'next') {
    if (room.hostId !== playerId || room.phase !== 'reveal') return fail(403, 'ホストのみ進められます');
    beginRound(room);
  } else if (action === 'rematch') {
    if (room.hostId !== playerId || room.phase !== 'finished') return fail(403, 'ホストのみ再プレイできます');
    room.songs = [];
    room.corpus = seedTitles;
    room.gameNumber = (room.gameNumber || 0) + 1;
    room.phase = 'lobby'; room.round = -1;
    room.readyIds = new Set(); room.assetsReadyIds = new Set();
    room.pushed = new Set(); room.pushAttempts = []; room.skipped = new Set(); room.answers = [];
    room.startAt = null; room.roundDeadline = null; room.pausedAt = null; room.pausedPositionMS = null;
    room.pushClosed = false; room.audioStoppedAt = null; room.correctPlayerID = null; room.correctPlayerIDs = [];
    room.processedChoices = [];
    for (const participant of room.players) {
      participant.score = 0; participant.correctCount = 0; participant.wrongCount = 0;
      participant.roundResults = []; participant.lives = room.settings.lives; participant.disqualified = false;
    }
  } else if (action === 'leave') {
    const attempt = room.answers.find(answer => answer.playerId === playerId && answer.status === 'active');
    room.players = room.players.filter(p => p.id !== playerId);
    delete room.settings.handicaps?.[playerId];
    if (!room.players.length) rooms.delete(room.id);
    else {
      if (room.hostId === playerId) room.hostId = room.players.sort((a,b) => a.joinedAt - b.joinedAt)[0].id;
      if (attempt) wrong(room, player, attempt);
      refresh(room);
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
    phase: room.phase, round: room.round, hostId: room.hostId, handicaps: room.settings.handicaps,
    friendship: room.players.map(({ profileId }) => [profileId,
      profiles.get(profileId)?.friends, profiles.get(profileId)?.friendRequests?.map(item => item.id)]),
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

function enrichStreamingChorus(id) {
  const room = rooms.get(id);
  const song = room && currentSong(room);
  if (room && room.mode !== 'sabitro' && song && !Number.isFinite(song.chorusMS)) {
    chorusPosition(song).then(position => { song.chorusMS = position; persist(); }).catch(() => {});
  }
}

export const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://localhost');
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
    if (request.method === 'POST' && url.pathname === '/friends/invites/join' && result.status === 200) {
      const room = rooms.get(result.body.id);
      if (room) { publishRoom(room); scheduleRoom(room); }
    }
    if (request.method === 'POST' && url.pathname === '/friends/accept' && result.status === 200) {
      for (const room of rooms.values()) {
        if (room.players.some(player => player.profileId === body.profileId)) publishRoom(room);
      }
    }
    if (result.status === 200 && request.method === 'POST' && /\/rooms\/[A-Z]{6}\/(start|next)$/.test(url.pathname)) {
      enrichStreamingChorus(url.pathname.split('/')[2]);
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
        if (answer.status === 200 && ['start', 'next'].includes(message.action)) enrichStreamingChorus(id);
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
