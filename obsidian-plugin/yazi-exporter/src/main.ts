import {
  App,
  Component,
  MarkdownRenderer,
  MarkdownView,
  Notice,
  normalizePath,
  Plugin,
  PluginSettingTab,
  Setting,
  TFile,
} from "obsidian";
import html2canvas from "html2canvas";
import { promises as fs } from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import {
  isRequestFresh as isRequestFreshValue,
  normalizeRenderProfile as normalizeRenderProfileValue,
  resolveAutoRenderProfile as resolveAutoRenderProfileValue,
  sanitizeVaultRelativePath as sanitizeVaultRelativePathValue,
  type RenderProfile,
} from "./request-helpers";

interface YaziExporterSettings {
  cacheDir: string;
  widthPx: number;
  maxHeightPx: number;
  pageHeightPx: number;
  pixelRatio: number;
  paddingPx: number;
  renderWaitMs: number;
  enableDebugLogs: boolean;
  forceCustomColors: boolean;
  backgroundColor: string;
  textColor: string;
}

interface YaziRenderRequest {
  path: string;
  digest?: string;
  requestId?: string;
  renderWidthPx?: number;
  pageHeightPx?: number;
  targetPage?: number;
  quickMode?: boolean;
  renderProfile?: RenderProfile;
  terminalProgram?: string;
  terminalScale?: number;
  renderCalcBaselinePx?: number;
  renderCalcByColsPx?: number;
  renderCalcAfterColsPx?: number;
  renderCalcAfterReadabilityPx?: number;
  renderCalcAfterTerminalPx?: number;
  renderCalcTmuxCapPx?: number;
  readabilityZoom?: number;
  pageTallness?: number;
  previewCols?: number;
  previewRows?: number;
  requestedAt?: number;
}

const DEFAULT_CACHE_DIR = (() => {
  if (process.platform === "darwin") {
    return "~/Library/Caches/obsidian-yazi";
  }
  const xdgCacheHome = process.env.XDG_CACHE_HOME?.trim();
  if (xdgCacheHome) {
    return `${xdgCacheHome.replace(/\/+$/, "")}/obsidian-yazi`;
  }
  return "~/.cache/obsidian-yazi";
})();

const DEFAULT_SETTINGS: YaziExporterSettings = {
  cacheDir: DEFAULT_CACHE_DIR,
  widthPx: 680,
  maxHeightPx: 0,
  pageHeightPx: 820,
  pixelRatio: 1.25,
  paddingPx: 24,
  renderWaitMs: 120,
  enableDebugLogs: false,
  forceCustomColors: false,
  backgroundColor: "#ffffff",
  textColor: "#222222",
};

const RENDER_TIMEOUT_MS = 9000;
const CAPTURE_TIMEOUT_MS = 30000;
const EXPORT_TIMEOUT_MS = 60000;
const MAX_INLINE_IMAGE_PIXELS = 16_000_000;
const MAX_INLINE_IMAGE_EDGE = 4096;
const INLINE_IMAGE_CACHE_MAX_BYTES = 64 * 1024 * 1024;
const INLINE_IMAGE_CACHE_TTL_MS = 30_000;
const REQUEST_MAX_AGE_MS = 3 * 60_000;
const MAX_QUEUE_FILES = 128;
const MAX_CANVAS_BYTES = 512 * 1024 * 1024;
const MAX_CANVAS_EDGE = 32_767;
const MIN_CAPTURE_SCALE = 0.35;
const CJK_TEXT_RE = /[\u3000-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/;
const CACHE_ROOT_ENV_VAR = "OBSIDIAN_YAZI_CACHE";
const DEBUG_INCLUDE_PATHS_ENV_VAR = "OBSIDIAN_YAZI_DEBUG_INCLUDE_PATHS";

export default class YaziExporterPlugin extends Plugin {
  settings: YaziExporterSettings = { ...DEFAULT_SETTINGS };
  private inFlight = new Map<string, Promise<string>>();
  private pendingRequests = new Map<string, YaziRenderRequest | undefined>();
  private inlineImageCache = new Map<string, { dataUrl: string; approxBytes: number; at: number }>();
  private inlineImageCacheBytes = 0;
  private imageNameIndexCache: Map<string, TFile[]> | null = null;
  private imageNameIndexCachedAt = 0;

  async onload() {
    await this.loadSettings();

    this.addCommand({
      id: "export-active-to-cache",
      name: "Export active note to Yazi cache",
      callback: async () => {
        try {
          const file = this.app.workspace.getActiveFile();
          if (!file) {
            new Notice("Yazi Exporter: active note not found.");
            return;
          }

          await this.exportFileToCache(file.path);
        } catch (error) {
          console.error("Yazi Exporter failed", error);
          new Notice("Yazi Exporter: export failed. Open console for details.");
        }
      },
    });

    this.addCommand({
      id: "export-requested-to-cache",
      name: "Export requested note to Yazi cache",
      callback: async () => {
        try {
          await this.exportRequestedToCache();
        } catch (error) {
          console.error("Yazi Exporter failed", error);
          new Notice("Yazi Exporter: export failed. Open console for details.");
        }
      },
    });

    this.addSettingTab(new YaziExporterSettingTab(this.app, this));

    this.registerEvent(this.app.vault.on("create", () => this.invalidateImageNameIndex()));
    this.registerEvent(this.app.vault.on("delete", () => this.invalidateImageNameIndex()));
    this.registerEvent(this.app.vault.on("rename", () => this.invalidateImageNameIndex()));
  }

  async loadSettings() {
    const loaded = Object.assign({}, DEFAULT_SETTINGS, await this.loadData()) as YaziExporterSettings;
    const maxHeight = Number(loaded.maxHeightPx);

    loaded.widthPx = Math.max(500, Number(loaded.widthPx) || DEFAULT_SETTINGS.widthPx);
    loaded.pageHeightPx = Math.max(300, Number(loaded.pageHeightPx) || DEFAULT_SETTINGS.pageHeightPx);
    loaded.pixelRatio = Math.max(1, Math.min(2.5, Number(loaded.pixelRatio) || DEFAULT_SETTINGS.pixelRatio));
    loaded.paddingPx = Math.max(0, Number(loaded.paddingPx) || DEFAULT_SETTINGS.paddingPx);
    loaded.renderWaitMs = Math.max(0, Number(loaded.renderWaitMs) || DEFAULT_SETTINGS.renderWaitMs);
    loaded.maxHeightPx = !Number.isFinite(maxHeight) || maxHeight <= 0 ? 0 : Math.max(1000, Math.floor(maxHeight));
    loaded.enableDebugLogs = Boolean(loaded.enableDebugLogs);

    this.settings = loaded;
  }

  async saveSettings() {
    await this.saveData(this.settings);
  }

  private normalizeRenderProfile(raw: unknown, fallback: RenderProfile = "auto"): RenderProfile {
    return normalizeRenderProfileValue(raw, fallback);
  }

  private sanitizeVaultRelativePath(raw: string): string | null {
    return sanitizeVaultRelativePathValue(raw, normalizePath);
  }

  private isRequestFresh(request?: YaziRenderRequest | null): boolean {
    return isRequestFreshValue(request?.requestedAt, REQUEST_MAX_AGE_MS);
  }

  private resolveAutoRenderProfile(colsRaw?: number, rowsRaw?: number): RenderProfile {
    return resolveAutoRenderProfileValue(colsRaw, rowsRaw);
  }

  private shouldIncludeSensitiveDebugPaths(): boolean {
    const raw = process.env[DEBUG_INCLUDE_PATHS_ENV_VAR]?.trim().toLowerCase();
    return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
  }

  private async exportRequestedToCache(): Promise<string> {
    const cacheRoot = this.resolveEffectiveCacheRoot();
    await this.ensureCacheDirs(cacheRoot);

    const requestPath = path.join(cacheRoot, "requests", "current.txt");
    const requestJsonPath = path.join(cacheRoot, "requests", "current.json");
    const requestQueueDir = path.join(cacheRoot, "requests", "queue");
    const queuedRequestRaw = await this.readQueuedRequest(requestQueueDir);
    const currentRequestRaw = await this.readRenderRequest(requestJsonPath);
    const queuedRequest = this.isRequestFresh(queuedRequestRaw) ? queuedRequestRaw : null;
    const currentRequest = this.isRequestFresh(currentRequestRaw) ? currentRequestRaw : null;
    const requestPayload = this.selectPreferredRequest(currentRequest, queuedRequest);
    const requestSource = requestPayload === currentRequest
      ? "current"
      : requestPayload === queuedRequest
        ? "queue"
        : "none";

    const requestTextStat = await fs.stat(requestPath).catch(() => null);
    const requestTextFresh = Boolean(requestTextStat && ((Date.now() - requestTextStat.mtimeMs) <= REQUEST_MAX_AGE_MS));
    const requestedPathFromText = requestTextFresh
      ? ((await fs.readFile(requestPath, "utf8").catch(() => "")).split(/\r?\n/, 1)[0]?.trim() ?? "")
      : "";
    const requestedPath = this.sanitizeVaultRelativePath(requestPayload?.path ?? requestedPathFromText);
    const tracePath = path.join(cacheRoot, "log", "request-trace.json");

    if (this.settings.enableDebugLogs) {
      const includePaths = this.shouldIncludeSensitiveDebugPaths();
      const tracePayload: Record<string, unknown> = {
        at: new Date().toISOString(),
        requestTextFresh,
        requestSource,
        requestId: requestPayload?.requestId ?? null,
        requestDigest: requestPayload?.digest ?? null,
        terminalProgram: requestPayload?.terminalProgram ?? null,
        terminalScale: requestPayload?.terminalScale ?? null,
        renderCalcBaselinePx: requestPayload?.renderCalcBaselinePx ?? null,
        renderCalcByColsPx: requestPayload?.renderCalcByColsPx ?? null,
        renderCalcAfterColsPx: requestPayload?.renderCalcAfterColsPx ?? null,
        renderCalcAfterReadabilityPx: requestPayload?.renderCalcAfterReadabilityPx ?? null,
        renderCalcAfterTerminalPx: requestPayload?.renderCalcAfterTerminalPx ?? null,
        renderCalcTmuxCapPx: requestPayload?.renderCalcTmuxCapPx ?? null,
        requestFresh: Boolean(requestPayload),
        hasPayload: Boolean(requestPayload),
      };
      if (includePaths) {
        Object.assign(tracePayload, {
          requestPath,
          requestJsonPath,
          requestQueueDir,
          requestedPath,
        });
      }
      await fs.writeFile(tracePath, JSON.stringify(tracePayload, null, 2)).catch(() => undefined);
    }

    if (!requestedPath) {
      throw new Error("Request file is empty or missing");
    }

    return this.exportFileToCache(requestedPath, requestPayload ?? undefined);
  }

  private async readRenderRequest(requestJsonPath: string): Promise<YaziRenderRequest | null> {
    const raw = await fs.readFile(requestJsonPath, "utf8").catch(() => "");
    if (!raw.trim()) {
      return null;
    }

    try {
      const parsed = JSON.parse(raw) as Partial<YaziRenderRequest> | null;
      if (!parsed || typeof parsed !== "object") {
        return null;
      }

      const pathValue = this.sanitizeVaultRelativePath(typeof parsed.path === "string" ? parsed.path : "");
      if (!pathValue) {
        return null;
      }

      const request: YaziRenderRequest = { path: pathValue };
      const parseNonNegativeInt = (value: unknown): number | undefined => {
        const n = Number(value);
        if (!Number.isFinite(n) || n < 0) {
          return undefined;
        }
        return Math.floor(n);
      };

      const digest = typeof parsed.digest === "string" ? parsed.digest.trim() : "";
      if (/^[A-Za-z0-9_-]{8,128}$/.test(digest)) {
        request.digest = digest;
      }

      const requestId = typeof parsed.requestId === "string" ? parsed.requestId.trim() : "";
      if (/^[A-Za-z0-9._:-]{1,128}$/.test(requestId)) {
        request.requestId = requestId;
      }

      const width = Number(parsed.renderWidthPx);
      if (Number.isFinite(width) && width > 0) {
        request.renderWidthPx = Math.floor(width);
      }

      const pageHeight = Number(parsed.pageHeightPx);
      if (Number.isFinite(pageHeight) && pageHeight > 0) {
        request.pageHeightPx = Math.floor(pageHeight);
      }

      const targetPage = Number(parsed.targetPage);
      if (Number.isFinite(targetPage) && targetPage >= 0) {
        request.targetPage = Math.floor(targetPage);
      }

      const quickModeRaw: unknown = (parsed as Record<string, unknown>).quickMode;
      if (typeof quickModeRaw === "boolean") {
        request.quickMode = quickModeRaw;
      } else if (typeof quickModeRaw === "string") {
        const raw = quickModeRaw.trim().toLowerCase();
        if (raw === "1" || raw === "true" || raw === "yes") {
          request.quickMode = true;
        } else if (raw === "0" || raw === "false" || raw === "no") {
          request.quickMode = false;
        }
      }

      request.renderProfile = this.normalizeRenderProfile(parsed.renderProfile, "auto");

      const readabilityZoom = Number(parsed.readabilityZoom);
      if (Number.isFinite(readabilityZoom) && readabilityZoom > 0) {
        request.readabilityZoom = Math.max(0.7, Math.min(2.4, readabilityZoom));
      }

      const pageTallness = Number(parsed.pageTallness);
      if (Number.isFinite(pageTallness) && pageTallness > 0) {
        request.pageTallness = Math.max(0.7, Math.min(2.4, pageTallness));
      }

      const cols = Number(parsed.previewCols);
      if (Number.isFinite(cols) && cols >= 0) {
        request.previewCols = Math.floor(cols);
      }

      const rows = Number(parsed.previewRows);
      if (Number.isFinite(rows) && rows >= 0) {
        request.previewRows = Math.floor(rows);
      }

      const terminalProgram = typeof parsed.terminalProgram === "string"
        ? parsed.terminalProgram.trim().toLowerCase()
        : "";
      if (/^[A-Za-z0-9._:-]{1,64}$/.test(terminalProgram)) {
        request.terminalProgram = terminalProgram;
      }

      const terminalScale = Number(parsed.terminalScale);
      if (Number.isFinite(terminalScale) && terminalScale > 0) {
        request.terminalScale = Math.max(0.7, Math.min(2.6, terminalScale));
      }

      const renderCalcBaselinePx = parseNonNegativeInt(parsed.renderCalcBaselinePx);
      if (renderCalcBaselinePx !== undefined) {
        request.renderCalcBaselinePx = renderCalcBaselinePx;
      }
      const renderCalcByColsPx = parseNonNegativeInt(parsed.renderCalcByColsPx);
      if (renderCalcByColsPx !== undefined) {
        request.renderCalcByColsPx = renderCalcByColsPx;
      }
      const renderCalcAfterColsPx = parseNonNegativeInt(parsed.renderCalcAfterColsPx);
      if (renderCalcAfterColsPx !== undefined) {
        request.renderCalcAfterColsPx = renderCalcAfterColsPx;
      }
      const renderCalcAfterReadabilityPx = parseNonNegativeInt(parsed.renderCalcAfterReadabilityPx);
      if (renderCalcAfterReadabilityPx !== undefined) {
        request.renderCalcAfterReadabilityPx = renderCalcAfterReadabilityPx;
      }
      const renderCalcAfterTerminalPx = parseNonNegativeInt(parsed.renderCalcAfterTerminalPx);
      if (renderCalcAfterTerminalPx !== undefined) {
        request.renderCalcAfterTerminalPx = renderCalcAfterTerminalPx;
      }
      const renderCalcTmuxCapPx = parseNonNegativeInt(parsed.renderCalcTmuxCapPx);
      if (renderCalcTmuxCapPx !== undefined) {
        request.renderCalcTmuxCapPx = renderCalcTmuxCapPx;
      }

      const requestedAt = Number(parsed.requestedAt);
      if (Number.isFinite(requestedAt) && requestedAt > 0) {
        request.requestedAt = Math.floor(requestedAt);
      }

      return request;
    } catch {
      return null;
    }
  }

  private async readQueuedRequest(queueDir: string): Promise<YaziRenderRequest | null> {
    const entries = await fs.readdir(queueDir).catch(() => [] as string[]);
    const jsonEntries = entries.filter((name) => /^[A-Za-z0-9._-]{8,180}\.json$/.test(name));
    if (jsonEntries.length === 0) {
      return null;
    }

    const stats = await Promise.all(
      jsonEntries.map(async (name) => {
        const fullPath = path.join(queueDir, name);
        const stat = await fs.stat(fullPath).catch(() => null);
        return {
          fullPath,
          mtimeMs: stat?.mtimeMs ?? 0,
        };
      })
    );

    stats.sort((a, b) => b.mtimeMs - a.mtimeMs);
    const keep = stats.slice(0, MAX_QUEUE_FILES);
    const overflow = stats.slice(MAX_QUEUE_FILES);
    await Promise.all(overflow.map((item) => fs.unlink(item.fullPath).catch(() => undefined)));

    for (const item of keep) {
      if (item.mtimeMs <= 0) {
        continue;
      }
      const request = await this.readRenderRequest(item.fullPath);
      await fs.unlink(item.fullPath).catch(() => undefined);
      if (request && this.isRequestFresh(request)) {
        return request;
      }
    }

    return null;
  }

  private selectPreferredRequest(
    currentRequest: YaziRenderRequest | null,
    queuedRequest: YaziRenderRequest | null
  ): YaziRenderRequest | null {
    if (currentRequest && queuedRequest) {
      const currentTs = Number(currentRequest.requestedAt ?? 0);
      const queuedTs = Number(queuedRequest.requestedAt ?? 0);
      if (Number.isFinite(currentTs) && Number.isFinite(queuedTs)) {
        return currentTs >= queuedTs ? currentRequest : queuedRequest;
      }
      return currentRequest;
    }
    return currentRequest ?? queuedRequest;
  }

  private resolveVaultFile(vaultRelativePath: string): TFile | null {
    const normalized = normalizePath(vaultRelativePath);
    const direct = this.app.vault.getAbstractFileByPath(vaultRelativePath);
    if (direct instanceof TFile) {
      return direct;
    }

    if (normalized !== vaultRelativePath) {
      const normalizedFile = this.app.vault.getAbstractFileByPath(normalized);
      if (normalizedFile instanceof TFile) {
        return normalizedFile;
      }
    }

    const targetNfc = vaultRelativePath.normalize("NFC");
    const targetNfd = vaultRelativePath.normalize("NFD");
    for (const file of this.app.vault.getMarkdownFiles()) {
      if (file.path === vaultRelativePath || file.path === normalized) {
        return file;
      }

      if (file.path.normalize("NFC") === targetNfc || file.path.normalize("NFD") === targetNfd) {
        return file;
      }
    }

    return null;
  }

  private rewriteImageEmbeds(markdown: string, sourcePath: string, imageNameIndex: Map<string, TFile[]>): string {
    const sourceDir = sourcePath.split("/").slice(0, -1).join("/");

    return markdown.replace(/!\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_all, rawTarget: string, rawSize?: string) => {
      const target = (rawTarget ?? "").trim();
      if (!target) {
        return _all;
      }

      const file = this.resolveEmbeddedImageFile(target, sourceDir, imageNameIndex);
      if (!file) {
        return _all;
      }

      const src = this.app.vault.getResourcePath(file);
      const escapedSrc = this.escapeHtmlAttr(src);
      const size = (rawSize ?? "").trim();
      if (/^\d+$/.test(size)) {
        return `<img src="${escapedSrc}" width="${size}" />`;
      }
      if (size.toLowerCase() === "full") {
        return `<img src="${escapedSrc}" style="width: 100%;" />`;
      }
      return `![](${src})`;
    });
  }

  private escapeHtmlAttr(value: string): string {
    return value
      .replace(/&/g, "&amp;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  private resolveEmbeddedImageFile(target: string, sourceDir: string, imageNameIndex: Map<string, TFile[]>): TFile | null {
    let cleaned = target.replace(/^\/+/, "");
    try {
      cleaned = decodeURIComponent(cleaned);
    } catch {
      // Keep raw target when decode fails.
    }
    const normalized = normalizePath(cleaned);
    const fromRoot = this.app.vault.getAbstractFileByPath(normalized);
    if (fromRoot instanceof TFile && this.isImageFile(fromRoot)) {
      return fromRoot;
    }

    if (sourceDir) {
      const joined = normalizePath(`${sourceDir}/${cleaned}`);
      const fromSourceDir = this.app.vault.getAbstractFileByPath(joined);
      if (fromSourceDir instanceof TFile && this.isImageFile(fromSourceDir)) {
        return fromSourceDir;
      }
    }

    const baseName = cleaned.split("/").pop() ?? "";
    if (!baseName) {
      return null;
    }

    const candidates = imageNameIndex.get(baseName) ?? [];
    if (candidates.length > 0) {
      return candidates[0];
    }

    return null;
  }

  private buildImageNameIndex(): Map<string, TFile[]> {
    const now = Date.now();
    if (this.imageNameIndexCache && now - this.imageNameIndexCachedAt < 5000) {
      return this.imageNameIndexCache;
    }

    const index = new Map<string, TFile[]>();
    for (const file of this.app.vault.getFiles()) {
      if (!this.isImageFile(file)) {
        continue;
      }
      const list = index.get(file.name);
      if (list) {
        list.push(file);
      } else {
        index.set(file.name, [file]);
      }
    }
    this.imageNameIndexCache = index;
    this.imageNameIndexCachedAt = now;
    return index;
  }

  private invalidateImageNameIndex(): void {
    this.imageNameIndexCache = null;
    this.imageNameIndexCachedAt = 0;
  }

  private isImageFile(file: TFile): boolean {
    const ext = file.extension.toLowerCase();
    return ext === "png" || ext === "jpg" || ext === "jpeg" || ext === "webp" || ext === "gif" || ext === "bmp" || ext === "svg";
  }

  private async exportFileToCache(vaultRelativePath: string, request?: YaziRenderRequest): Promise<string> {
    const existing = this.inFlight.get(vaultRelativePath);
    if (existing) {
      if (request) {
        this.pendingRequests.set(vaultRelativePath, request);
      }
      return this.withTimeout(existing, EXPORT_TIMEOUT_MS, `Export timed out at ${EXPORT_TIMEOUT_MS}ms`);
    }

    this.pendingRequests.delete(vaultRelativePath);
    const task = (async () => {
      let nextRequest: YaziRenderRequest | undefined = request;
      let outputPath = "";

      while (true) {
        outputPath = await this.exportFileToCacheImpl(vaultRelativePath, nextRequest);
        const pending = this.pendingRequests.get(vaultRelativePath);
        this.pendingRequests.delete(vaultRelativePath);
        if (!pending) {
          return outputPath;
        }
        nextRequest = pending;
      }
    })();
    this.inFlight.set(vaultRelativePath, task);

    void task.finally(() => {
      if (this.inFlight.get(vaultRelativePath) === task) {
        this.inFlight.delete(vaultRelativePath);
      }
    });

    return this.withTimeout(task, EXPORT_TIMEOUT_MS, `Export timed out at ${EXPORT_TIMEOUT_MS}ms`);
  }

  private async exportFileToCacheImpl(vaultRelativePath: string, request?: YaziRenderRequest): Promise<string> {
    const abstract = this.resolveVaultFile(vaultRelativePath);
    if (!(abstract instanceof TFile)) {
      throw new Error("Requested file was not found in the vault");
    }
    this.sweepInlineImageCache();

    const requestedWidth = Number(request?.renderWidthPx);
    const effectiveWidthPx =
      Number.isFinite(requestedWidth) && requestedWidth > 0
        ? Math.max(400, Math.min(2600, Math.floor(requestedWidth)))
        : this.settings.widthPx;
    const requestedPageHeight = Number(request?.pageHeightPx);
    const effectivePageHeightPx =
      Number.isFinite(requestedPageHeight) && requestedPageHeight > 0
        ? Math.max(300, Math.min(2600, Math.floor(requestedPageHeight)))
        : this.settings.pageHeightPx;
    const requestedTargetPage = Number(request?.targetPage);
    const effectiveTargetPage =
      Number.isFinite(requestedTargetPage) && requestedTargetPage >= 0
        ? Math.floor(requestedTargetPage)
        : 0;
    const requestedRenderProfile = this.normalizeRenderProfile(request?.renderProfile, "auto");
    const effectiveRenderProfile =
      requestedRenderProfile === "auto"
        ? this.resolveAutoRenderProfile(request?.previewCols, request?.previewRows)
        : requestedRenderProfile;
    const quickMode = Boolean(request?.quickMode) || effectiveRenderProfile === "fast";
    const requestedReadabilityZoom = Number(request?.readabilityZoom);
    const effectiveReadabilityZoom =
      Number.isFinite(requestedReadabilityZoom) && requestedReadabilityZoom > 0
        ? Math.max(0.7, Math.min(2.4, requestedReadabilityZoom))
        : 1;
    const requestedPageTallness = Number(request?.pageTallness);
    const effectivePageTallness =
      Number.isFinite(requestedPageTallness) && requestedPageTallness > 0
        ? Math.max(0.7, Math.min(2.4, requestedPageTallness))
        : 1;
    const deviceDPR = typeof window !== "undefined" ? (window.devicePixelRatio || 1) : 1;
    const basePixelRatio = quickMode
      ? Math.max(1, Math.min(1.2, this.settings.pixelRatio))
      : effectiveRenderProfile === "quality"
        ? Math.max(Math.min(this.settings.pixelRatio, 2.5), 1.9)
        : Math.min(this.settings.pixelRatio, 1.45);
    // Use device pixel ratio as minimum so images fill the pane on high-DPI displays.
    // ya.image_show only downscales, so under-sized images leave blank space.
    const effectivePixelRatio = Math.min(Math.max(basePixelRatio, deviceDPR), 2.5);
    const effectiveRenderWaitMs = quickMode
      ? Math.min(this.settings.renderWaitMs, 80)
      : effectiveRenderProfile === "quality"
        ? Math.max(this.settings.renderWaitMs, 240)
        : Math.min(this.settings.renderWaitMs, 140);
    const effectiveFrameWaitMs = quickMode ? 30 : (effectiveRenderProfile === "quality" ? 80 : 55);
    const effectiveFontWaitMs = quickMode ? 220 : (effectiveRenderProfile === "quality" ? 800 : 380);

    let markdownPrepared = false;
    let markdown = "";
    let renderedMarkdown = "";
    const ensureRenderedMarkdown = async (): Promise<string> => {
      if (markdownPrepared) {
        return renderedMarkdown;
      }

      markdown = await this.app.vault.cachedRead(abstract);
      if (markdown.includes("![[")) {
        const imageNameIndex = this.buildImageNameIndex();
        renderedMarkdown = this.rewriteImageEmbeds(markdown, abstract.path, imageNameIndex);
      } else {
        renderedMarkdown = markdown;
      }
      markdownPrepared = true;
      return renderedMarkdown;
    };
    const cacheRoot = this.resolveEffectiveCacheRoot();
    await this.ensureCacheDirs(cacheRoot);

    const computedDigest = createHash("md5").update(vaultRelativePath).digest("hex");
    const requestedDigest = request?.digest && /^[A-Za-z0-9_-]{8,128}$/.test(request.digest) ? request.digest : "";
    const digest = requestedDigest && requestedDigest === computedDigest ? requestedDigest : computedDigest;
    const digestMismatch = requestedDigest !== "" && requestedDigest !== computedDigest;
    const imgDir = path.join(cacheRoot, "img");
    const outputPath = path.join(cacheRoot, "img", `${digest}.png`);
    const debugPath = path.join(cacheRoot, "log", `${digest}.json`);
    const errorPath = path.join(cacheRoot, "log", `${digest}.error.json`);
    const colors = this.resolveColors();
    const configuredPaddingPx = Math.max(0, Number(this.settings.paddingPx) || 0);
    // Keep side padding compact so tables/content can use the preview width.
    const effectivePaddingPx = Math.min(configuredPaddingPx, Math.max(4, Math.floor(effectiveWidthPx * 0.02)));

    const debugBase: Record<string, unknown> = {
      backgroundColor: colors.backgroundColor,
      textColor: colors.textColor,
      widthPx: effectiveWidthPx,
      requestedWidthPx: Number.isFinite(requestedWidth) ? Math.floor(requestedWidth) : null,
      pageHeightPx: effectivePageHeightPx,
      requestedPageHeightPx: Number.isFinite(requestedPageHeight) ? Math.floor(requestedPageHeight) : null,
      previewCols: request?.previewCols ?? null,
      previewRows: request?.previewRows ?? null,
      requestId: request?.requestId ?? null,
      requestDigest: request?.digest ?? null,
      terminalProgram: request?.terminalProgram ?? null,
      terminalScale: request?.terminalScale ?? null,
      renderCalcBaselinePx: request?.renderCalcBaselinePx ?? null,
      renderCalcByColsPx: request?.renderCalcByColsPx ?? null,
      renderCalcAfterColsPx: request?.renderCalcAfterColsPx ?? null,
      renderCalcAfterReadabilityPx: request?.renderCalcAfterReadabilityPx ?? null,
      renderCalcAfterTerminalPx: request?.renderCalcAfterTerminalPx ?? null,
      renderCalcTmuxCapPx: request?.renderCalcTmuxCapPx ?? null,
      digestMismatch,
      targetPage: effectiveTargetPage,
      paddingPx: effectivePaddingPx,
      pixelRatio: effectivePixelRatio,
      readabilityZoom: effectiveReadabilityZoom,
      pageTallness: effectivePageTallness,
      renderProfile: effectiveRenderProfile,
      requestedRenderProfile,
      readabilityScaleMode: "font-size-with-width-compensation",
      quickMode,
      captureMode: quickMode ? "fast" : effectiveRenderProfile,
      maxHeightPx: this.settings.maxHeightPx,
    };
    if (this.settings.enableDebugLogs) {
      const includePaths = this.shouldIncludeSensitiveDebugPaths();
      const pathPayload = includePaths
        ? {
            path: vaultRelativePath,
            resolvedPath: abstract.path,
            requestPath: request?.path ?? null,
          }
        : {
            path: "<redacted>",
            resolvedPath: "<redacted>",
            requestPath: request?.path ? "<redacted>" : null,
          };
      Object.assign(debugBase, {
        ...pathPayload,
        markdownLength: null,
        markdownOriginalLength: null,
        markdownPrepared: false,
      });
    }
    let stage = "prepare-host";
    const startedAtIso = new Date().toISOString();
    const statusBase = {
      path: vaultRelativePath,
      digest,
      requestId: request?.requestId ?? null,
      quickMode,
      renderProfile: effectiveRenderProfile,
    };
    const reportStage = async (nextStage: string, extra: Record<string, unknown> = {}): Promise<void> => {
      stage = nextStage;
      await this.writeRenderStatus(cacheRoot, digest, {
        ...statusBase,
        state: "running",
        stage: nextStage,
        startedAt: startedAtIso,
        ...extra,
      });
    };

    const host = document.createElement("div");
    host.className = "yazi-exporter-render-host markdown-preview-view markdown-rendered";
    host.style.position = "fixed";
    host.style.left = "0";
    host.style.top = "0";
    host.style.width = `${effectiveWidthPx}px`;
    host.style.maxWidth = `${effectiveWidthPx}px`;
    host.style.paddingTop = "0";
    host.style.paddingBottom = `${effectivePaddingPx}px`;
    host.style.paddingLeft = `${effectivePaddingPx}px`;
    host.style.paddingRight = `${effectivePaddingPx}px`;
    host.style.background = colors.backgroundColor;
    host.style.color = colors.textColor;
    host.style.zIndex = "1";
    host.style.pointerEvents = "none";
    this.applyTypographyFix(host);
    this.applyReadabilityTuning(host, effectiveReadabilityZoom, effectiveWidthPx);

    document.body.appendChild(host);

    const component = new Component();
    component.load();

    try {
      await reportStage("prepare-host");

      if (this.settings.enableDebugLogs) {
        await fs
          .writeFile(
            debugPath,
            JSON.stringify(
              {
                ...debugBase,
                at: new Date().toISOString(),
                stage: "begin",
              },
              null,
              2
            )
          )
          .catch(() => undefined);
      }

      await reportStage("render-markdown");
      const usedLiveView = this.cloneLivePreview(host, vaultRelativePath);
      debugBase.usedLiveView = usedLiveView;
      if (!usedLiveView) {
        const markdownForRender = await ensureRenderedMarkdown();
        try {
          await this.withTimeout(
            MarkdownRenderer.render(this.app, markdownForRender, host, vaultRelativePath, component),
            RENDER_TIMEOUT_MS,
            `Markdown render timed out at ${RENDER_TIMEOUT_MS}ms`
          );
        } catch (error) {
          const renderError =
            error instanceof Error
              ? { name: error.name, message: error.message, stack: error.stack ?? null }
              : { message: String(error) };
          debugBase.renderError = renderError;
          host.innerHTML = "";
          this.ensureRenderableFallback(host, markdownForRender);
        }
      }

      await reportStage("wait-stability");
      await this.waitForRenderStability(host, effectiveRenderWaitMs, effectiveFrameWaitMs);
      this.ensureRenderableFallback(host, markdownPrepared ? renderedMarkdown : "");
      await this.waitForFonts(effectiveFontWaitMs);

      if (this.settings.enableDebugLogs) {
        const firstParagraph = host.querySelector("p, li, h1, h2, h3, h4, h5, h6") as HTMLElement | null;
        const firstParagraphStyle = firstParagraph ? getComputedStyle(firstParagraph) : null;
        const firstBodyParagraph = host.querySelector("p, li") as HTMLElement | null;
        const firstBodyParagraphStyle = firstBodyParagraph ? getComputedStyle(firstBodyParagraph) : null;
        const firstImage = host.querySelector("img") as HTMLImageElement | null;
        Object.assign(debugBase, {
          markdownPrepared,
          markdownLength: markdownPrepared ? renderedMarkdown.length : null,
          markdownOriginalLength: markdownPrepared ? markdown.length : null,
          innerHtmlLength: host.innerHTML.length,
          textLength: (host.textContent ?? "").trim().length,
          childElementCount: host.childElementCount,
          firstParagraphTextLength: firstParagraph?.textContent?.trim().length ?? null,
          firstParagraphLetterSpacing: firstParagraphStyle?.letterSpacing ?? null,
          firstParagraphWordSpacing: firstParagraphStyle?.wordSpacing ?? null,
          firstParagraphTextAlign: firstParagraphStyle?.textAlign ?? null,
          firstParagraphTextJustify: firstParagraphStyle
            ? ((firstParagraphStyle as CSSStyleDeclaration & { textJustify?: string }).textJustify ?? null)
            : null,
          firstParagraphFontFamily: firstParagraphStyle?.fontFamily ?? null,
          firstParagraphFontSize: firstParagraphStyle?.fontSize ?? null,
          firstBodyParagraphTextLength: firstBodyParagraph?.textContent?.trim().length ?? null,
          firstBodyParagraphLetterSpacing: firstBodyParagraphStyle?.letterSpacing ?? null,
          firstBodyParagraphWordSpacing: firstBodyParagraphStyle?.wordSpacing ?? null,
          firstBodyParagraphTextAlign: firstBodyParagraphStyle?.textAlign ?? null,
          firstBodyParagraphTextJustify: firstBodyParagraphStyle
            ? ((firstBodyParagraphStyle as CSSStyleDeclaration & { textJustify?: string }).textJustify ?? null)
            : null,
          firstBodyParagraphFontFamily: firstBodyParagraphStyle?.fontFamily ?? null,
          firstImageSrc: firstImage?.getAttribute("src") ?? null,
          firstImageResolvedSrc: firstImage?.src ?? null,
          firstImageComplete: firstImage?.complete ?? null,
          firstImageNaturalWidth: firstImage?.naturalWidth ?? null,
          firstImageNaturalHeight: firstImage?.naturalHeight ?? null,
          scrollHeight: host.scrollHeight,
          scrollWidth: host.scrollWidth,
        });
      }

      stage = "write-debug-pre-canvas";
      if (this.settings.enableDebugLogs) {
        await fs.writeFile(
          debugPath,
          JSON.stringify(
            { ...debugBase, at: new Date().toISOString(), stage },
            null,
            2
          )
        );
      }

      await reportStage("inline-images");
      const imageCount = host.querySelectorAll("img").length;
      const inlineLimit = quickMode ? 2 : (effectiveRenderProfile === "quality" ? 6 : 3);
      if (imageCount > 0 && imageCount <= 24) {
        await this.inlineLoadedImages(host, inlineLimit);
      }

      await reportStage("capture-canvas");
      const visualRect = host.getBoundingClientRect();
      const sourceWidth = Math.max(1, Math.ceil(Math.max(host.scrollWidth, visualRect.width)));
      const sourceHeight = Math.max(1, Math.ceil(Math.max(host.scrollHeight, visualRect.height)));
      const configuredMaxHeight = Number.isFinite(this.settings.maxHeightPx) ? Math.floor(this.settings.maxHeightPx) : 0;
      const sourceHeightLimit =
        configuredMaxHeight > 0
          ? Math.min(sourceHeight, Math.max(1000, configuredMaxHeight))
          : sourceHeight;
      let captureHeight = sourceHeightLimit;
      let requestedScale = Math.max(1, Math.min(3, effectivePixelRatio));
      const sourcePixels = Math.max(1, sourceWidth * sourceHeightLimit);
      if (!quickMode && effectiveRenderProfile !== "quality") {
        if (sourcePixels > 18_000_000) {
          requestedScale = Math.min(requestedScale, 1.18);
        } else if (sourcePixels > 12_000_000) {
          requestedScale = Math.min(requestedScale, 1.24);
        }
      }
      const scaleByBytes = Math.sqrt(
        MAX_CANVAS_BYTES / Math.max(1, sourceWidth * captureHeight * 4)
      );
      const scaleByWidthEdge = MAX_CANVAS_EDGE / Math.max(1, sourceWidth);
      const scaleByHeightEdge = MAX_CANVAS_EDGE / Math.max(1, captureHeight);
      let appliedScale = Math.min(requestedScale, scaleByBytes, scaleByWidthEdge, scaleByHeightEdge);
      let clippedBySafety = false;
      if (!Number.isFinite(appliedScale) || appliedScale <= 0) {
        appliedScale = requestedScale;
      }

      if (appliedScale < MIN_CAPTURE_SCALE) {
        appliedScale = MIN_CAPTURE_SCALE;
        const maxHeightByBytes = Math.floor(
          MAX_CANVAS_BYTES / Math.max(1, sourceWidth * appliedScale * appliedScale * 4)
        );
        const maxHeightByEdge = Math.floor(MAX_CANVAS_EDGE / Math.max(1, appliedScale));
        const safetyHeightLimit = Math.max(1000, Math.min(maxHeightByBytes, maxHeightByEdge));
        if (captureHeight > safetyHeightLimit) {
          captureHeight = safetyHeightLimit;
          clippedBySafety = sourceHeightLimit > captureHeight;
        }
      }
      const clippedByMaxHeight = sourceHeightLimit < sourceHeight;

      host.style.height = `${captureHeight}px`;
      host.style.overflow = "hidden";

      Object.assign(debugBase, {
        renderer: "html2canvas-full",
        sourceWidth,
        sourceHeight,
        sourceHeightLimit,
        captureHeight,
        requestedScale,
        appliedScale,
        scaleByBytes,
        scaleByWidthEdge,
        scaleByHeightEdge,
        clippedByMaxHeight,
        clippedBySafety,
      });

      const preferForeignObject = this.shouldPreferForeignObjectRendering(host, quickMode, effectiveRenderProfile);
      debugBase.preferForeignObject = preferForeignObject;
      let canvas: HTMLCanvasElement;
      try {
        canvas = await this.withTimeout(
          html2canvas(host, {
            backgroundColor: colors.backgroundColor,
            scale: appliedScale,
            useCORS: true,
            foreignObjectRendering: preferForeignObject,
            logging: false,
            windowWidth: sourceWidth,
            windowHeight: captureHeight,
          }),
          CAPTURE_TIMEOUT_MS,
          `Canvas capture timed out at ${CAPTURE_TIMEOUT_MS}ms`
        );
      } catch (firstCaptureError) {
        if (!preferForeignObject) {
          throw firstCaptureError;
        }
        await reportStage("capture-canvas-fallback");
        debugBase.captureFallback = "foreignObject=false";
        canvas = await this.withTimeout(
          html2canvas(host, {
            backgroundColor: colors.backgroundColor,
            scale: appliedScale,
            useCORS: true,
            foreignObjectRendering: false,
            logging: false,
            windowWidth: sourceWidth,
            windowHeight: captureHeight,
          }),
          CAPTURE_TIMEOUT_MS,
          `Canvas capture timed out at ${CAPTURE_TIMEOUT_MS}ms`
        );
      }

      if (canvas.width <= 1 || canvas.height <= 1) {
        throw new Error("Canvas size is invalid");
      }

      Object.assign(debugBase, {
        canvasWidth: canvas.width,
        canvasHeight: canvas.height,
      });

      await reportStage("write-pages");
      const pageHeight = Math.max(240, Math.floor(effectivePageHeightPx * appliedScale));
      const pageCount = Math.max(1, Math.ceil(canvas.height / pageHeight));
      const targetPage = Math.max(0, Math.min(pageCount - 1, effectiveTargetPage));
      // For smooth page navigation in yazi, normal (non-quick) renders keep all pages cached.
      const writeAllPages = !quickMode;
      const pageWriteRadius = quickMode ? 2 : (effectiveRenderProfile === "quality" ? 4 : 3);
      const keepPages = writeAllPages
        ? this.computeAllPages(pageCount)
        : this.computePagesToWrite(pageCount, targetPage, pageWriteRadius);
      await this.cleanupTempPageImages(imgDir, digest);
      const baseTempPath = `${outputPath}.tmp`;
      const pageTempPaths = new Map<number, string>();
      const pageIndexes = Array.from(keepPages.values()).sort((a, b) => a - b);

      for (const i of pageIndexes) {
        const y = i * pageHeight;
        const h = Math.min(pageHeight, canvas.height - y);
        const pageCanvas = document.createElement("canvas");
        pageCanvas.width = canvas.width;
        pageCanvas.height = h;

        const ctx = pageCanvas.getContext("2d");
        if (!ctx) {
          throw new Error("Failed to acquire 2D context for page canvas");
        }
        ctx.drawImage(canvas, 0, y, canvas.width, h, 0, 0, canvas.width, h);

        const pageDataUrl = pageCanvas.toDataURL("image/png");
        if (!pageDataUrl.startsWith("data:image/png;base64,")) {
          throw new Error(`Canvas export failed at page ${i + 1}/${pageCount}`);
        }
        const pageBuffer = Buffer.from(pageDataUrl.replace(/^data:image\/png;base64,/, ""), "base64");
        const pageTempPath = path.join(imgDir, `${digest}--tmp-p${String(i).padStart(4, "0")}.png`);
        await fs.writeFile(pageTempPath, pageBuffer);
        pageTempPaths.set(i, pageTempPath);

        if (i === 0) {
          await fs.writeFile(baseTempPath, pageBuffer);
        }
      }

      if (!pageTempPaths.has(0)) {
        throw new Error("Page 0 was not generated.");
      }

      for (const i of pageIndexes) {
        const tempPath = pageTempPaths.get(i);
        if (!tempPath) {
          continue;
        }
        const finalPagePath = path.join(imgDir, `${digest}--p${String(i).padStart(4, "0")}.png`);
        await fs.rename(tempPath, finalPagePath);
      }

      await fs.rename(baseTempPath, outputPath);
      await this.cleanupObsoletePageImages(imgDir, digest, pageCount, keepPages);

      await reportStage("write-meta");
      const metaPath = path.join(imgDir, `${digest}.meta.json`);
      const metaTempPath = `${metaPath}.tmp`;
      await fs.writeFile(
        metaTempPath,
        JSON.stringify(
          {
            pageCount,
            renderWidthPx: effectiveWidthPx,
            previewCols: request?.previewCols ?? null,
            previewRows: request?.previewRows ?? null,
            requestId: request?.requestId ?? null,
            requestDigest: request?.digest ?? null,
            terminalProgram: request?.terminalProgram ?? null,
            terminalScale: request?.terminalScale ?? null,
            renderCalcBaselinePx: request?.renderCalcBaselinePx ?? null,
            renderCalcByColsPx: request?.renderCalcByColsPx ?? null,
            renderCalcAfterColsPx: request?.renderCalcAfterColsPx ?? null,
            renderCalcAfterReadabilityPx: request?.renderCalcAfterReadabilityPx ?? null,
            renderCalcAfterTerminalPx: request?.renderCalcAfterTerminalPx ?? null,
            renderCalcTmuxCapPx: request?.renderCalcTmuxCapPx ?? null,
            requestedAt: request?.requestedAt ?? null,
            targetPage,
            writeAllPages,
            generatedPages: pageIndexes,
            pageHeightPx: effectivePageHeightPx,
            captureScale: appliedScale,
            clippedByMaxHeight,
            clippedBySafety,
            readabilityZoom: effectiveReadabilityZoom,
            pageTallness: effectivePageTallness,
            renderProfile: effectiveRenderProfile,
            generatedAt: new Date().toISOString(),
          },
          null,
          2
        )
      );
      await fs.rename(metaTempPath, metaPath);

      stage = "write-debug-final";
      if (this.settings.enableDebugLogs) {
        await fs.writeFile(
          debugPath,
          JSON.stringify(
            { ...debugBase, at: new Date().toISOString(), stage: "done", pageCount, pageHeight },
            null,
            2
          )
        );
      }

      await this.writeRenderStatus(cacheRoot, digest, {
        ...statusBase,
        state: "done",
        stage: "done",
        startedAt: startedAtIso,
        finishedAt: new Date().toISOString(),
        pageCount,
        captureScale: appliedScale,
        clippedByMaxHeight,
        clippedBySafety,
      });

      await fs.unlink(errorPath).catch(() => undefined);
      return outputPath;
    } catch (error) {
      const serializedError =
        error instanceof Error
          ? {
              name: error.name,
              message: this.settings.enableDebugLogs ? error.message : "export failed",
              stack: this.settings.enableDebugLogs ? (error.stack ?? null) : null,
            }
          : { message: this.settings.enableDebugLogs ? String(error) : "export failed" };

      await fs
        .writeFile(
          errorPath,
          JSON.stringify(
            {
              ...debugBase,
              at: new Date().toISOString(),
              stage,
              error: serializedError,
            },
            null,
            2
          )
        )
        .catch(() => undefined);

      await this.writeRenderStatus(cacheRoot, digest, {
        ...statusBase,
        state: "error",
        stage,
        startedAt: startedAtIso,
        finishedAt: new Date().toISOString(),
        error: serializedError,
      });
      throw error;
    } finally {
      component.unload();
      host.remove();
    }
  }

  private ensureSafeCacheRoot(cacheRoot: string): string {
    const raw = String(cacheRoot ?? "").trim();
    if (!raw) {
      throw new Error("Unsafe cache directory: empty path");
    }
    if (raw.includes("\0")) {
      throw new Error("Unsafe cache directory: contains NUL byte");
    }
    if (!path.isAbsolute(raw)) {
      throw new Error(`Unsafe cache directory: must be absolute (${raw})`);
    }

    const resolved = path.resolve(raw);
    const normalized = path.normalize(resolved);
    const fsRoot = path.parse(normalized).root;
    const homeRoot = path.resolve(homedir());
    if (normalized === fsRoot || normalized === homeRoot) {
      throw new Error(`Unsafe cache directory: ${normalized}`);
    }
    return normalized;
  }

  public validateCacheRoot(value: string): string {
    return this.ensureSafeCacheRoot(this.expandPath(value));
  }

  private resolveEffectiveCacheRoot(): string {
    const envOverride = process.env[CACHE_ROOT_ENV_VAR]?.trim();
    const configured = envOverride && envOverride.length > 0 ? envOverride : this.settings.cacheDir;
    return this.ensureSafeCacheRoot(this.expandPath(configured));
  }

  private async ensureCacheDirs(cacheRoot: string): Promise<void> {
    const safeRoot = this.ensureSafeCacheRoot(cacheRoot);
    const dirs = [
      safeRoot,
      path.join(safeRoot, "img"),
      path.join(safeRoot, "mode"),
      path.join(safeRoot, "locks"),
      path.join(safeRoot, "log"),
      path.join(safeRoot, "requests"),
      path.join(safeRoot, "requests", "queue"),
    ];

    for (const dir of dirs) {
      await fs.mkdir(dir, { recursive: true, mode: 0o700 });
    }

    if (process.platform !== "win32") {
      for (const dir of dirs) {
        await fs.chmod(dir, 0o700);
      }
    }

    const sentinelPath = path.join(safeRoot, ".obsidian-yazi-cache");
    await fs.writeFile(sentinelPath, "obsidian-yazi-cache\n", { mode: 0o600 });
    if (process.platform !== "win32") {
      await fs.chmod(sentinelPath, 0o600);
    }
  }

  private computePagesToWrite(pageCount: number, targetPage: number, radius: number): Set<number> {
    const keep = new Set<number>();
    keep.add(0);
    const clampedTarget = Math.max(0, Math.min(pageCount - 1, Math.floor(targetPage)));
    keep.add(clampedTarget);

    const safeRadius = Math.max(0, Math.floor(radius));
    for (let i = 1; i <= safeRadius; i += 1) {
      const prev = clampedTarget - i;
      const next = clampedTarget + i;
      if (prev >= 0) {
        keep.add(prev);
      }
      if (next < pageCount) {
        keep.add(next);
      }
    }

    return keep;
  }

  private computeAllPages(pageCount: number): Set<number> {
    const keep = new Set<number>();
    const total = Math.max(0, Math.floor(pageCount));
    for (let i = 0; i < total; i += 1) {
      keep.add(i);
    }
    return keep;
  }

  private async cleanupObsoletePageImages(
    imgDir: string,
    digest: string,
    validPageCount: number,
    keepPages?: Set<number>
  ): Promise<void> {
    const files = await fs.readdir(imgDir).catch(() => []);
    const pagePattern = new RegExp(`^${digest}--p(\\d{4})\\.png$`);
    const tempPrefix = `${digest}--tmp-p`;

    await Promise.all(
      files.map(async (name) => {
        if (name.startsWith(tempPrefix) && name.endsWith(".png")) {
          await fs.unlink(path.join(imgDir, name)).catch(() => undefined);
          return;
        }

        const match = name.match(pagePattern);
        if (!match) {
          return;
        }

        const index = Number(match[1]);
        if (Number.isFinite(index) && index >= validPageCount) {
          await fs.unlink(path.join(imgDir, name)).catch(() => undefined);
          return;
        }

        if (Number.isFinite(index) && keepPages && !keepPages.has(index)) {
          await fs.unlink(path.join(imgDir, name)).catch(() => undefined);
        }
      })
    );
  }

  private async cleanupTempPageImages(imgDir: string, digest: string): Promise<void> {
    const files = await fs.readdir(imgDir).catch(() => []);
    const tempPrefix = `${digest}--tmp-p`;

    await Promise.all(
      files
        .filter((name) => name.startsWith(tempPrefix) && name.endsWith(".png"))
        .map((name) => fs.unlink(path.join(imgDir, name)).catch(() => undefined))
    );
  }

  private statusFilePath(cacheRoot: string, digest: string): string {
    return path.join(cacheRoot, "log", `${digest}.status.json`);
  }

  private async writeRenderStatus(cacheRoot: string, digest: string, payload: Record<string, unknown>): Promise<void> {
    const statusPath = this.statusFilePath(cacheRoot, digest);
    const tempPath = `${statusPath}.tmp`;
    const content = JSON.stringify(
      {
        ...payload,
        updatedAt: new Date().toISOString(),
      },
      null,
      2
    );

    await fs
      .writeFile(tempPath, content)
      .then(() => fs.rename(tempPath, statusPath))
      .catch(async () => {
        await fs.writeFile(statusPath, content).catch(() => undefined);
        await fs.unlink(tempPath).catch(() => undefined);
      });
  }

  private expandPath(value: string): string {
    if (value.startsWith("~/")) {
      return path.join(homedir(), value.slice(2));
    }
    return value;
  }

  private resolveColors(): { backgroundColor: string; textColor: string } {
    if (this.settings.forceCustomColors) {
      return {
        backgroundColor: this.settings.backgroundColor,
        textColor: this.settings.textColor,
      };
    }

    const computed = getComputedStyle(document.body);
    const background = computed.getPropertyValue("--background-primary").trim();
    const text = computed.getPropertyValue("--text-normal").trim();

    return {
      backgroundColor: background || this.settings.backgroundColor,
      textColor: text || this.settings.textColor,
    };
  }

  private applyTypographyFix(host: HTMLDivElement): void {
    const bodyStyles = getComputedStyle(document.body);
    const textFont = bodyStyles.getPropertyValue("--font-text").trim();
    if (textFont) {
      host.style.fontFamily = textFont;
    }
    host.style.textAlign = "left";
    host.style.letterSpacing = "normal";
    host.style.wordSpacing = "normal";

    const style = document.createElement("style");
    style.textContent = `
.yazi-exporter-render-host,
.yazi-exporter-render-host .markdown-preview-sizer,
.yazi-exporter-render-host .markdown-preview-view {
  text-align: left !important;
  text-justify: auto !important;
}

.yazi-exporter-render-host .markdown-preview-sizer,
.yazi-exporter-render-host .markdown-preview-view.markdown-rendered {
  width: 100% !important;
  max-width: 750px !important;
  margin-left: auto !important;
  margin-right: auto !important;
  padding-left: 0 !important;
  padding-right: 0 !important;
  padding-top: 0 !important;
  margin-top: 0 !important;
}

.yazi-exporter-render-host > .markdown-preview-sizer > div:first-child,
.yazi-exporter-render-host > div:first-child {
  margin-top: 0 !important;
  padding-top: 0 !important;
}

.yazi-exporter-render-host .markdown-rendered {
  --file-line-width: 750px !important;
  --line-width: 750px !important;
}

.yazi-exporter-render-host p,
.yazi-exporter-render-host li,
.yazi-exporter-render-host blockquote,
.yazi-exporter-render-host td,
.yazi-exporter-render-host th,
.yazi-exporter-render-host h1,
.yazi-exporter-render-host h2,
.yazi-exporter-render-host h3,
.yazi-exporter-render-host h4,
.yazi-exporter-render-host h5,
.yazi-exporter-render-host h6,
.yazi-exporter-render-host span,
.yazi-exporter-render-host a,
.yazi-exporter-render-host strong,
.yazi-exporter-render-host em,
.yazi-exporter-render-host small {
  text-align: left !important;
  text-justify: auto !important;
  letter-spacing: normal !important;
  word-spacing: normal !important;
  font-kerning: normal !important;
}

.yazi-exporter-render-host code,
.yazi-exporter-render-host pre {
  letter-spacing: normal !important;
  word-spacing: normal !important;
}

.yazi-exporter-render-host table {
  width: 100% !important;
  max-width: 100% !important;
}

.yazi-exporter-render-host .table-wrapper {
  width: 100% !important;
  max-width: none !important;
  margin-left: 0 !important;
  margin-right: 0 !important;
}

.yazi-exporter-render-host .table-wrapper > table,
.yazi-exporter-render-host table.markdown-table {
  width: 100% !important;
  max-width: 100% !important;
}

.yazi-exporter-render-host .metadata-container,
.yazi-exporter-render-host .frontmatter-container,
.yazi-exporter-render-host .mod-header,
.yazi-exporter-render-host .metadata-properties-heading,
.yazi-exporter-render-host .metadata-properties {
  display: none !important;
  height: 0 !important;
  margin: 0 !important;
  padding: 0 !important;
  overflow: hidden !important;
}
	`;
    host.appendChild(style);
  }

  private shouldPreferForeignObjectRendering(host: HTMLDivElement, quickMode: boolean, profile: RenderProfile): boolean {
    if (!quickMode) {
      return true;
    }
    if (profile === "quality") {
      return true;
    }

    const textSample = (host.textContent ?? "").slice(0, 12_000);
    if (textSample.length === 0) {
      return false;
    }
    return CJK_TEXT_RE.test(textSample);
  }

  private applyReadabilityTuning(host: HTMLDivElement, zoomRaw: number, baseWidthPx: number): void {
    const zoom = Number.isFinite(zoomRaw) ? Math.max(0.7, Math.min(2.4, zoomRaw)) : 1;
    if (Math.abs(zoom - 1) < 0.001) {
      return;
    }

    const boostedZoom = zoom >= 1 ? 1 + (zoom - 1) * 1.35 : 1 - (1 - zoom) * 0.95;
    const visualZoom = Math.max(0.55, Math.min(2.6, boostedZoom));
    const safeBaseWidth = Math.max(400, Math.floor(baseWidthPx));
    // Keep final composition width close to the pane while still making text size visibly change.
    const compensationFactor = visualZoom < 1
      ? Math.min(Math.pow(1 / visualZoom, 0.70), 1.35)
      : Math.max(0.85, 1 / Math.pow(visualZoom, 0.45));
    const compensatedWidth = Math.max(300, Math.floor(safeBaseWidth * compensationFactor));
    host.style.width = `${compensatedWidth}px`;
    host.style.maxWidth = `${compensatedWidth}px`;
    host.style.removeProperty("zoom");
    host.style.transform = "";
    host.style.transformOrigin = "";
    host.style.fontSize = `${(visualZoom * 100).toFixed(1)}%`;
  }

  private cloneLivePreview(host: HTMLDivElement, vaultRelativePath: string): boolean {
    const activeFile = this.app.workspace.getActiveFile();
    if (!activeFile || activeFile.path !== vaultRelativePath) {
      return false;
    }

    const markdownView = this.app.workspace.getActiveViewOfType(MarkdownView);
    if (!markdownView || markdownView.getMode() !== "preview") {
      return false;
    }

    const previewContainer = markdownView?.previewMode?.containerEl;
    if (!previewContainer) {
      return false;
    }

    const liveRoot =
      (previewContainer.querySelector(".markdown-preview-sizer") as HTMLElement | null) ??
      (previewContainer.querySelector(".markdown-preview-view.markdown-rendered") as HTMLElement | null) ??
      previewContainer;
    const liveText = (liveRoot.textContent ?? "").trim();
    const liveRenderable = liveRoot.querySelector("img,svg,canvas,video,iframe,table,pre,code,blockquote,ul,ol,p,h1,h2,h3,h4,h5,h6,math");
    if (liveText.length === 0 && !liveRenderable) {
      return false;
    }

    const clone = liveRoot.cloneNode(true) as HTMLElement;

    clone.querySelectorAll(".mod-header").forEach((el) => el.remove());
    clone.style.width = "100%";
    clone.style.maxWidth = "none";
    clone.style.margin = "0";

    host.appendChild(clone);
    return true;
  }

  private async withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
    let timer: number | null = null;
    try {
      return await Promise.race([
        promise,
        new Promise<T>((_, reject) => {
          timer = window.setTimeout(() => reject(new Error(message)), timeoutMs);
        }),
      ]);
    } finally {
      if (timer !== null) {
        window.clearTimeout(timer);
      }
    }
  }

  private approximateDataUrlBytes(dataUrl: string): number {
    return Math.max(0, Math.floor(dataUrl.length * 0.75));
  }

  private evictInlineImageCacheToLimit(maxBytes = INLINE_IMAGE_CACHE_MAX_BYTES): void {
    if (this.inlineImageCacheBytes <= maxBytes) {
      return;
    }

    const ordered = Array.from(this.inlineImageCache.entries()).sort((a, b) => a[1].at - b[1].at);
    for (const [cacheKey, value] of ordered) {
      this.inlineImageCache.delete(cacheKey);
      this.inlineImageCacheBytes = Math.max(0, this.inlineImageCacheBytes - value.approxBytes);
      if (this.inlineImageCacheBytes <= maxBytes) {
        break;
      }
    }
  }

  private sweepInlineImageCache(now = Date.now()): void {
    if (this.inlineImageCache.size === 0) {
      return;
    }

    for (const [cacheKey, value] of this.inlineImageCache.entries()) {
      if ((now - value.at) > INLINE_IMAGE_CACHE_TTL_MS) {
        this.inlineImageCache.delete(cacheKey);
        this.inlineImageCacheBytes = Math.max(0, this.inlineImageCacheBytes - value.approxBytes);
      }
    }

    this.evictInlineImageCacheToLimit(INLINE_IMAGE_CACHE_MAX_BYTES);
  }

  private touchInlineImageCache(key: string): { dataUrl: string; approxBytes: number; at: number } | null {
    const cached = this.inlineImageCache.get(key);
    if (!cached) {
      return null;
    }
    if ((Date.now() - cached.at) > INLINE_IMAGE_CACHE_TTL_MS) {
      this.inlineImageCache.delete(key);
      this.inlineImageCacheBytes = Math.max(0, this.inlineImageCacheBytes - cached.approxBytes);
      return null;
    }
    cached.at = Date.now();
    this.inlineImageCache.set(key, cached);
    return cached;
  }

  private storeInlineImageCache(key: string, dataUrl: string): void {
    const approxBytes = this.approximateDataUrlBytes(dataUrl);
    if (approxBytes <= 0 || approxBytes > INLINE_IMAGE_CACHE_MAX_BYTES) {
      return;
    }

    const existing = this.inlineImageCache.get(key);
    if (existing) {
      this.inlineImageCacheBytes = Math.max(0, this.inlineImageCacheBytes - existing.approxBytes);
      this.inlineImageCache.delete(key);
    }

    this.inlineImageCache.set(key, { dataUrl, approxBytes, at: Date.now() });
    this.inlineImageCacheBytes += approxBytes;
    this.evictInlineImageCacheToLimit(INLINE_IMAGE_CACHE_MAX_BYTES);
  }

  private async inlineLoadedImages(host: HTMLDivElement, maxImages?: number): Promise<void> {
    const images = Array.from(host.querySelectorAll("img")) as HTMLImageElement[];
    const limit = Number.isFinite(Number(maxImages)) && Number(maxImages) > 0
      ? Math.floor(Number(maxImages))
      : Number.POSITIVE_INFINITY;
    let processed = 0;
    for (const image of images) {
      if (processed >= limit) {
        break;
      }
      const src = image.getAttribute("src") ?? "";
      if (!(src.startsWith("app://") || src.startsWith("file://"))) {
        continue;
      }
      if (!image.complete || image.naturalWidth <= 0 || image.naturalHeight <= 0) {
        continue;
      }

      try {
        const originalWidth = image.naturalWidth;
        const originalHeight = image.naturalHeight;
        const originalPixels = originalWidth * originalHeight;
        let targetWidth = originalWidth;
        let targetHeight = originalHeight;

        if (originalWidth > MAX_INLINE_IMAGE_EDGE || originalHeight > MAX_INLINE_IMAGE_EDGE || originalPixels > MAX_INLINE_IMAGE_PIXELS) {
          const edgeScale = Math.min(MAX_INLINE_IMAGE_EDGE / originalWidth, MAX_INLINE_IMAGE_EDGE / originalHeight, 1);
          const pixelScale = Math.min(Math.sqrt(MAX_INLINE_IMAGE_PIXELS / Math.max(1, originalPixels)), 1);
          const finalScale = Math.min(edgeScale, pixelScale);
          targetWidth = Math.max(1, Math.floor(originalWidth * finalScale));
          targetHeight = Math.max(1, Math.floor(originalHeight * finalScale));
        }

        const cacheKey = `${src}|${targetWidth}x${targetHeight}`;
        const cached = this.touchInlineImageCache(cacheKey);
        if (cached) {
          image.setAttribute("data-yazi-original-src", src);
          image.setAttribute("src", cached.dataUrl);
          processed += 1;
          continue;
        }

        const canvas = document.createElement("canvas");
        canvas.width = targetWidth;
        canvas.height = targetHeight;
        const ctx = canvas.getContext("2d");
        if (!ctx) {
          continue;
        }

        ctx.drawImage(image, 0, 0, targetWidth, targetHeight);
        const dataUrl = canvas.toDataURL("image/png");
        if (!dataUrl.startsWith("data:image/")) {
          continue;
        }

        this.storeInlineImageCache(cacheKey, dataUrl);
        image.setAttribute("data-yazi-original-src", src);
        image.setAttribute("src", dataUrl);
        processed += 1;
      } catch {
        // Skip images that cannot be rasterized.
      }
    }
  }

  private captureRenderState(host: HTMLDivElement): string {
    const pendingImages = Array.from(host.querySelectorAll("img")).filter((node) => {
      const image = node as HTMLImageElement;
      return !image.complete || image.naturalWidth <= 0 || image.naturalHeight <= 0;
    }).length;
    const rect = host.getBoundingClientRect();
    const scrollWidth = Math.ceil(host.scrollWidth);
    const scrollHeight = Math.ceil(host.scrollHeight);
    const visualWidth = Math.ceil(rect.width);
    const visualHeight = Math.ceil(rect.height);
    const childCount = host.childElementCount;
    return `${scrollWidth}x${scrollHeight}|${visualWidth}x${visualHeight}|${childCount}|${pendingImages}`;
  }

  private async waitForRenderStability(
    host: HTMLDivElement,
    renderWaitMs = this.settings.renderWaitMs,
    frameWaitMs = 80
  ): Promise<void> {
    const maxWaitMs = Math.max(80, renderWaitMs);
    const startedAt = Date.now();
    const maxProbes = Math.max(2, Math.ceil(maxWaitMs / Math.max(16, frameWaitMs)));
    let previousState = "";
    let stableCount = 0;

    for (let probe = 0; probe < maxProbes; probe += 1) {
      await this.waitFrameOrTimeout(frameWaitMs);
      const state = this.captureRenderState(host);

      if (state === previousState) {
        stableCount += 1;
      } else {
        stableCount = 0;
      }

      previousState = state;

      if (stableCount >= 1 && (Date.now() - startedAt) >= Math.min(60, maxWaitMs)) {
        return;
      }
    }
  }

  private async waitFrameOrTimeout(timeoutMs: number): Promise<void> {
    await Promise.race([
      new Promise<void>((resolve) => requestAnimationFrame(() => resolve())),
      new Promise<void>((resolve) => setTimeout(resolve, timeoutMs)),
    ]);
  }

  private async waitForFonts(maxWaitMs = 1200): Promise<void> {
    try {
      const fonts = (document as Document & { fonts?: { ready?: Promise<unknown> } }).fonts;
      if (fonts?.ready) {
        await Promise.race([
          fonts.ready,
          new Promise((resolve) => setTimeout(resolve, maxWaitMs)),
        ]);
      }
    } catch {
      // no-op
    }
  }

  private ensureRenderableFallback(host: HTMLDivElement, markdown: string): void {
    const text = host.textContent?.trim() ?? "";
    const hasRenderable = Boolean(
      host.querySelector("img,svg,canvas,video,iframe,table,pre,code,blockquote,ul,ol,p,h1,h2,h3,h4,h5,h6,math")
    );

    if (text.length > 0 || hasRenderable) {
      return;
    }

    const fallback = document.createElement("pre");
    fallback.textContent = markdown.slice(0, 20000);
    fallback.style.whiteSpace = "pre-wrap";
    fallback.style.wordBreak = "break-word";
    fallback.style.fontFamily = "var(--font-monospace)";
    fallback.style.lineHeight = "1.5";
    host.appendChild(fallback);
  }
}

class YaziExporterSettingTab extends PluginSettingTab {
  plugin: YaziExporterPlugin;

  constructor(app: App, plugin: YaziExporterPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();

    containerEl.createEl("h2", { text: "Yazi Exporter" });

    new Setting(containerEl)
      .setName("Cache directory")
      .setDesc("PNG cache output directory (outside Vault recommended, absolute path required). If OBSIDIAN_YAZI_CACHE is set in Obsidian's environment, it overrides this value.")
      .addText((text) =>
        text
          .setPlaceholder(DEFAULT_CACHE_DIR)
          .setValue(this.plugin.settings.cacheDir)
          .onChange(async (value) => {
            const next = value.trim() || DEFAULT_SETTINGS.cacheDir;
            try {
              this.plugin.validateCacheRoot(next);
            } catch (error) {
              const message = error instanceof Error ? error.message : String(error);
              new Notice(`Yazi Exporter: ${message}`);
              return;
            }
            this.plugin.settings.cacheDir = next;
            await this.plugin.saveSettings();
          })
      );

    new Setting(containerEl)
      .setName("Render width")
      .setDesc("Rendered image width in pixels.")
      .addText((text) =>
        text
          .setValue(String(this.plugin.settings.widthPx))
          .onChange(async (value) => {
            this.plugin.settings.widthPx = Math.max(500, Number(value) || DEFAULT_SETTINGS.widthPx);
            await this.plugin.saveSettings();
          })
      );

    new Setting(containerEl)
      .setName("Max image height")
      .setDesc("0 = unlimited. Set a cap only if very long notes should be clipped.")
      .addText((text) =>
        text
          .setValue(String(this.plugin.settings.maxHeightPx))
          .onChange(async (value) => {
            const parsed = Number(value);
            if (!Number.isFinite(parsed)) {
              this.plugin.settings.maxHeightPx = DEFAULT_SETTINGS.maxHeightPx;
            } else if (parsed <= 0) {
              this.plugin.settings.maxHeightPx = 0;
            } else {
              this.plugin.settings.maxHeightPx = Math.max(1000, Math.floor(parsed));
            }
            await this.plugin.saveSettings();
          })
      );

    new Setting(containerEl)
      .setName("Page height")
      .setDesc("Height (px) of each split PNG page. Smaller values improve readability in yazi.")
      .addText((text) =>
        text
          .setValue(String(this.plugin.settings.pageHeightPx))
          .onChange(async (value) => {
            this.plugin.settings.pageHeightPx = Math.max(300, Number(value) || DEFAULT_SETTINGS.pageHeightPx);
            await this.plugin.saveSettings();
          })
      );

    new Setting(containerEl)
      .setName("Pixel ratio")
      .setDesc("1.0-2.0 is recommended. Higher value makes sharper but larger PNG.")
      .addText((text) =>
        text
          .setValue(String(this.plugin.settings.pixelRatio))
          .onChange(async (value) => {
            const parsed = Number(value);
            this.plugin.settings.pixelRatio = Math.max(1, Math.min(2.5, Number.isFinite(parsed) ? parsed : DEFAULT_SETTINGS.pixelRatio));
            await this.plugin.saveSettings();
          })
      );

    new Setting(containerEl)
      .setName("Render wait ms")
      .setDesc("Wait time after markdown render before PNG capture.")
      .addText((text) =>
        text
          .setValue(String(this.plugin.settings.renderWaitMs))
          .onChange(async (value) => {
            this.plugin.settings.renderWaitMs = Math.max(0, Number(value) || DEFAULT_SETTINGS.renderWaitMs);
            await this.plugin.saveSettings();
          })
      );

    new Setting(containerEl)
      .setName("Enable debug logs")
      .setDesc("Recommended OFF. When ON, detailed debug logs are written under cache/log. Path fields are redacted by default; set OBSIDIAN_YAZI_DEBUG_INCLUDE_PATHS=1 only when explicitly needed.")
      .addToggle((toggle) =>
        toggle.setValue(this.plugin.settings.enableDebugLogs).onChange(async (value) => {
          this.plugin.settings.enableDebugLogs = value;
          await this.plugin.saveSettings();
        })
      );

    new Setting(containerEl)
      .setName("Use current theme colors")
      .setDesc("ON: use current Obsidian theme colors in PNG output (recommended).")
      .addToggle((toggle) =>
        toggle.setValue(!this.plugin.settings.forceCustomColors).onChange(async (value) => {
          this.plugin.settings.forceCustomColors = !value;
          await this.plugin.saveSettings();
        })
      );

    new Setting(containerEl)
      .setName("Background color")
      .setDesc("Background color used when 'Use current theme colors' is OFF.")
      .addText((text) =>
        text
          .setPlaceholder("#ffffff")
          .setValue(this.plugin.settings.backgroundColor)
          .onChange(async (value) => {
            this.plugin.settings.backgroundColor = value.trim() || DEFAULT_SETTINGS.backgroundColor;
            await this.plugin.saveSettings();
          })
      );

    new Setting(containerEl)
      .setName("Text color")
      .setDesc("Text color used when 'Use current theme colors' is OFF.")
      .addText((text) =>
        text
          .setPlaceholder("#222222")
          .setValue(this.plugin.settings.textColor)
          .onChange(async (value) => {
            this.plugin.settings.textColor = value.trim() || DEFAULT_SETTINGS.textColor;
            await this.plugin.saveSettings();
          })
      );
  }
}
