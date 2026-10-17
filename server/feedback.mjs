import { createAnonymousReportHandler } from './anonymous-reports.mjs';

export const maximumMessageLength = 2000;
const categoryLabels = new Map([
  ['bug', '不具合・バグ'],
  ['suggestion', 'ご意見・ご要望']
]);
const text = (value, maximum) => {
  if (typeof value !== 'string' || !value.trim() || value.length > maximum) throw new Error('invalid');
  return value.trim();
};

export function normalizeFeedback(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('invalid');
  const id = text(input.id, 36).toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) throw new Error('invalid');
  if (input.category !== undefined && !categoryLabels.has(input.category)) throw new Error('invalid');
  // Never forward profile, room, device, or authentication fields from the request.
  // Keep uncategorized reports compatible with old apps and their saved delivery receipts.
  return { id, ...(input.category === undefined ? {} : { category: input.category }),
    message: text(input.message, maximumMessageLength),
    appVersion: text(input.appVersion, 40), appBuild: text(input.appBuild, 40) };
}

export function discordFeedback(report, receivedAt) {
  return {
    allowed_mentions: { parse: [] },
    embeds: [{ title: 'ご意見送信フォーム · 匿名送信', color: 0xB44B37,
      description: report.message,
      fields: [{ name: '種別', value: categoryLabels.get(report.category) ?? '未選択（旧バージョン）', inline: true },
        { name: 'アプリ', value: `${report.appVersion} (${report.appBuild})`, inline: true }],
      footer: { text: `匿名 · 報告ID: ${report.id}` }, timestamp: new Date(receivedAt).toISOString() }]
  };
}

export function createFeedbackHandler(options = {}) {
  return createAnonymousReportHandler({ webhookURL: () => process.env.DISCORD_FEEDBACK_WEBHOOK_URL,
    ...options, normalizeReport: normalizeFeedback,
    discordReport: discordFeedback, receiptName: 'feedback-reports.json' });
}
