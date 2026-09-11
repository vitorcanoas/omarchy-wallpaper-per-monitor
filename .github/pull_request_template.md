<!--
There is no CI in this repository: no workflows, no Makefile, no test suite.
Verification here is manual, so what you write below IS the verification
record. Please do not delete the checklist — mark items N/A instead.
-->

## What this changes

<!-- The problem, and the chosen solution. Keep one concern per pull request. -->

## User-visible impact

<!--
Any change to commands, the config file format, the menu row, or what gets
drawn on screen. Write "none" for an internal or docs-only change.
-->

## Files and interfaces affected

<!--
Call out explicitly if this touches Background.qml, the config file format,
override resolution, file watching, or the installer's edits to shell.json /
omarchy-menu.jsonc.
-->

## Verification

Commands actually run, with their results:

```
$ bash -n install.sh uninstall.sh bin/wp bin/wallpaper-monitor \
    bin/wallpaper-monitor-menu

$ shellcheck bin/* *.sh          # optional, not enforced

$ DRY_RUN=1 ./install.sh
$ DRY_RUN=1 ./uninstall.sh
```

- [ ] `bash -n` passes on every changed shell script
- [ ] `shellcheck` run where available (optional)
- [ ] `DRY_RUN=1 ./install.sh` and `DRY_RUN=1 ./uninstall.sh` pass, if either script changed
- [ ] `jq . manifest.json` valid, if the manifest changed
- [ ] No generated files, local config, rendered wallpapers or machine-specific screenshots committed

### Manual verification on real hardware

Required for anything affecting override resolution, file watching or
background transitions — there is no automated test to fall back on.

- **Omarchy version:**
- **Monitor setup:** <!-- names, resolutions, orientation and `transform` values -->
- **Rotated monitor tested?** <!-- yes / no / no rotated monitor available -->
- **What you observed:**

<!--
A rotated monitor is the case this plugin exists for and the one most likely
to break. If you do not have one, say so — the maintainer can check that
path, but it must not go unverified.

Shell log, if relevant:  journalctl -t omarchy-shell
(note: `journalctl --user -u omarchy-shell` returns nothing on this setup)
-->

## Docs

- [ ] README or CHANGELOG updated, if user-visible behaviour or commands changed
- [ ] A comment added next to the code, if this uncovered a new pitfall worth recording
