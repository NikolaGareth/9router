import { v4 as uuidv4 } from "uuid";
import { getAdapter } from "../driver.js";
import { getShanghaiDayWindow, normalizeDailyCostLimit } from "../../apiKeyQuota.js";

function rowToKey(row) {
  if (!row) return null;
  return {
    id: row.id,
    key: row.key,
    name: row.name,
    machineId: row.machineId,
    isActive: row.isActive === 1 || row.isActive === true,
    dailyCostLimit: row.dailyCostLimit == null ? null : Number(row.dailyCostLimit),
    createdAt: row.createdAt,
  };
}

export async function getApiKeys() {
  const db = await getAdapter();
  const rows = db.all(`SELECT * FROM apiKeys ORDER BY createdAt ASC`);
  return rows.map(rowToKey);
}

export async function getApiKeyById(id) {
  const db = await getAdapter();
  const row = db.get(`SELECT * FROM apiKeys WHERE id = ?`, [id]);
  return rowToKey(row);
}

export async function createApiKey(name, machineId) {
  if (!machineId) throw new Error("machineId is required");
  const db = await getAdapter();
  const { generateApiKeyWithMachine } = await import("@/shared/utils/apiKey");
  const result = generateApiKeyWithMachine(machineId);
  const apiKey = {
    id: uuidv4(),
    name,
    key: result.key,
    machineId,
    isActive: true,
    dailyCostLimit: null,
    createdAt: new Date().toISOString(),
  };
  db.run(
    `INSERT INTO apiKeys(id, key, name, machineId, isActive, dailyCostLimit, createdAt) VALUES(?, ?, ?, ?, ?, ?, ?)`,
    [apiKey.id, apiKey.key, apiKey.name, apiKey.machineId, 1, null, apiKey.createdAt]
  );
  return apiKey;
}

export async function updateApiKey(id, data) {
  const db = await getAdapter();
  let result = null;
  db.transaction(() => {
    const row = db.get(`SELECT * FROM apiKeys WHERE id = ?`, [id]);
    if (!row) return;
    const merged = { ...rowToKey(row), ...data };
    if (Object.hasOwn(data, "dailyCostLimit")) {
      merged.dailyCostLimit = normalizeDailyCostLimit(data.dailyCostLimit);
    }
    db.run(
      `UPDATE apiKeys SET key = ?, name = ?, machineId = ?, isActive = ?, dailyCostLimit = ? WHERE id = ?`,
      [merged.key, merged.name, merged.machineId, merged.isActive ? 1 : 0, merged.dailyCostLimit, id]
    );
    result = merged;
  });
  return result;
}

export async function deleteApiKey(id) {
  const db = await getAdapter();
  const res = db.run(`DELETE FROM apiKeys WHERE id = ?`, [id]);
  return (res?.changes ?? 0) > 0;
}

export async function validateApiKey(key) {
  const db = await getAdapter();
  const row = db.get(`SELECT isActive FROM apiKeys WHERE key = ?`, [key]);
  if (!row) return false;
  return row.isActive === 1 || row.isActive === true;
}

export async function getApiKeyDailyCostUsage(key, now = new Date(), limitOverride) {
  const db = await getAdapter();
  const keyRow = limitOverride === undefined
    ? db.get(`SELECT dailyCostLimit FROM apiKeys WHERE key = ?`, [key])
    : null;
  const limit = limitOverride === undefined
    ? (keyRow?.dailyCostLimit == null ? null : Number(keyRow.dailyCostLimit))
    : limitOverride;
  const { startAt, resetAt } = getShanghaiDayWindow(now);
  const row = db.get(
    `SELECT COALESCE(SUM(cost), 0) AS used
       FROM usageHistory
      WHERE apiKey = ? AND timestamp >= ? AND timestamp < ?`,
    [key, startAt, resetAt]
  );
  const used = Number(row?.used || 0);
  const remaining = limit == null ? null : Math.max(0, limit - used);
  const percentage = limit == null ? null : (used / limit) * 100;
  return {
    limit,
    used,
    remaining,
    percentage,
    exceeded: limit != null && used >= limit,
    resetAt,
  };
}

export async function checkApiKeyAccess(key, now = new Date()) {
  const db = await getAdapter();
  const row = db.get(`SELECT isActive, dailyCostLimit FROM apiKeys WHERE key = ?`, [key]);
  if (!row) return { allowed: false, reason: "invalid" };
  if (!(row.isActive === 1 || row.isActive === true)) {
    return { allowed: false, reason: "inactive" };
  }
  if (row.dailyCostLimit == null) return { allowed: true, reason: "ok" };
  const usage = await getApiKeyDailyCostUsage(key, now, Number(row.dailyCostLimit));
  if (usage.exceeded) return { allowed: false, reason: "quota_exceeded", usage };
  return { allowed: true, reason: "ok", usage };
}
