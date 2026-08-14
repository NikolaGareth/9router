function toCents(value, fieldName, { allowZero = true } = {}) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || (!allowZero && value === 0)) {
    throw new TypeError(`${fieldName} must be ${allowZero ? "a non-negative" : "a positive"} number`);
  }
  const cents = value * 100;
  if (Math.abs(cents - Math.round(cents)) > 1e-8) {
    throw new TypeError(`${fieldName} must have at most two decimal places`);
  }
  return Math.round(cents);
}

export function normalizeBudgetPool({ totalBudgetUsd, reserveUsd }) {
  const totalCents = toCents(totalBudgetUsd, "Total budget", { allowZero: false });
  const reserveCents = toCents(reserveUsd, "Reserve");
  if (reserveCents >= totalCents) throw new TypeError("Reserve must be less than the total budget");
  return {
    totalBudgetUsd: totalCents / 100,
    reserveUsd: reserveCents / 100,
    distributableUsd: (totalCents - reserveCents) / 100,
  };
}

export function splitBudgetEvenly(totalBudgetUsd, reserveUsd, keyIds) {
  const pool = normalizeBudgetPool({ totalBudgetUsd, reserveUsd });
  const ids = [...new Set((keyIds || []).filter(Boolean))];
  if (ids.length === 0) throw new TypeError("Select at least one API key");
  const availableCents = Math.round(pool.distributableUsd * 100);
  if (availableCents < ids.length) throw new TypeError("Distributable budget must be at least $0.01 per selected key");
  const base = Math.floor(availableCents / ids.length);
  const remainder = availableCents % ids.length;
  return ids.map((id, index) => ({ id, dailyCostLimit: (base + (index < remainder ? 1 : 0)) / 100 }));
}

export function summarizeBudgetPool(totalBudgetUsd, reserveUsd, limits) {
  const pool = normalizeBudgetPool({ totalBudgetUsd, reserveUsd });
  const assignedCents = (limits || []).reduce((sum, value) => sum + toCents(value, "Allocation", { allowZero: false }), 0);
  const distributableCents = Math.round(pool.distributableUsd * 100);
  return {
    ...pool,
    assignedUsd: assignedCents / 100,
    unallocatedUsd: (distributableCents - assignedCents) / 100,
    exceeded: assignedCents > distributableCents,
  };
}
