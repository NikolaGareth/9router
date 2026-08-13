import { describe, expect, it } from "vitest";
import {
  getQuotaPresentation,
  parseDailyCostLimitInput,
} from "../../src/app/(dashboard)/dashboard/endpoint/quotaPresentation.js";

describe("API key quota presentation", () => {
  it("formats unlimited, warning and exceeded summaries", () => {
    expect(getQuotaPresentation({ dailyCostLimit: null, dailyCostUsage: { used: 2 } })).toEqual({
      text: "Today $2.00 · Unlimited",
      tone: "normal",
    });
    expect(getQuotaPresentation({ dailyCostLimit: 10, dailyCostUsage: { used: 8, percentage: 80 } })).toEqual({
      text: "Today $8.00 / $10.00",
      tone: "warning",
    });
    expect(getQuotaPresentation({ dailyCostLimit: 10, dailyCostUsage: { used: 10.5, percentage: 105, exceeded: true } })).toEqual({
      text: "Today $10.50 / $10.00 · Limit reached",
      tone: "danger",
    });
  });

  it("parses valid amounts and rejects invalid precision or zero", () => {
    expect(parseDailyCostLimitInput("12.34")).toEqual({ value: 12.34, error: "" });
    expect(parseDailyCostLimitInput("0").error).toMatch(/greater/);
    expect(parseDailyCostLimitInput("1.001").error).toMatch(/two decimal/);
    expect(parseDailyCostLimitInput("abc").error).toMatch(/two decimal/);
  });
});
