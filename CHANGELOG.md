# Changelog

All notable changes to this project are documented in this file.

## Unreleased

### Fixed
- correct yazi minimum version in README (`v26+` → `v26.1.22+`) including badge
- correct Node.js minimum version in README (`v20+` → `>=20.19.0`)
- correct prebuilt SHA-256 asset filename in README
- correct launchd plist name in uninstall instructions (`com.obsidian-yazi.cleanup` → `com.obsidian-yazi-cache-cleanup`)
- document URI fallback dependency on Advanced URI plugin (`obsidian://adv-uri`)
- add `jq`/`rsync`/`curl` to requirements table (installer and runtime)
- add `community-plugins.json` cleanup, backup dir, launchd logs, and `/tmp` fallback cache to uninstall instructions
- note custom plist/log path cleanup in uninstall
- show Linux/fallback cache defaults in README configuration table
- add prerequisites and CI note to CONTRIBUTING.md
- add Obsidian minimum version (`v1.6.0+`) to requirements table
- separate CLI tool roles in requirements table (installer vs runtime)
- expand uninstall note to list all 4 custom launchd env vars
- fix `install.sh` path in CONTRIBUTING.md note (`install.sh` → `./scripts/install.sh`)
- add `curl` to CONTRIBUTING.md prerequisites

## 0.2.0 - 2026-03-07

### Added
- adaptive viewport rendering: render width and page height auto-fit to terminal pane size
- browser-like content layout with centered max-width and DPR-aware pixel ratio
- fast path for page navigation (J/K) with direct seek display
- manual refresh progress overlay with spinner in preview pane
- delayed image re-draw after overlay to fix Kitty graphics artifacts
- uninstall instructions and known limitations in README
- CONTRIBUTING.md with development setup guide

### Fixed
- Kitty graphics black rectangle artifact after manual refresh (U key) overlay disappears
- top padding in rendered PNG (split padding to exclude top)
- blending function anchoring to stale cached parameters when diff > 15%
- manual refresh (U key) polling and progress display
- cold-cache preview and installer sed regression

### Changed
- rewrite README (Japanese and English) with GitHub decorations (badges, alerts, kbd tags)
- disable background refresh notifications by default (`OBSIDIAN_YAZI_REFRESH_NOTIFY=0`)
- eliminate top margin/padding on render host elements for tighter content fit
- hide metadata/frontmatter with height collapse in render host

### Infrastructure
- rebuild prebuilt plugin artifact from latest source and refresh `prebuilt/main.js.sha256`
- add release gate to ensure `prebuilt/main.js` matches a fresh source build
- align cache default resolution across installer/runtime/docs (including `XDG_CACHE_HOME` support)
- require absolute cache paths in installer/cleanup scripts to prevent relative-path accidents
- harden `install-launchd.sh` with plist backup, atomic write, and pre-load `plutil -lint` validation
- make installer file replacement stage temp files in the target directory for same-filesystem atomic moves
- simplify refresh transport and deduplicate http_post curl logic
- harden plugins with LRU bounds, shared fallback hints, and safe fixes

## 0.1.20 - 2026-02-26

- add CI matrix release checks (ubuntu + macOS + windows)
- add deterministic CI dependency install (`npm ci`) before release checks
- add plugin `typecheck` gate and wire it into release checks
- harden installer with backups, dry-run mode, and rollback guidance
- add SHA-256 command fallback (`shasum` / `sha256sum` / `openssl`) in installer and doctor scripts
- clarify trusted prebuilt checksum behavior in docs
- disable HOME-wide REST API key scan by default; add explicit opt-in `OBSIDIAN_YAZI_ALLOW_HOME_KEY_SCAN`
- make Lua syntax gate strict by default and remove non-deterministic `npx --yes` parser fallback
- enforce Node.js minimum version (`>=20.19.0`) for source-build paths
