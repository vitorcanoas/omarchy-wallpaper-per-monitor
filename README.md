# Omarchy Wallpaper Per Monitor

Per-monitor wallpaper for [Omarchy](https://omarchy.org): a different image on
every screen, with sensible fallback by orientation.

## The problem

Omarchy applies wallpapers through a single symlink
(`~/.local/state/omarchy/current/background`) shared by every display. When a
theme or background changes, all monitors show the same image. Omarchy's own
documentation confirms this is the intended behaviour: per-monitor wallpaper
is not supported natively. On a desk that mixes a landscape monitor with a
portrait one, that means either a stretched or cropped image on one of them.

## The solution

This plugin lets each screen keep its own wallpaper. Configure an image for a
named monitor, or set a default for portrait and landscape displays so any
unconfigured screen still gets an image matched to its orientation. Unset
displays, and any override that fails to load, fall back to the normal Omarchy
theme background — nothing breaks if the plugin is disabled or the config file
is missing.

## Install

```bash
omarchy plugin add https://github.com/vitorcanoas/omarchy-wallpaper-per-monitor.git --enable
```

`install.sh` is optional; it only creates the `wallpaper-monitor`, `wp` and
`omarchy-wallpaper-render` commands on `PATH`. It does not install the plugin
or change your wallpaper by itself.

## Removal

```bash
omarchy plugin remove vitorcanoas.background-per-monitor
```

That removes the plugin itself. If you also ran `install.sh`, undo it with
the matching `./uninstall.sh` from the repository checkout:

```bash
./uninstall.sh
```

`uninstall.sh` reverses `install.sh` step by step:

- removes the `wallpaper-monitor`, `wp` and `omarchy-wallpaper-render`
  symlinks from `~/.local/bin` — but only if each one still points at this
  plugin's installed `bin/` directory; a real file or a symlink to something
  else at that path is left alone;
- removes `vitorcanoas.background-per-monitor` from `plugins[]` in
  `~/.config/omarchy/shell.json`, and restores `omarchy.background` by
  removing it from `disabledPlugins[]`, backing up `shell.json` first;
- removes the installed plugin directory,
  `~/.config/omarchy/plugins/vitorcanoas.background-per-monitor/`.

It does **not**:

- delete `~/.config/omarchy/background-per-monitor.json`, your per-monitor
  override config — that is your own configuration, not something the
  installer created on your behalf, and it stays in place (the script prints
  its path as a reminder);
- delete `~/.config/omarchy/shell.json.bak.*` backups left behind by
  `install.sh` — these accumulate across repeated installs and are removed
  by hand (`rm -f ~/.config/omarchy/shell.json.bak.*`) once you no longer
  need them;
- restore `omarchy.background` if this installer's own plugin id was already
  missing from `shell.json` when `uninstall.sh` ran (e.g. it was removed by
  hand beforehand) — `shell.json` does not record which installer disabled
  the native plugin, so `uninstall.sh` leaves `disabledPlugins[]` untouched
  in that case rather than guess, and says so.

As with `install.sh`, run `DRY_RUN=1 ./uninstall.sh` first to preview every
step against a throwaway staging copy, with no changes to the real
`shell.json` or `~/.local/bin`.

Restart `omarchy-shell` (or your session) after either removal path for the
change to take effect.

## Usage

### `wallpaper-monitor`

Manages the override file at `~/.config/omarchy/background-per-monitor.json`.

```bash
wallpaper-monitor set <MONITOR> <image-path>    # override for one named monitor
wallpaper-monitor set-portrait <image-path>     # default for portrait displays
wallpaper-monitor set-landscape <image-path>    # default for landscape displays
wallpaper-monitor clear <MONITOR>                # remove a monitor's override
wallpaper-monitor clear-portrait                 # remove the portrait default
wallpaper-monitor clear-landscape                # remove the landscape default
wallpaper-monitor list                           # show configured overrides, defaults and detected monitors
```

`set`/`set-portrait`/`set-landscape` resolve the given path to an absolute
path and refuse to write it if the file does not exist. The plugin watches the
JSON file live, so there is no need to restart the shell after changing it.

### `wp`

A shortcut on top of `wallpaper-monitor` that picks the target monitor by its
actual orientation (via `hyprctl`), not by a hardcoded name:

```bash
wp                # list both catalogues (landscape and portrait art)
wp h               # list only the landscape catalogue
wp v               # list only the portrait catalogue
wp h <n>           # apply the n-th landscape image to the detected landscape monitor
wp v <n>           # apply the n-th portrait image to the detected portrait monitor
```

`h` targets a landscape (horizontal) monitor, `v` targets a portrait
(vertical) one, and `<n>` is the 1-based index of the image as listed by `wp`
(or `wp h` / `wp v` alone).

## Configuration format

`~/.config/omarchy/background-per-monitor.json`:

```json
{
  "monitors": {
    "DP-2": "/home/you/Pictures/wallpapers/landscape-01.png",
    "HDMI-A-1": "/home/you/Pictures/wallpapers/portrait-01.png"
  },
  "portrait": "/home/you/Pictures/wallpapers/portrait-default.png",
  "landscape": "/home/you/Pictures/wallpapers/landscape-default.png"
}
```

- `monitors` maps a monitor name (as reported by `hyprctl monitors -j`) to an
  absolute image path.
- `portrait` and `landscape` are fallback images used for any monitor without
  a named entry, chosen by whether the monitor's effective (post-rotation)
  height exceeds its width.
- A flat, older format — a plain object mapping monitor name to path, without
  a `monitors` key — is still read directly by the plugin. `wallpaper-monitor`
  migrates it to the current format automatically on first write, keeping a
  timestamped backup.
- Resolution order: named `monitors` entry, then the `portrait`/`landscape`
  default for that orientation, then the normal Omarchy theme background.
- Only absolute paths (or `~/...`, expanded to the home directory) are
  accepted; anything else, or a path that fails to load, is treated as unset
  and falls through to the next step in that order.

## Prior art and credits

This plugin's per-monitor and per-orientation selection logic is adapted from
[PR #10249](https://github.com/omacom/omarchy/pull/10249) ("Support
per-monitor wallpapers") by **DCPRevere**, open against upstream Omarchy at
the time of writing — not merged, not rejected. Credit goes to that PR for:

- the portrait/landscape fallback design (a named override taking precedence
  over an orientation default);
- validating that an override path is absolute (or `~/...`) before using it;
- the `rejectedSource` pattern — remembering which specific path just failed
  to load, so a later change to the config is retried automatically instead
  of leaving the display stuck on the theme background until a manual reset.

This plugin reimplements that logic against its own configuration file
(`background-per-monitor.json` instead of `shell.json`) and adds support for
the older flat JSON format, a render pipeline for source art, and the
`wallpaper-monitor`/`wp` command-line tools. See
[`docs/upstream-pr-10249/`](docs/upstream-pr-10249/) for the saved reference
copy of the upstream PR.

## More information

- [Technical background](docs/CONTEXTO.md) (in Portuguese) — render pipeline,
  known pitfalls and design decisions
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

MIT.
