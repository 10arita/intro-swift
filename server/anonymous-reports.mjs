import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const retentionMS = 30 * 24 * 60 * 60 * 1000;
const failure = (status, error) => ({ status, body: { error } });

// The server shares one intake budget across chorus reports and feedback.
export function createReportRateLimit(now = () => Date.now()) {
  let windowStartedAt = now();
  let deliveriesInWindow = 0;
  return () => {
    if (now() - windowStartedAt >= 60_000) { windowStartedAt = now(); deliveriesInWindow = 0; }
    if (deliveriesInWindow >= 30) return false;
    deliveriesInWindow++;
    return true;
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

export function createAnonymousReportHandler({ dataDir = null,
  webhookURL = () => undefined,
  fetchImpl = (...args) => fetch(...args), now = () => Date.now(),
  rateLimit = createReportRateLimit(now), normalizeReport, discordReport, receiptName } = {}) {
  const delivered = new Map();
  const pending = new Map();
  const file = dataDir ? join(dataDir, receiptName) : null;
  if (file && existsSync(file)) {
    try {
      for (const item of JSON.parse(readFileSync(file, 'utf8'))) {
        if (Number.isFinite(item.receivedAt) && now() - item.receivedAt < retentionMS) {
          const report = normalizeReport(item.report);
          delivered.set(report.id, { report, receivedAt: item.receivedAt });
        }
      }
    } catch { console.error('Anonymous report receipts could not be loaded'); }
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
    } catch { console.error('Anonymous report receipts could not be saved'); }
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
    if (!rateLimit()) return failure(429, '報告が混み合っています。1分ほど待ってから再試行してください。');
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
