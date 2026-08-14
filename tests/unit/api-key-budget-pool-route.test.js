import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getSettings: vi.fn(),
  updateSettings: vi.fn(),
  updateApiKeyDailyCostLimits: vi.fn(),
}));

vi.mock("next/server", () => ({
  NextResponse: { json: (body, init) => ({ body, status: init?.status || 200 }) },
}));
vi.mock("@/lib/localDb", () => mocks);

const route = await import("../../src/app/api/keys/budget-pool/route.js");

describe("API key budget pool route", () => {
  beforeEach(() => vi.clearAllMocks());

  it("saves custom allocations and pool metadata", async () => {
    mocks.updateApiKeyDailyCostLimits.mockResolvedValue([{ id: "a" }, { id: "b" }]);
    mocks.updateSettings.mockResolvedValue({});
    const response = await route.PUT({ json: vi.fn().mockResolvedValue({
      totalBudgetUsd: 20,
      reserveUsd: 2,
      allocations: [{ id: "a", dailyCostLimit: 7 }, { id: "b", dailyCostLimit: 9 }],
    }) });

    expect(response.status).toBe(200);
    expect(response.body.summary).toMatchObject({ assignedUsd: 16, unallocatedUsd: 2 });
    expect(mocks.updateApiKeyDailyCostLimits).toHaveBeenCalledTimes(1);
    expect(mocks.updateSettings).toHaveBeenCalledWith({ apiKeyBudgetPool: expect.objectContaining({ totalBudgetUsd: 20, reserveUsd: 2 }) });
  });

  it("rejects allocations that consume the reserve", async () => {
    const response = await route.PUT({ json: vi.fn().mockResolvedValue({
      totalBudgetUsd: 20,
      reserveUsd: 2,
      allocations: [{ id: "a", dailyCostLimit: 19 }],
    }) });

    expect(response.status).toBe(400);
    expect(mocks.updateApiKeyDailyCostLimits).not.toHaveBeenCalled();
  });
});
