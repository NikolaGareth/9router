import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

let tempDir;
const originalDataDir = process.env.DATA_DIR;

beforeEach(() => {
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "9router-api-key-quota-"));
  process.env.DATA_DIR = tempDir;
  delete global._dbAdapter;
  vi.resetModules();
});

afterEach(() => {
  try { global._dbAdapter?.instance?.close?.(); } catch {}
  delete global._dbAdapter;
  if (tempDir) fs.rmSync(tempDir, { recursive: true, force: true });
  if (originalDataDir === undefined) delete process.env.DATA_DIR;
  else process.env.DATA_DIR = originalDataDir;
});

describe("API key daily cost quota", () => {
  it("uses Asia/Shanghai calendar-day boundaries across month and year changes", async () => {
    const { getShanghaiDayWindow } = await import("@/lib/apiKeyQuota.js");

    expect(getShanghaiDayWindow(new Date("2026-12-31T16:00:00.000Z"))).toEqual({
      startAt: "2026-12-31T16:00:00.000Z",
      resetAt: "2027-01-01T16:00:00.000Z",
    });
    expect(getShanghaiDayWindow(new Date("2026-08-13T15:59:59.999Z"))).toEqual({
      startAt: "2026-08-12T16:00:00.000Z",
      resetAt: "2026-08-13T16:00:00.000Z",
    });
  });

  it("persists a nullable limit and aggregates only the current Shanghai day", async () => {
    const dbApi = await import("@/lib/db/index.js");
    const { getAdapter } = await import("@/lib/db/driver.js");
    const key = await dbApi.createApiKey("budgeted", "machine-a");
    expect(key.dailyCostLimit).toBeNull();

    await dbApi.updateApiKey(key.id, { dailyCostLimit: 1 });
    const db = await getAdapter();
    const insert = (timestamp, cost) => db.run(
      `INSERT INTO usageHistory(timestamp, apiKey, cost, status) VALUES(?, ?, ?, 'ok')`,
      [timestamp, key.key, cost]
    );
    insert("2026-08-12T15:59:59.999Z", 9);
    insert("2026-08-12T16:00:00.000Z", 0.4);
    insert("2026-08-13T15:59:59.999Z", 0.6);
    insert("2026-08-13T16:00:00.000Z", 7);

    const usage = await dbApi.getApiKeyDailyCostUsage(key.key, new Date("2026-08-13T12:00:00.000Z"));
    expect(usage).toMatchObject({
      limit: 1,
      used: 1,
      remaining: 0,
      percentage: 100,
      exceeded: true,
      resetAt: "2026-08-13T16:00:00.000Z",
    });
  });

  it("returns structured access states for invalid, paused, unlimited and exceeded keys", async () => {
    const dbApi = await import("@/lib/db/index.js");
    const { getAdapter } = await import("@/lib/db/driver.js");
    const unlimited = await dbApi.createApiKey("unlimited", "machine-a");
    expect(await dbApi.checkApiKeyAccess(unlimited.key)).toMatchObject({ allowed: true, reason: "ok" });

    expect(await dbApi.checkApiKeyAccess("missing")).toEqual({ allowed: false, reason: "invalid" });
    await dbApi.updateApiKey(unlimited.id, { isActive: false });
    expect(await dbApi.checkApiKeyAccess(unlimited.key)).toEqual({ allowed: false, reason: "inactive" });

    const limited = await dbApi.createApiKey("limited", "machine-a");
    await dbApi.updateApiKey(limited.id, { dailyCostLimit: 2 });
    const db = await getAdapter();
    db.run(
      `INSERT INTO usageHistory(timestamp, apiKey, cost, status) VALUES(?, ?, ?, 'ok')`,
      ["2026-08-13T03:00:00.000Z", limited.key, 2]
    );
    const result = await dbApi.checkApiKeyAccess(limited.key, new Date("2026-08-13T12:00:00.000Z"));
    expect(result).toMatchObject({ allowed: false, reason: "quota_exceeded" });
    expect(result.usage.exceeded).toBe(true);
  });

  it("round-trips dailyCostLimit through database export and import", async () => {
    const dbApi = await import("@/lib/db/index.js");
    const key = await dbApi.createApiKey("exported", "machine-a");
    await dbApi.updateApiKey(key.id, { dailyCostLimit: 12.34 });

    const exported = await dbApi.exportDb();
    expect(exported.apiKeys[0].dailyCostLimit).toBe(12.34);
    await dbApi.importDb(exported);
    expect((await dbApi.getApiKeyById(key.id)).dailyCostLimit).toBe(12.34);
  });

  it("rejects invalid imported dailyCostLimit values", async () => {
    const dbApi = await import("@/lib/db/index.js");
    await expect(dbApi.importDb({
      apiKeys: [{ id: "bad", key: "sk-bad", name: "bad", dailyCostLimit: "abc" }],
    })).rejects.toThrow(/Daily cost limit/);
  });

  it("updates multiple key limits atomically", async () => {
    const dbApi = await import("@/lib/db/index.js");
    const first = await dbApi.createApiKey("first", "machine-a");
    const second = await dbApi.createApiKey("second", "machine-a");

    await dbApi.updateApiKeyDailyCostLimits([
      { id: first.id, dailyCostLimit: 4.75 },
      { id: second.id, dailyCostLimit: 6.25 },
    ]);
    expect((await dbApi.getApiKeyById(first.id)).dailyCostLimit).toBe(4.75);
    expect((await dbApi.getApiKeyById(second.id)).dailyCostLimit).toBe(6.25);

    await expect(dbApi.updateApiKeyDailyCostLimits([
      { id: first.id, dailyCostLimit: 1 },
      { id: "missing", dailyCostLimit: 1 },
    ])).rejects.toThrow(/not found/);
    expect((await dbApi.getApiKeyById(first.id)).dailyCostLimit).toBe(4.75);
  });
});
