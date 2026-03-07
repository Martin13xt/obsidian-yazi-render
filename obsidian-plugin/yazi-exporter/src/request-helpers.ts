export type RenderProfile = "auto" | "fast" | "balanced" | "quality";

export function normalizeRenderProfile(raw: unknown, fallback: RenderProfile = "auto"): RenderProfile {
  if (typeof raw !== "string") {
    return fallback;
  }
  const value = raw.trim().toLowerCase();
  if (value === "fast" || value === "balanced" || value === "quality" || value === "auto") {
    return value;
  }
  return fallback;
}

export function sanitizeVaultRelativePath(
  raw: unknown,
  normalizePathFn: (value: string) => string
): string | null {
  const trimmed = String(raw ?? "").trim();
  if (!trimmed) {
    return null;
  }

  const normalized = normalizePathFn(trimmed);
  if (!normalized || normalized.startsWith("/") || normalized.startsWith("\\") || normalized.includes("\0")) {
    return null;
  }

  const segments = normalized.split("/");
  if (segments.some((segment) => segment === "" || segment === "." || segment === "..")) {
    return null;
  }

  return normalized;
}

export function isRequestFresh(requestedAt: unknown, maxAgeMs: number, nowMs: number = Date.now()): boolean {
  const requestedAtNumber = Number(requestedAt);
  if (!Number.isFinite(requestedAtNumber) || requestedAtNumber <= 0) {
    return false;
  }

  const ageMs = nowMs - (requestedAtNumber * 1000);
  if (ageMs < -30_000) {
    return false;
  }
  return ageMs <= maxAgeMs;
}

export function resolveAutoRenderProfile(colsRaw?: number, rowsRaw?: number): RenderProfile {
  const cols = Number.isFinite(Number(colsRaw)) ? Math.max(0, Math.floor(Number(colsRaw))) : 0;
  const rows = Number.isFinite(Number(rowsRaw)) ? Math.max(0, Math.floor(Number(rowsRaw))) : 0;

  if ((cols > 0 && cols <= 120) || (rows > 0 && rows <= 36)) {
    return "fast";
  }
  if (cols >= 180 && rows >= 55) {
    return "quality";
  }
  return "balanced";
}
