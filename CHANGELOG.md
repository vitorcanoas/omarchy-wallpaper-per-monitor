# Changelog

All notable changes to Omarchy Wallpaper Per Monitor are documented here.

## [Unreleased]

### Fixed

- `install.sh` ignored a test `HOME` override and silently wrote into the
  real user's `~/.config/omarchy/shell.json` and plugin directory. The cause
  was not `~` expansion (there was none in the script) but
  `${XDG_CONFIG_HOME:-$HOME/.config}` / `${XDG_BIN_HOME:-$HOME/.local/bin}`:
  a desktop session exports `XDG_CONFIG_HOME` as an absolute path to the
  real home, so that fallback took priority over `$HOME` and ignored it
  entirely, while `XDG_BIN_HOME` (unset) correctly fell through to `$HOME`
  -- explaining why only the `bin/` symlinks respected the fake `HOME` in
  testing. Now resolved directly from `"$HOME"` (`"$HOME/.config/omarchy"`,
  `"$HOME/.local/bin"`), matching how Omarchy's own migrations resolve
  `shell.json`. Verified with `HOME=<fake> bash install.sh`: every file
  landed under the fake home, and the real `shell.json` was confirmed
  byte-for-byte and mtime-identical before and after.
- Documented (no target change) the `IpcHandler { target: "background" }`
  collision warning logged by `Background.qml` when the native
  `omarchy.background` plugin is disabled. The shared target is load
  bearing: `omarchy theme bg set` and `omarchy theme set` both drive the
  shell via `omarchy-shell -q background set|themeTransition ...`, so this
  plugin must keep answering on `background` to stay wired to Omarchy's own
  CLI. The warning is cosmetic.

## [0.1.0] - 2026-09-06

### Added

- `Background.qml` Quickshell service plugin: per-monitor wallpaper override
  with fallback by orientation (portrait/landscape) and fallback to the
  normal Omarchy theme background when no override applies or an override
  fails to load.
- Support for both the current override format
  (`{"monitors": {...}, "portrait": ..., "landscape": ...}`) and the older
  flat format (a plain monitor-name-to-path object), read directly by the
  plugin.
- `wallpaper-monitor` CLI: `set`, `set-portrait`, `set-landscape`, `clear`,
  `clear-portrait`, `clear-landscape` and `list`, operating on
  `~/.config/omarchy/background-per-monitor.json`, with automatic migration
  from the flat format (backed up before rewriting) and absolute-path
  validation.
- `wp` CLI: shortcut over `wallpaper-monitor` that selects the target monitor
  by detected orientation (via `hyprctl`) instead of a hardcoded name, and
  lists the available landscape/portrait art catalogues.
- `omarchy-wallpaper-render` rendering pipeline: renders each source image
  only in its native orientation (no forced dual-orientation rendering),
  using Real-ESRGAN (`x4plus-anime`, fixed 4x scale) for upscaling and
  ImageMagick for composition, output as PNG.
- Art classification reference (`docs/classificacao-de-artes.md`) documenting
  the native orientation of each source image.
- Saved reference copy of upstream [PR #10249](https://github.com/omacom/omarchy/pull/10249)
  (`docs/upstream-pr-10249/`), the basis for the override-selection and
  fallback logic in `Background.qml`.
