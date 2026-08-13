export function getQuotaPresentation(key) {
  const usage = key.dailyCostUsage || {};
  const used = Number(usage.used || 0);
  if (key.dailyCostLimit == null) {
    return { text: `Today $${used.toFixed(2)} · Unlimited`, tone: "normal" };
  }
  const limit = Number(key.dailyCostLimit);
  const exceeded = usage.exceeded || Number(usage.percentage || 0) >= 100;
  const warning = !exceeded && Number(usage.percentage || 0) >= 80;
  return {
    text: `Today $${used.toFixed(2)} / $${limit.toFixed(2)}${exceeded ? " · Limit reached" : ""}`,
    tone: exceeded ? "danger" : warning ? "warning" : "normal",
  };
}

export function parseDailyCostLimitInput(input) {
  const value = String(input).trim();
  if (!/^\d+(?:\.\d{1,2})?$/.test(value)) {
    return { value: null, error: "Enter an amount greater than 0 with at most two decimal places." };
  }
  const amount = Number(value);
  if (!Number.isFinite(amount) || amount <= 0) {
    return { value: null, error: "Daily limit must be greater than $0.00." };
  }
  return { value: amount, error: "" };
}
