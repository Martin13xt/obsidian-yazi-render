# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| latest `main` snapshot | yes |
| older snapshots | best effort |

## Reporting a Vulnerability

Please open a private security advisory on GitHub if possible.
If private advisory is not available, open an issue with the prefix `[security]` and avoid posting exploit details until triage.

When reporting, include:

- affected version/commit
- operating system
- reproduction steps
- impact summary

## Response Targets

- Initial triage: within 72 hours
- Mitigation plan: within 7 days for high/critical issues
- Public disclosure: after a fix is available or when coordinated disclosure window ends

## Security Notes

- REST API key handling:
  - By default, yazi side key discovery is limited to the active vault settings and `OBSIDIAN_API_KEY`.
  - Cross-vault key discovery under `$HOME` is disabled by default and requires explicit opt-in via `OBSIDIAN_YAZI_ALLOW_HOME_KEY_SCAN=1`.
- Debug log privacy:
  - Debug logging is disabled by default.
  - When enabled, note/request paths are redacted unless `OBSIDIAN_YAZI_DEBUG_INCLUDE_PATHS=1` is explicitly set.
- Prebuilt plugin integrity:
  - Installer trusts only an externally verified checksum passed via `--prebuilt-sha256` (or `OBSIDIAN_PREBUILT_SHA256`).
  - Recommended source of trusted checksum: GitHub Release asset `obsidian-yazi-render-<VERSION>.prebuilt-main.js.sha256`.
