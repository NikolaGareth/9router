import { describe, expect, it } from "vitest";
import { normalizeBudgetPool, splitBudgetEvenly, summarizeBudgetPool } from "@/lib/apiKeyBudgetPool.js";

describe("API key budget pool", () => {
  it("splits the distributable budget exactly to the cent", () => {
    const allocations = splitBudgetEvenly(100, 5, Array.from({ length: 20 }, (_, index) => `key-${index}`));
    expect(allocations).toHaveLength(20);
    expect(allocations.every((item) => item.dailyCostLimit === 4.75)).toBe(true);
    expect(allocations.reduce((sum, item) => sum + item.dailyCostLimit, 0)).toBe(95);
  });

  it("distributes indivisible cents without exceeding the pool", () => {
    const allocations = splitBudgetEvenly(1, 0, ["a", "b", "c"]);
    expect(allocations.map((item) => item.dailyCostLimit)).toEqual([0.34, 0.33, 0.33]);
  });

  it("reports custom allocation headroom and rejects invalid pools", () => {
    expect(summarizeBudgetPool(20, 2, [5, 6])).toMatchObject({
      distributableUsd: 18,
      assignedUsd: 11,
      unallocatedUsd: 7,
      exceeded: false,
    });
    expect(() => normalizeBudgetPool({ totalBudgetUsd: 10, reserveUsd: 10 })).toThrow(/Reserve/);
    expect(() => splitBudgetEvenly(0.01, 0, ["a", "b"])).toThrow(/at least/);
  });
});
