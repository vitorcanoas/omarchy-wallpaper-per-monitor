# Contributing

Thank you for contributing to Omarchy Wallpaper Per Monitor. Keep changes
focused, reviewable and compatible with Omarchy 4.

## Before you start

Read the [README](README.md) and the [technical background](docs/CONTEXTO.md),
especially the sections on the override resolution order, the QML binding
pitfall around `useOverride`, and the render pipeline. `Background.qml` runs
inside the user's Omarchy shell and controls what is drawn on every screen in
production, so changes to it — override resolution, fallback behaviour,
transition handling — need extra care and manual verification on a real
multi-monitor setup before merging.

## Development setup

Install Omarchy 4 and Quickshell, then add the plugin to your local Omarchy
setup. From the repository root:

```bash
make validate
make lint
```

For local iteration, `make dev` synchronizes the tree into
`~/.config/omarchy/plugins/vitorcanoas.background-per-monitor` and asks the
shell to rescan plugins. Review the value of `PLUGIN_DIR` before using it; the
command updates the installed plugin directory.

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
may ask for a smaller split if a pull request mixes code, render-pipeline and
documentation changes.

## Merge expectations

Every pull request must have green CI and a deliberate diff review before it
is merged. This is a solo-maintained project, so an external approval is
welcome but not required. Changes that affect override resolution, file
watching, background transitions or the render pipeline should include a
focused test or a reproducible manual verification on real hardware.

## License

By contributing, you agree that your contribution is provided under the
repository's [MIT license](LICENSE).
