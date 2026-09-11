# Changelog

All notable changes to Omarchy Wallpaper Per Monitor are documented here.

## [Unreleased]

### Removed

- `bin/omarchy-wallpaper-render` and `docs/RENDER.md`. The render tool was
  always optional and never on the plugin's runtime path, and its batch body
  was specific to one art collection rather than general. The plugin now
  installs three CLIs instead of four; wallpaper selection and rendering
  behaviour are unchanged.
- Internal working notes that were never contributor documentation. The
  pitfalls they recorded are now comments beside the code that motivated
  each one, in English.

### Changed

- **Translated the six CLI/QML files from Portuguese to English**: comments
  and user-facing output in `bin/wp`, `bin/wallpaper-monitor`,
  `bin/wallpaper-monitor-menu`,
  `Background.qml`, `install.sh` and `uninstall.sh`. This plugin is published
  to the international Omarchy community, so English is now the working
  language of the repo. The Portuguese aliases in `wp` (`horizontal`/`deitada`,
  `vertical`/`pe`) stay accepted as muscle memory.

## [0.2.0] - 2026-09-06

Hardening pass: a four-front adversarial code review over the committed
code, every finding required to come with a concrete reproducible scenario,
then applied and validated on the live shell (two monitors, one of them
rotated). Adds a visual entry to the Omarchy menu.

### Added

- **Menu entry under Style > Wallpaper per monitor**, reachable from the
  Omarchy menu (SUPER+SPACE): pick a monitor, then pick the art from a
  thumbnail grid. `bin/wallpaper-monitor-menu` opens the catalogue matching
  that monitor's *orientation* -- offering landscape art for a portrait
  screen is the letterboxing this plugin exists to avoid. Cancelling at any
  step exits 0 without applying anything.

  It deliberately does **not** declare `kind:"menu"`: that kind opens a
  separate IPC-summoned window rather than contributing a row to the main
  menu. The row is injected into `~/.config/omarchy/extensions/omarchy-menu.jsonc`,
  which the shell merges over its default menu at runtime and watches for
  changes. The manifest is therefore unchanged -- the plugin is still
  `kinds:["service"]`, and the service validated in production is untouched.

  Thumbnails and search are Omarchy's own: `omarchy-menu-images` already
  renders them with `vipsthumbnail`, caches them, and offers `--filterable`.
  Nothing was reimplemented.

- `uninstall.sh`, which did not exist. Removes the symlinks only when they
  point at this plugin, restores `omarchy.background`, drops the menu row,
  and never deletes the user's own `background-per-monitor.json`.

- `SECURITY.md`, documenting the execution surface, the deliberate reuse of
  the `"background"` IPC target, the atomic-write technique, and the absence
  of network or credential access.

### Fixed

- **`wallpaper-monitor list` destroyed the user's overrides.** A read-only
  command: on a corrupted JSON the `except` treated "unreadable" as
  "old/empty format", migrated to `{"monitors":{}}` and wrote it back. Now
  a missing file (start empty) and an unreadable one (abort, exit 2, change
  nothing) are separate cases, and `list` never writes.

- **Concurrent writes lost overrides.** `mktemp`+`mv` made the *replacement*
  atomic, but the read-modify-write cycle was not serialized: two `wp` calls
  at once (a repeated keybind) and the last one won. Now serialized with the
  directory-lock technique already approved by the marketplace maintainer in
  omarchy-nightlight PR #8 -- deliberately not `flock 9>path`, which that
  same PR rejects for following a symlink at the final component -- plus
  `fsync`. Measured: 12 concurrent writes preserved 0/12 before, 12/12 after.

- **`finishTransition` locked up permanently on hotplug**, leaking the
  crossfade images in VRAM until the shell restarted: reading `.baseReady`
  off a destroyed panel yields `undefined`, so the guard returned early on
  every later call and no event could re-trigger it. The same bug exists
  upstream in PR #10249; it was inherited, not introduced.

- **Crossfade layers decoded at native resolution with mipmaps**, and did so
  even when `useOverride` was true and not one of their pixels was visible --
  four wasted full-resolution decodes per theme switch in the production
  configuration. With 8000px PNGs that peaked over 750 MB of VRAM for a
  420 ms effect.

- **A partial install could leave the system half-configured.** `shell.json`
  was edited *before* the symlinks, so a collision at `~/.local/bin/wp`
  (common: another tool) disabled the native wallpaper and then aborted. The
  three links are now pre-checked without side effects; the script refuses
  with "Nothing has been changed yet".

- **`DRY_RUN=true` performed a real install** (the test was `== 1`). Only
  `0` and `1` are accepted now, rather than guessed at.

- **`wp` reported an empty catalogue from anywhere but its own checkout.**
  `BASE=$(dirname $0)/..` resolved to the installed plugin directory when
  called through the `~/.local/bin` symlink -- which holds no `render/` -- so
  `wp h` printed "(no 16x9)" and exited 0, indistinguishable from "no art".
  Resolution now matches the menu's exactly, so the number the menu shows and
  the one `wp` applies can never come from different catalogues.

- **The menu row insertion corrupted `omarchy-menu.jsonc`**, taking the
  user's own menu entries with it. Inserting before the last `}` placed the
  row after the user's final entry, which carries no trailing comma; the
  shell's `JSON.parse` sits in a `try/catch` returning an empty list, so the
  user would lose their own rows with no message at all. The row now goes in
  right after the opening `{`. Caught in review, before the menu was ever
  installed.

- **A connector name containing a newline applied the wallpaper to a phantom
  monitor**, silently and with exit 0: the TSV output is read line by line,
  so `DP\n1` became two records and the name regex ran *after* the split, on
  a fragment that passes it. Rejected at the source now.

- **Writes were not actually atomic.** The temp file was created in `/tmp`
  (tmpfs) with the destination in `$HOME` (btrfs), making `mv` a copy+unlink
  rather than `rename(2)`. A crash mid-copy would truncate `shell.json` --
  the file the whole shell reads at startup.

- Malformed input no longer fails silently: `hyprctl` output without a
  `transform` field, a monitor name that is not a string, `portrait`/
  `landscape` keys holding a non-string, a disabled monitor being offered as
  a target, and an index with a leading zero (`wp h 09`, which died with the
  shell's octal error) all produce clear messages now.

- Catalogue ordering is pinned with `LC_ALL=C`, so the number the user
  memorises does not change between an interactive terminal and a keybind.

- The per-monitor JSON keeps its file mode instead of inheriting `mktemp`'s.

### Changed

- Flat-format JSON now honours the `portrait`/`landscape` fallback, which the
  code's own comment already promised but only applied to the new format.


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
- Studied upstream [PR #10249](https://github.com/omacom/omarchy/pull/10249)
  by DCPRevere, the basis for the override-selection and fallback logic in
  `Background.qml`.
