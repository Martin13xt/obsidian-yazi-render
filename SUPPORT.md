# Support Scope

## Official Support

- macOS
- Linux (manual setup on POSIX runtime)
- Windows (manual setup with POSIX compatibility layer in PATH)
- yazi + Obsidian Desktop
- Obsidian Local REST API plugin

## Privacy Defaults

- Cache directories and sentinel/header files are permission-hardened (`700` dirs, `600` sensitive files on POSIX).
- REST API key handling is restricted to vault-local config and explicit env by default.
- Debug logs are OFF by default and redact note paths unless `OBSIDIAN_YAZI_DEBUG_INCLUDE_PATHS=1` is explicitly set.

## What to Include in Issues

- OS and shell
- yazi version
- Obsidian version
- Local REST API plugin enabled/disabled
- output from `./scripts/doctor.sh --vault "<path>"`
- relevant files under cache `log/*.error.json` (redacted if needed)
