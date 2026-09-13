# Contributing

Thank you for contributing to Omarchy Wallpaper Per Monitor. Keep changes
focused, reviewable and compatible with Omarchy 4.

## Before you start

Read the [README](../README.md), then the code itself: the pitfalls that cost
real debugging rounds are documented as comments next to the lines that
motivated them. Pay particular attention to the override resolution order in
`Background.qml`, the QML binding pitfall around `useOverride`, and the
`transform` correction in `bin/wallpaper-monitor`. `Background.qml` runs
inside the user's Omarchy shell and controls what is drawn on every screen in
production, so changes to it — override resolution, fallback behaviour,
transition handling — need extra care and manual verification on a real
multi-monitor setup before merging.

## Development setup

Install Omarchy 4 and Quickshell, then add the plugin to your local Omarchy
setup. There is no build step. Run the syntax and boundary checks:

```bash
bash -n install.sh uninstall.sh bin/wp bin/wallpaper-monitor \
  bin/wallpaper-monitor-menu bin/wallpaper-monitor-common.sh
shellcheck -x install.sh uninstall.sh bin/wp bin/wallpaper-monitor \
  bin/wallpaper-monitor-menu bin/wallpaper-monitor-common.sh
python3 -B -m unittest discover -s tests -v
DRY_RUN=1 ./install.sh
DRY_RUN=1 ./uninstall.sh
omarchy plugin validate .
```

Tests use disposable homes and preserve the desktop configuration.

For local iteration, run `./install.sh` for real (it is idempotent) to
synchronize the tree into
`~/.config/omarchy/plugins/vitorcanoas.background-per-monitor`, then restart
`omarchy-shell` (or your session) to pick up changes to `Background.qml`.
Changes to the JSON config the plugin watches (bounded metadata polling) apply live, without a restart.

Do not edit `/usr/share/omarchy`. Test changes through the user plugin copy
and restore any wallpaper state before removing the plugin. Plugins run
outside a sandbox with no review process, so treat the installed copy as
production code from the first sync.

## Changes and commits

- Keep one concern per commit when practical.
- Use concise, imperative commit subjects, for example
  `docs: clarify override resolution order`.
- Do not include generated files, local configuration, rendered wallpaper
  images or machine-specific screenshots.
- Update the README or changelog when user-visible behaviour or commands
  change.

## Pull requests

Open a pull request against `main` with a short explanation of the problem
and the chosen solution. Include:

- the user-visible impact;
- files and interfaces affected;
- commands used to validate the change;
- Omarchy version and monitor setup (names, orientation, `transform` values)
  when behaviour depends on them;
- screenshots or terminal output when they make a UI or integration change
  easier to review.

Keep unrelated cleanup out of feature or bug-fix pull requests. Maintainers
may ask for a smaller split if a pull request mixes code and documentation
changes.

## Merge expectations

There is no CI in this repository — no `.github/workflows/`, no Makefile, a Python regression suite under `tests/`. Every pull request is
verified manually before it is merged: `bash -n` on any changed script,
`shellcheck` where available, a `DRY_RUN=1` pass of `install.sh`/`uninstall.sh`
for anything touching those scripts, and a deliberate diff review. This is a
solo-maintained project, so an external approval is welcome but not required.
Changes that affect override resolution, file watching or background
transitions should include a reproducible manual verification on real
hardware (ideally with a rotated monitor) described in the pull request,
since there is no automated test to fall back on.

## License

By contributing, you agree that your contribution is provided under the
repository's [MIT license](../LICENSE).
