"use client";

import { useEffect, useMemo, useState } from "react";
import { Button, Input, Modal } from "@/shared/components";
import { splitBudgetEvenly, summarizeBudgetPool } from "@/lib/apiKeyBudgetPool";
import { parseDailyCostLimitInput } from "../quotaPresentation";

const usd = (value) => `$${Number(value || 0).toFixed(2)}`;

export default function ApiKeyBudgetPool({ keys, onSaved }) {
  const [budgetPool, setBudgetPool] = useState(null);
  const [open, setOpen] = useState(false);
  const [total, setTotal] = useState("");
  const [reserve, setReserve] = useState("");
  const [selected, setSelected] = useState({});
  const [limits, setLimits] = useState({});
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);

  const loadPool = async () => {
    try {
      const response = await fetch("/api/keys/budget-pool", { cache: "no-store" });
      const data = await response.json();
      if (response.ok) setBudgetPool(data.budgetPool);
    } catch { /* individual limits remain usable */ }
  };

  useEffect(() => { loadPool(); }, []);

  const configuredLimits = keys.filter((key) => key.dailyCostLimit != null).map((key) => key.dailyCostLimit);
  const assignedUsd = configuredLimits.reduce((sum, value) => sum + Number(value || 0), 0);
  const usedTodayUsd = keys.reduce((sum, key) => sum + Number(key.dailyCostUsage?.used || 0), 0);

  const selectedIds = useMemo(() => keys.filter((key) => selected[key.id]).map((key) => key.id), [keys, selected]);
  let draftSummary = null;
  try {
    const parsedLimits = selectedIds.map((id) => parseDailyCostLimitInput(limits[id])).filter((result) => !result.error).map((result) => result.value);
    if (parsedLimits.length === selectedIds.length && selectedIds.length > 0) {
      draftSummary = summarizeBudgetPool(Number(total), Number(reserve), parsedLimits);
    }
  } catch { /* fields are still being edited */ }

  const openEditor = () => {
    const selectedMap = {};
    const limitMap = {};
    for (const key of keys) {
      selectedMap[key.id] = key.isActive !== false;
      limitMap[key.id] = key.dailyCostLimit == null ? "" : String(key.dailyCostLimit);
    }
    const existingTotal = budgetPool?.totalBudgetUsd;
    setTotal(String(existingTotal || Math.max(100, assignedUsd + 5)));
    setReserve(String(budgetPool?.reserveUsd ?? (existingTotal ? 0 : 5)));
    setSelected(selectedMap);
    setLimits(limitMap);
    setError("");
    setOpen(true);
  };

  const handleEqualSplit = () => {
    try {
      const allocations = splitBudgetEvenly(Number(total), Number(reserve), selectedIds);
      setLimits((current) => ({ ...current, ...Object.fromEntries(allocations.map((item) => [item.id, item.dailyCostLimit.toFixed(2)])) }));
      setError("");
    } catch (splitError) {
      setError(splitError.message);
    }
  };

  const handleSave = async () => {
    try {
      const allocations = selectedIds.map((id) => {
        const parsed = parseDailyCostLimitInput(limits[id]);
        if (parsed.error) throw new TypeError(parsed.error);
        return { id, dailyCostLimit: parsed.value };
      });
      const summary = summarizeBudgetPool(Number(total), Number(reserve), allocations.map((item) => item.dailyCostLimit));
      if (summary.exceeded) throw new TypeError("Allocated limits exceed the amount available after reserve");
      setSaving(true);
      setError("");
      const response = await fetch("/api/keys/budget-pool", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ totalBudgetUsd: Number(total), reserveUsd: Number(reserve), allocations }),
      });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || "Failed to save budget pool");
      setBudgetPool(data.budgetPool);
      setOpen(false);
      await onSaved();
    } catch (saveError) {
      setError(saveError.message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <div className="mb-4 rounded-xl border border-border bg-surface-2 p-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <p className="font-medium flex items-center gap-2">
              <span className="material-symbols-outlined text-[18px] text-primary">account_balance_wallet</span>
              Daily Budget Pool
            </p>
            {budgetPool ? (
              <p className="text-xs text-text-muted mt-1">
                Total {usd(budgetPool.totalBudgetUsd)} · Reserve {usd(budgetPool.reserveUsd)} · Assigned {usd(assignedUsd)} · Used today {usd(usedTodayUsd)}
              </p>
            ) : (
              <p className="text-xs text-text-muted mt-1">Set a total budget, keep a reserve, then split it across multiple API keys.</p>
            )}
          </div>
          <Button size="sm" icon="tune" onClick={openEditor}>Manage allocation</Button>
        </div>
      </div>

      <Modal isOpen={open} title="Manage Daily Budget Pool" onClose={() => !saving && setOpen(false)}>
        <div className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-3">
            <Input label="Total budget (USD/day)" type="number" min="0.01" step="0.01" value={total} onChange={(event) => setTotal(event.target.value)} />
            <Input label="Reserve (USD/day)" type="number" min="0" step="0.01" value={reserve} onChange={(event) => setReserve(event.target.value)} />
          </div>

          <div className="flex items-center justify-between gap-3">
            <p className="text-sm font-medium">API key allocations</p>
            <Button size="sm" variant="secondary" onClick={handleEqualSplit}>Equal split</Button>
          </div>

          <div className="max-h-[340px] overflow-y-auto rounded-xl border border-border divide-y divide-border">
            {keys.map((key) => (
              <div key={key.id} className="flex items-center gap-3 p-3">
                <input
                  type="checkbox"
                  checked={!!selected[key.id]}
                  onChange={(event) => setSelected((current) => ({ ...current, [key.id]: event.target.checked }))}
                  aria-label={`Allocate budget to ${key.name}`}
                  className="h-4 w-4 accent-primary"
                />
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium truncate">{key.name}</p>
                  <p className="text-xs text-text-muted">Today {usd(key.dailyCostUsage?.used)}</p>
                </div>
                <div className="flex items-center gap-1">
                  <span className="text-sm text-text-muted">$</span>
                  <input
                    type="number"
                    min="0.01"
                    step="0.01"
                    disabled={!selected[key.id]}
                    value={limits[key.id] || ""}
                    onChange={(event) => setLimits((current) => ({ ...current, [key.id]: event.target.value }))}
                    aria-label={`Daily limit for ${key.name}`}
                    placeholder="0.00"
                    className="w-24 rounded-lg bg-surface-2 border border-border px-2 py-1.5 text-sm outline-none focus:border-primary disabled:opacity-50"
                  />
                </div>
              </div>
            ))}
          </div>

          <div className={`rounded-lg p-3 text-sm ${draftSummary?.exceeded ? "bg-red-500/10 text-red-500" : "bg-primary/10 text-text-main"}`}>
            {draftSummary ? (
              <>Available {usd(draftSummary.distributableUsd)} · Assigned {usd(draftSummary.assignedUsd)} · {draftSummary.unallocatedUsd >= 0 ? "Unallocated" : "Over"} {usd(Math.abs(draftSummary.unallocatedUsd))}</>
            ) : "Select keys and enter a valid limit for each one."}
          </div>
          {error && <p className="text-sm text-red-500">{error}</p>}

          <div className="flex gap-2">
            <Button onClick={handleSave} fullWidth disabled={saving || selectedIds.length === 0 || !draftSummary || draftSummary.exceeded}>{saving ? "Saving..." : "Save allocation"}</Button>
            <Button onClick={() => setOpen(false)} variant="ghost" fullWidth disabled={saving}>Cancel</Button>
          </div>
        </div>
      </Modal>
    </>
  );
}
