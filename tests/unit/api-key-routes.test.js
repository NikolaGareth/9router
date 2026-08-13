import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getApiKeys: vi.fn(),
  getApiKeyDailyCostUsage: vi.fn(),
  getApiKeyById: vi.fn(),
  updateApiKey: vi.fn(),
  deleteApiKey: vi.fn(),
  createApiKey: vi.fn(),
}));

vi.mock("next/server", () => ({
  NextResponse: { json: (body, init) => ({ body, status: init?.status || 200 }) },
}));

vi.mock("@/lib/localDb", () => mocks);
vi.mock("@/shared/utils/machineId", () => ({ getConsistentMachineId: vi.fn() }));

const keysRoute = await import("../../src/app/api/keys/route.js");
const keyRoute = await import("../../src/app/api/keys/[id]/route.js");

describe("API key quota routes", () => {
  beforeEach(() => vi.clearAllMocks());

  it("GET /api/keys includes daily usage for every key", async () => {
    mocks.getApiKeys.mockResolvedValue([
      { id: "a", key: "sk-a", dailyCostLimit: 1 },
      { id: "b", key: "sk-b", dailyCostLimit: null },
    ]);
    mocks.getApiKeyDailyCostUsage
      .mockResolvedValueOnce({ limit: 1, used: 0.4, remaining: 0.6, percentage: 40, exceeded: false, resetAt: "reset" })
      .mockResolvedValueOnce({ limit: null, used: 2, remaining: null, percentage: null, exceeded: false, resetAt: "reset" });

    const response = await keysRoute.GET();

    expect(response.status).toBe(200);
    expect(response.body.keys[0].dailyCostUsage.used).toBe(0.4);
    expect(response.body.keys[1].dailyCostUsage.limit).toBeNull();
  });

  it.each([0, -1, "1", 1.001, Number.NaN])("PUT rejects invalid dailyCostLimit %p", async (dailyCostLimit) => {
    mocks.getApiKeyById.mockResolvedValue({ id: "a", key: "sk-a" });
    const request = { json: vi.fn().mockResolvedValue({ dailyCostLimit }) };

    const response = await keyRoute.PUT(request, { params: Promise.resolve({ id: "a" }) });

    expect(response.status).toBe(400);
    expect(mocks.updateApiKey).not.toHaveBeenCalled();
  });

  it("PUT accepts a two-decimal limit and null for unlimited", async () => {
    mocks.getApiKeyById.mockResolvedValue({ id: "a", key: "sk-a" });
    mocks.updateApiKey
      .mockResolvedValueOnce({ id: "a", dailyCostLimit: 12.34 })
      .mockResolvedValueOnce({ id: "a", dailyCostLimit: null });

    const limited = await keyRoute.PUT(
      { json: vi.fn().mockResolvedValue({ dailyCostLimit: 12.34 }) },
      { params: Promise.resolve({ id: "a" }) }
    );
    const unlimited = await keyRoute.PUT(
      { json: vi.fn().mockResolvedValue({ dailyCostLimit: null }) },
      { params: Promise.resolve({ id: "a" }) }
    );

    expect(limited.status).toBe(200);
    expect(unlimited.status).toBe(200);
    expect(mocks.updateApiKey).toHaveBeenNthCalledWith(1, "a", { dailyCostLimit: 12.34 });
    expect(mocks.updateApiKey).toHaveBeenNthCalledWith(2, "a", { dailyCostLimit: null });
  });

  it.each([0.29, 1.1])("PUT accepts floating-point-safe cent amount %p", async (dailyCostLimit) => {
    mocks.getApiKeyById.mockResolvedValue({ id: "a", key: "sk-a" });
    mocks.updateApiKey.mockResolvedValue({ id: "a", dailyCostLimit });

    const response = await keyRoute.PUT(
      { json: vi.fn().mockResolvedValue({ dailyCostLimit }) },
      { params: Promise.resolve({ id: "a" }) }
    );

    expect(response.status).toBe(200);
    expect(mocks.updateApiKey).toHaveBeenCalledWith("a", { dailyCostLimit });
  });
});
