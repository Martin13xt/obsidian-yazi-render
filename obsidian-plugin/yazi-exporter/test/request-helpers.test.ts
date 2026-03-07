import { describe, expect, it } from "vitest";
import {
  isRequestFresh,
  normalizeRenderProfile,
  resolveAutoRenderProfile,
  sanitizeVaultRelativePath,
} from "../src/request-helpers";

const normalizePathForTest = (value: string): string =>
  value.replace(/\\/g, "/").replace(/\/{2,}/g, "/").replace(/^\.\/+/, "");

describe("request-helpers", () => {
  it("sanitizes vault-relative paths", () => {
    expect(sanitizeVaultRelativePath("notes/today.md", normalizePathForTest)).toBe("notes/today.md");
    expect(sanitizeVaultRelativePath("a\\\\b.md", normalizePathForTest)).toBe("a/b.md");
  });

  it("rejects unsafe paths", () => {
    expect(sanitizeVaultRelativePath("", normalizePathForTest)).toBeNull();
    expect(sanitizeVaultRelativePath("../secret.md", normalizePathForTest)).toBeNull();
    expect(sanitizeVaultRelativePath("/abs/path.md", normalizePathForTest)).toBeNull();
    expect(sanitizeVaultRelativePath("a/./b.md", normalizePathForTest)).toBeNull();
  });

  it("normalizes render profile values", () => {
    expect(normalizeRenderProfile("FAST", "auto")).toBe("fast");
    expect(normalizeRenderProfile("quality", "auto")).toBe("quality");
    expect(normalizeRenderProfile("unknown", "balanced")).toBe("balanced");
  });

  it("evaluates request freshness window", () => {
    const nowMs = 1_700_000_000_000;
    const nowSec = Math.floor(nowMs / 1000);

    expect(isRequestFresh(undefined, 180_000, nowMs)).toBe(false);
    expect(isRequestFresh("invalid", 180_000, nowMs)).toBe(false);
    expect(isRequestFresh(nowSec, 180_000, nowMs)).toBe(true);
    expect(isRequestFresh(nowSec - 60, 180_000, nowMs)).toBe(true);
    expect(isRequestFresh(nowSec - 500, 180_000, nowMs)).toBe(false);
    expect(isRequestFresh(nowSec + 60, 180_000, nowMs)).toBe(false);
  });

  it("selects auto profile from pane size", () => {
    expect(resolveAutoRenderProfile(100, 40)).toBe("fast");
    expect(resolveAutoRenderProfile(190, 60)).toBe("quality");
    expect(resolveAutoRenderProfile(150, 45)).toBe("balanced");
  });
});
