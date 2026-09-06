# Changelog

All notable changes to Omarchy Wallpaper Per Monitor are documented here.

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
