# Omarchy Wallpaper Per Monitor

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![Version 0.2.0](https://img.shields.io/badge/version-0.2.0-lightgrey)
![Status: beta](https://img.shields.io/badge/status-beta-orange)

A different wallpaper on every screen in [Omarchy](https://omarchy.org) — and,
unlike everything else I could find in the ecosystem, it gets **rotated
monitors** right.

**For:** Omarchy 4 users with more than one monitor, especially anyone running
a panel rotated to portrait. **It is** a Quickshell `service` plugin that
replaces the native `omarchy.background` plugin — see
[what this changes on your system](#what-this-changes-on-your-system).

[Quick start](#quick-start) · [Requirements](#requirements) ·
[Usage](#usage) · [What this changes on your system](#what-this-changes-on-your-system) ·
[The rotation problem](#the-rotation-problem) · [Uninstall](#uninstall)

```text
   DP-2  ──  1920x1080            HDMI-A-1 ── 1080x1920
   transform: 0                   transform: 1  (rotated 90°)
  ┌───────────────────────┐        ┌──────────┐
  │                       │        │          │
  │   landscape art       │        │ portrait │
  │   16x9/               │        │   art    │
  │                       │        │  9x16/   │
  └───────────────────────┘        │          │
                                   │          │
   same physical panel model ──────└──────────┘

   hyprctl reports BOTH as 1920x1080. Only `transform` reveals
   that the second one is displaying 1080x1920.
```

Two screens, one rotated to portrait, each getting art composed for its own
orientation — chosen from the monitor's **effective post-rotation** size, not
the mode `hyprctl` reports. [Why that distinction is the whole
point.](#the-rotation-problem)

> **⚠ Beta, tested on one machine.** It fails soft — a wallpaper that does not
> load falls back to your normal Omarchy theme background, and uninstalling
> restores stock behaviour. [What is and is not
> tested.](#what-is-and-is-not-tested)

---

## Requirements

- **Omarchy 4** with `omarchy-shell` (Quickshell)
- **`jq`** — used by `install.sh` to edit `shell.json` safely
- **`python3`** — used by the CLIs to parse `hyprctl` output and the config

`install.sh` checks its required tools up front and stops with the package name if
one is missing, rather than failing halfway through.

Linux process supervision also requires `/proc` and child-subreaper support.
Configuration paths must have real directories (no symlink components), owned
by the user and not writable by group or others. Config files are limited to
256 KiB; existing file modes are preserved. Overrides refresh within about two
seconds. Interactive pickers close after 120 seconds without a selection.

That is all you need. You can use this plugin perfectly well with wallpapers
you already have.

---

## Quick start

```bash
git clone https://github.com/vitorcanoas/omarchy-wallpaper-per-monitor.git
cd omarchy-wallpaper-per-monitor
DRY_RUN=1 ./install.sh   # preview first — changes nothing
./install.sh
```

Wallpaper choices are independent of your Omarchy theme. Setting an override
for a monitor does not change the theme.

Then set a wallpaper per screen, without having to remember connector names:

```bash
wp            # list the landscape and portrait catalogues
wp h 3        # apply landscape image #3 to the landscape monitor
wp v 2        # apply portrait image #2 to the portrait monitor
```

`DRY_RUN=1` prints every step against a throwaway staging copy, so you can see
exactly what would happen to your `shell.json` before it happens. I recommend
running it first. `install.sh` is idempotent — running it twice is safe.

`install.sh` does four things:

1. copies the plugin into
   `~/.config/omarchy/plugins/vitorcanoas.background-per-monitor/`;
2. registers it in `~/.config/omarchy/shell.json` and disables the native
   `omarchy.background` plugin (backing up `shell.json` first);
3. symlinks `wallpaper-monitor`, `wp` and `wallpaper-monitor-menu` into
   `~/.local/bin`;
4. adds a "Wallpaper per monitor" row to the SUPER+SPACE menu.

---

## What is and is not tested

I built this for my own desk and it has run there every day since — **that is
one machine, one configuration.** Validated in daily use: Omarchy 4 on Arch,
two monitors with one rotated (`DP-2` 1920x1080 landscape + `HDMI-A-1`
1080x1920 portrait), plus install, uninstall and the `DRY_RUN=1` preview of
both.

**Three or more monitors, real hotplug, and anything other than Arch + Omarchy
are untested.** Nothing here is production-hardened. It fails soft by design,
but "fails soft" is not the same as "well tested" — bug reports from other
setups are the most useful thing you can send me.

<details>
<summary><strong>Configurations not tested at all</strong> (click to expand)</summary>

- **Three or more monitors.** Nothing in the code assumes two — the config maps
  any number of connector names, and one layer is rendered per screen — but no
  one has run it on such a setup, so treat it as unverified rather than
  unsupported.
- **Two monitors in the *same* orientation sharing one orientation default** —
  they both get that same default, which is correct but probably not what you
  wanted. Give at least one of them a named entry
  (`wallpaper-monitor set DP-3 ...`). The `wp h`/`wp v` shortcut warns and
  applies to the first of them.
- **Real hotplug**: docking/undocking a laptop, plugging a monitor mid-session.
- **Anything other than Arch + Omarchy.**

Full disclosure: I am not a professional developer. I read a lot and tested
on real hardware, and the pitfalls I hit are recorded as comments in the code
next to the lines that motivated them.

</details>

---

## What this changes on your system

Nothing here needs `sudo`, and nothing is downloaded or executed from the
network at install time or at runtime. Nothing is changed without you running
`install.sh` yourself, and `DRY_RUN=1 ./install.sh` shows the whole diff first.

**It replaces the stock background renderer.** This plugin declares
`omarchy.clonedFrom: "omarchy.background"` in its `manifest.json` — Omarchy's
official way to say "I am a replacement for this built-in" — and it declares
the same `omarchy-background` Wayland layer namespace as the native
`omarchy.background`, which it disables, because two things drawing the
wallpaper on the same layer fight over it
([Omarchy issue #8378](https://github.com/omacom/omarchy/issues/8378)). It
reimplements the native plugin's full `background` IPC surface — `refresh`,
`set`, `setInstant`, `transition`, `themeTransition` — so `omarchy theme set`,
the wallpaper picker, and `SUPER+CTRL+SPACE` keep working exactly as before.
`uninstall.sh` restores the native plugin.

<details>
<summary><strong>Every path this plugin touches, and whether uninstall reverts it</strong></summary>

| Path | Change | Reverted by `uninstall.sh`? |
|---|---|---|
| `~/.config/omarchy/plugins/vitorcanoas.background-per-monitor/` | created; the plugin itself | yes, removed |
| `~/.config/omarchy/shell.json` | adds this plugin to `plugins[]`, adds `omarchy.background` to `disabledPlugins[]`, and adds this plugin to `cloneSourceRestores[]` to record that it is the one that disabled it; timestamped backup written first | yes, all three reversed |
| `~/.config/omarchy/extensions/omarchy-menu.jsonc` | one marker-delimited row added, edited as text (it is JSONC, never re-serialized) | yes, row removed |
| `~/.local/bin/{wallpaper-monitor,wp,wallpaper-monitor-menu}` | three symlinks into the installed plugin's `bin/` | yes, and only if each still points here |
| `~/.config/omarchy/background-per-monitor.json` | your wallpaper choices, written only when you run a `wallpaper-monitor` command | **no** — it is your config, not the installer's |

</details>

See the [security policy](.github/SECURITY.md) for what this plugin does with
the unsandboxed access every Omarchy plugin has.

---

## Usage

There are two ways to use it. Pick whichever you like.

### 1. The menu (SUPER+SPACE)

Press SUPER+SPACE and type `per` — or `per-monitor`, or `monitor-wallpaper`:

![The Omarchy SUPER+SPACE menu with "per" typed in the search box. The first
result is "Wallpaper per mon…" under Style, above the other fuzzy
matches.](docs/img/menu-super-space.png)

Pick a monitor, then pick the image from a thumbnail grid. The grid only shows
art matching **that monitor's orientation** — offering landscape art for a
portrait screen would produce exactly the black bars this plugin exists to
avoid. Cancelling at any step exits cleanly without changing anything.

Thumbnails, caching and search are Omarchy's own (`omarchy-menu-images`,
`omarchy-menu-select`); nothing was reimplemented.

<sub>Implementation note: the row is *not* declared as `kind:"menu"` in the
manifest — that kind opens a separate IPC-summoned window instead of adding a
row to the main menu. `install.sh` injects the row into
`~/.config/omarchy/extensions/omarchy-menu.jsonc`, which the shell merges over
its default menu at runtime. The plugin stays `kinds:["service"]`.</sub>

### 2. The command line

`wp` is the quick one. It picks the target monitor by its **actual**
orientation, so you never have to remember connector names:

```bash
wp                 # list both catalogues (landscape and portrait art)
wp h               # list only the landscape catalogue
wp v               # list only the portrait catalogue
wp h 3             # apply landscape image #3 to the landscape monitor
wp v 2             # apply portrait image #2 to the portrait monitor
wp h 5 DP-3        # ...to a specific monitor, when several share an orientation
```

`wallpaper-monitor` is the full interface to the config file:

```bash
wallpaper-monitor set <MONITOR> <image-path>    # override one named monitor
wallpaper-monitor set-portrait <image-path>     # default for portrait displays
wallpaper-monitor set-landscape <image-path>    # default for landscape displays
wallpaper-monitor clear <MONITOR>               # remove a monitor's override
wallpaper-monitor clear-portrait                # remove the portrait default
wallpaper-monitor clear-landscape               # remove the landscape default
wallpaper-monitor list                          # overrides, defaults, detected monitors
```

`set`, `set-portrait` and `set-landscape` resolve the path to an absolute one
and refuse to write it if the file does not exist.

`wp h`/`wp v` are a two-keystroke shortcut for "the landscape/portrait screen",
so they need one obvious target. With several screens sharing an orientation
there isn't one: `wp` prints the names it found, applies to the first, and tells
you to name the monitor instead. Disabled outputs are skipped, since writing an
override for a screen showing nothing looked like it worked and changed nothing.
Pass the connector name (`wp h 5 DP-3`) or use `wallpaper-monitor set` to be
unambiguous.

---

## How it works

Overrides live in a single JSON file,
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

The plugin watches that file live, so changes apply immediately — no shell
restart.

**Precedence**, per monitor:

1. a named entry in `monitors`;
2. the `portrait` or `landscape` default, chosen by the monitor's *effective*
   (post-rotation) dimensions;
3. the normal Omarchy theme background.

**Any number of monitors.** `monitors` is a plain name → path map with no fixed
size, and the plugin renders one layer per screen Quickshell reports, so four or
six displays work the same way two do: add an entry per connector name, mix
named entries with the orientation defaults freely, and any screen you leave out
falls through to step 2 and then step 3. The two-monitor example above is the
author's own desk, not a limit. Run `wallpaper-monitor list` to see the connector
names and the orientation the plugin computed for each. Caveat worth knowing
before you rely on it: more than two screens is **untested on real hardware** —
the logic has no limit, but nobody has run it that way yet.

Only absolute paths (or `~/...`) are accepted. Anything else, or an image that
fails to load, is treated as unset and falls through to the next step — so an
override pointing at a deleted file degrades to the theme background rather
than to a black screen. An older flat format (monitor name → path, with no
`monitors` key) is still read; `wallpaper-monitor` migrates it on first write,
keeping a timestamped backup.

---

## Why this exists

Omarchy applies wallpapers through a single symlink
(`~/.local/state/omarchy/current/background`) shared by every display. Change
a theme or a background and all monitors show the same image. That is
documented, intended behaviour — per-monitor wallpaper is not supported
natively. On a desk that mixes a landscape monitor with a portrait one, one of
them always ends up stretched, cropped, or letterboxed.

### The rotation problem

This is the interesting part, and the reason this plugin exists rather than a
config snippet.

`hyprctl monitors -j` reports the **physical** mode of a monitor, not its
logical, on-screen dimensions. A 1920x1080 panel with `transform: 1` is
actually displaying a 1080x1920 portrait area — but the JSON still says
`1920x1080`. Any code that decides "portrait or landscape?" from those numbers
without reading `transform` gets it wrong *specifically* on rotated monitors,
which is the whole reason someone would want per-monitor wallpaper in the
first place.

The fix is small once you know it — swap width and height when
`transform % 2` is odd — and it lives in `bin/wp`:

```python
w, h = (m['height'], m['width']) if m['transform'] % 2 else (m['width'], m['height'])
```

I looked at roughly six Quickshell shells in the Omarchy ecosystem
(DankMaterialShell, noctalia, caelestia, end-4, and others) and found **none**
that account for monitor rotation when deciding layout or wallpaper. The root
cause is upstream and not their fault: Quickshell's `ShellScreen` API does not
expose `transform`, so there is no clean way to ask. This plugin works around
it — the Quickshell side reads the already-rotated `width`/`height` that
`PanelWindow` receives, and the shell CLIs correct `hyprctl` by hand. It is a
workaround, not the right API. The `transform` correction itself is in
`bin/wallpaper-monitor`, commented where it happens.

### Why it has to be a plugin, not hyprpaper or swww

Omarchy issue [#8378](https://github.com/omacom/omarchy/issues/8378) (open):
both `omarchy restart shell` and `omarchy-update-restart` remount a layer
called `omarchy-background` on top of whatever is drawing your wallpaper. Any
external daemon — `hyprpaper`, `swww` — gets silently painted over on the next
restart, with no warning. So this has to be a Quickshell `service` plugin
declaring that same layer namespace, which is exactly what `Background.qml`
is. The namespace declaration is commented in `Background.qml` where it
happens.

---

## Uninstall

```bash
DRY_RUN=1 ./uninstall.sh   # preview
./uninstall.sh
```

`uninstall.sh` reverses `install.sh` step by step:

- removes the `wallpaper-monitor`, `wp` and `wallpaper-monitor-menu` symlinks
  from `~/.local/bin` — but only if each one still points at this plugin's
  installed `bin/`; a real file, or a symlink to something else, is left
  alone;
- removes `vitorcanoas.background-per-monitor` from `plugins[]` in
  `~/.config/omarchy/shell.json` and restores `omarchy.background` by taking
  it out of `disabledPlugins[]`, backing up `shell.json` first;
- removes the menu row from `omarchy-menu.jsonc`;
- removes the installed plugin directory.

It deliberately does **not**:

- delete `~/.config/omarchy/background-per-monitor.json` — that is your
  configuration, not something the installer created. The script prints its
  path as a reminder;
- delete `~/.config/omarchy/shell.json.bak.*` backups, which accumulate across
  repeated installs. Remove them by hand
  (`rm -f ~/.config/omarchy/shell.json.bak.*`) when you no longer need them;
- restore `omarchy.background` if `shell.json` does not name this plugin in
  `cloneSourceRestores[]` when `uninstall.sh` runs — that array is the record
  of *which* plugin disabled the native one, so without our id in it the
  script has no claim to release and leaves `disabledPlugins[]` alone rather
  than guess. In normal use our id is there and the native background **is**
  restored; the usual reason it is absent is that `omarchy plugin disable
  vitorcanoas.background-per-monitor` already ran, in which case the shell
  restored the native itself and there is nothing left to do.

Restart `omarchy-shell` (or your session) afterwards.

---

## Prior art and credit

There is an open PR against upstream Omarchy —
[#10249](https://github.com/omacom/omarchy/pull/10249), "Support per-monitor
wallpapers", by **DCPRevere** — that also does per-monitor wallpaper. It is
neither merged nor rejected at the time of writing, and it does not handle
rotation. Parts of this plugin's selection logic are adapted from it, with
credit in the header of `Background.qml`. Specifically:

- the portrait/landscape fallback design (a named override taking precedence
  over an orientation default);
- validating that an override path is absolute (or `~/...`) before using it;
- the `rejectedSource` pattern — remembering which path just failed to load,
  so a later config change is retried automatically instead of leaving the
  display stuck on the theme background.

This plugin reimplements that logic against its own config file
(`background-per-monitor.json` instead of `shell.json`), adds rotation-aware
orientation detection, support for the older flat format, the menu entry, and
the `wallpaper-monitor`/`wp` CLIs. The upstream PR itself is
[omacom/omarchy#10249](https://github.com/omacom/omarchy/pull/10249) by
DCPRevere, still open against an unreleased branch at the time of writing.

---

## More

- [Security policy](.github/SECURITY.md) — what this plugin does with the
  unsandboxed access every Omarchy plugin has
- [Changelog](CHANGELOG.md)
- [Contributing](.github/CONTRIBUTING.md)

## License

MIT.
</content>
