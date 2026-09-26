export function formatNumber(value) {
  const n = Number(value || 0);
  if (!Number.isFinite(n)) return "0";
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(n);
}

export function formatCompact(value) {
  const n = Number(value || 0);
  if (!Number.isFinite(n)) return "0";
  const abs = Math.abs(n);
  const sign = n < 0 ? "-" : "";
  const units = [[1e12,"T"],[1e9,"B"],[1e6,"M"],[1e3,"K"]];
  for (const [size, suffix] of units) {
    if (abs >= size) return `${sign}${trim(abs / size)}${suffix}`;
  }
  return `${sign}${Math.floor(abs)}`;
}

function trim(n) {
  if (n >= 100) return n.toFixed(0);
  if (n >= 10) return n.toFixed(1).replace(/\.0$/, "");
  return n.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

export function parseCompactAmount(input) {
  if (typeof input === "number") return Math.max(0, Math.floor(input));
  const raw = String(input ?? "").trim().toLowerCase().replace(/,/g, "");
  if (!raw) return 0;
  const match = raw.match(/^([0-9]+(?:\.[0-9]+)?)(k|m|b|t)?$/i);
  if (!match) return NaN;
  const base = Number(match[1]);
  const multiplier = ({ k: 1e3, m: 1e6, b: 1e9, t: 1e12 }[match[2] || ""] || 1);
  return Math.floor(base * multiplier);
}

export function displayPetValue(value) {
  return formatCompact(value);
}

export function rankForWagered(total) {
  const n = Number(total || 0);
  if (n >= 1e12) return { name: "COSMIC", color: "#b86cff", next: null };
  if (n >= 1e11) return { name: "TITAN", color: "#ffcb55", next: 1e12 };
  if (n >= 1e10) return { name: "WHALE", color: "#56d9ff", next: 1e11 };
  if (n >= 1e9) return { name: "HIGH ROLLER", color: "#6f8dff", next: 1e10 };
  if (n >= 1e8) return { name: "BIG SPENDER", color: "#5de2ad", next: 1e9 };
  if (n >= 1e7) return { name: "TRADER", color: "#f1a95b", next: 1e8 };
  return { name: "ROOKIE", color: "#8390aa", next: 1e7 };
}
