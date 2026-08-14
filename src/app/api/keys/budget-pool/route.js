import { NextResponse } from "next/server";
import { getSettings, updateSettings, updateApiKeyDailyCostLimits } from "@/lib/localDb";
import { normalizeBudgetPool, summarizeBudgetPool } from "@/lib/apiKeyBudgetPool";
import { normalizeDailyCostLimit } from "@/lib/apiKeyQuota";

export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const settings = await getSettings();
    return NextResponse.json({ budgetPool: settings.apiKeyBudgetPool || null });
  } catch (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
}

export async function PUT(request) {
  try {
    const body = await request.json();
    const pool = normalizeBudgetPool(body);
    if (!Array.isArray(body.allocations) || body.allocations.length === 0) {
      return NextResponse.json({ error: "Select at least one API key" }, { status: 400 });
    }
    const allocations = body.allocations.map((allocation) => ({
      id: allocation?.id,
      dailyCostLimit: normalizeDailyCostLimit(allocation?.dailyCostLimit),
    }));
    const summary = summarizeBudgetPool(pool.totalBudgetUsd, pool.reserveUsd, allocations.map((allocation) => allocation.dailyCostLimit));
    if (summary.exceeded) {
      return NextResponse.json({ error: "Allocated limits exceed the distributable budget" }, { status: 400 });
    }

    const keys = await updateApiKeyDailyCostLimits(allocations);
    const budgetPool = {
      totalBudgetUsd: pool.totalBudgetUsd,
      reserveUsd: pool.reserveUsd,
      updatedAt: new Date().toISOString(),
    };
    await updateSettings({ apiKeyBudgetPool: budgetPool });
    return NextResponse.json({ budgetPool, summary, keys });
  } catch (error) {
    const status = error instanceof TypeError || /not found|Duplicate/.test(error.message) ? 400 : 500;
    return NextResponse.json({ error: error.message }, { status });
  }
}
