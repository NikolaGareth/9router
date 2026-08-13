const SHANGHAI_OFFSET_MS = 8 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

export function getShanghaiDayWindow(now = new Date()) {
  const timestamp = now instanceof Date ? now.getTime() : new Date(now).getTime();
  if (!Number.isFinite(timestamp)) throw new TypeError("Invalid quota timestamp");
  const shiftedDayStart = Math.floor((timestamp + SHANGHAI_OFFSET_MS) / DAY_MS) * DAY_MS;
  const startMs = shiftedDayStart - SHANGHAI_OFFSET_MS;
  return {
    startAt: new Date(startMs).toISOString(),
    resetAt: new Date(startMs + DAY_MS).toISOString(),
  };
}

export function getQuotaRetryAfter(resetAt, now = new Date()) {
  const remainingMs = new Date(resetAt).getTime() - now.getTime();
  return Math.max(1, Math.ceil(remainingMs / 1000));
}

export function normalizeDailyCostLimit(value) {
  if (value === null) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new TypeError("Daily cost limit must be a number greater than 0 or null");
  }
  const cents = value * 100;
  if (Math.abs(cents - Math.round(cents)) > 1e-8) {
    throw new TypeError("Daily cost limit must have at most two decimal places");
  }
  return value;
}
