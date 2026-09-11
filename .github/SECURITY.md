# Security policy

Omarchy Wallpaper Per Monitor is a local Omarchy plugin. Like every Omarchy
plugin, it runs unsandboxed, with the user's own session permissions, inside
the same `omarchy-shell` (Quickshell) process that draws the rest of the
desktop — there is no plugin sandbox or capability restriction in Omarchy
today, and no marketplace review happens before a plugin is installed. This
document describes what this specific plugin does with that access.

## Supported versions

Security fixes target the latest release and the current `main` branch. Older
releases may not receive fixes; update to the latest version before reporting
a problem that may already be resolved.

## Execution surface

`Background.qml` itself starts three external processes, all fixed
command lines with no user-controlled string built into the command:

- `readlink -f <current-background-link>` — resolves the Omarchy theme
  background symlink.
- `bash -c 'background=$(omarchy-theme-bg-switcher); ...'` and
  `bash -c 'theme=$(omarchy-theme-switcher); ...'` — invoked only when the
  user double-clicks the background (left button opens the background
  switcher, right button the theme switcher), both existing Omarchy
  commands with no arguments derived from plugin state.

No other process is started from QML. The command-line tools ship
alongside the plugin but are not invoked by it at runtime:

- `bin/wallpaper-monitor` and `bin/wp` are run directly by the user (or a
  keybinding the user configures) to edit the override file below.
- `bin/wallpaper-monitor-menu` is run from the "Wallpaper per monitor" row
  the installer adds to the SUPER+SPACE menu, so it is the one CLI reached
  indirectly rather than typed.

Neither the shell nor any other plugin process invokes any of the three.

### Files read

- `~/.config/omarchy/background-per-monitor.json` — this plugin's own
  per-monitor override config, read live via Quickshell's `FileView`
  (`watchChanges: true`).
- `~/.local/state/omarchy/current/background` — the standard Omarchy
  wallpaper symlink, resolved with `readlink -f`; not written by this
  plugin.
- Whatever image paths appear in `background-per-monitor.json` or in the
  Omarchy background symlink, loaded as `Image.source` for display.
- `~/.config/omarchy/shell.json` — read by `install.sh`/`uninstall.sh` only,
  never by the running plugin.

### Files written

- `~/.config/omarchy/background-per-monitor.json` — written only by the
  `wallpaper-monitor` CLI (and transitively by `wp`, which shells out to it).
  `Background.qml` never writes this file; it only watches and reads it.
- `~/.config/omarchy/shell.json` — written only by `install.sh` and
  `uninstall.sh`, during an explicit, user-initiated install or uninstall.
  Never touched at runtime.
- `~/.local/bin/{wallpaper-monitor,wp,wallpaper-monitor-menu}` — symlinks
  created by `install.sh` and removed by `uninstall.sh`.

## The `IpcHandler` on target `"background"`

`Background.qml` registers `IpcHandler { target: "background" }` — the same
IPC target name the native `omarchy.background` plugin uses. This is
deliberate, not an oversight, and should not be
renamed.

Omarchy's own shell scripts drive theme and background changes through this
exact target, with no way to point them elsewhere:

```
/usr/share/omarchy/bin/omarchy-theme-bg-set -> omarchy-shell -q background set "$BACKGROUND"
/usr/share/omarchy/bin/omarchy-theme-set    -> shell_ipc background themeTransition ...
```

`omarchy theme bg set` and `omarchy theme set` both call `target: "background"`
by name. IPC calls in Quickshell are fire-and-forget: if no handler is
listening on that target, the command still exits `0`, and the wallpaper
simply never changes, with no error surfaced to the user. Renaming the
handler to something plugin-specific (e.g. `"background-per-monitor"`) would
silently disconnect this plugin from both of those commands.

In practice there is no live collision: `install.sh` adds
`omarchy.background` to `disabledPlugins[]` in `shell.json` as part of
installing this plugin, so the native handler for the same target is disabled
and this plugin's handler is the only one actually running — this is a
deliberate replacement, not two active handlers competing for the same name.

This was validated with a real theme switch (Tokyo Night → Gruvbox → Tokyo
Night) with the plugin active on 2026-09-06: the theme changed correctly and
each monitor's per-monitor override wallpaper stayed in place throughout, with
no `IpcHandler`/target `"background"` collision warning in the log. The
collision warnings that do appear in a normal session log come from other,
unrelated plugins (`power`, `weather`, `tailscale`, `which-key`, `nightlight`
were observed), not from this one.

## User configuration writes

### `~/.config/omarchy/background-per-monitor.json` (this plugin's own config)

Written exclusively by `bin/wallpaper-monitor`, at runtime, on explicit user
command (`set`, `set-portrait`, `set-landscape`, `clear`, `clear-portrait`,
`clear-landscape`). The write path (all in `bin/wallpaper-monitor`):

- **Locking**: a per-directory lock (`mkdir` on a `.lock.d` path under
  `XDG_RUNTIME_DIR`, or a private, mode-`0700` per-UID fallback directory
  under `/tmp` when `XDG_RUNTIME_DIR` is unusable) serializes the entire
  read-modify-write cycle across concurrent invocations, with a PID file used
  to detect and reclaim a lock left behind by a dead process. The lock is
  acquired by directory, deliberately **not** `flock 9>path`: a bare `9>path`
  redirection opens (and can create) the lock file by following whatever is
  at that path, including a symlink planted there by another process, before
  `flock` ever gets a chance to lock it. `mkdir` does not follow a symlink at
  its final path component, so the same attack against the lock path fails
  outright. This is the same technique already reviewed and accepted in
  `vitorcanoas/omarchy-nightlight` PR #8 (commit `78d9fb4`), for the same
  reason.
- **Read validation**: the target file is opened with `O_NOFOLLOW`
  (rejecting a symlink at the final path component), then checked to be a
  regular file, owned by the invoking user (`st_uid == geteuid()`), and no
  larger than 1 MiB before any byte is read; the read itself is bounded to
  that same limit. A file that exists but fails any of these checks — wrong
  owner, wrong type, oversized, or content that isn't valid UTF-8 JSON
  object — aborts the command with a clear error and changes nothing; only a
  genuinely absent file is treated as "not configured yet" (starts from
  `{}`). This distinction (`load_target` returning "doesn't exist" vs.
  raising on "exists but unreadable") is what lets `wallpaper-monitor list`
  stay strictly read-only even against a corrupted file, instead of
  "repairing" it by overwriting it.
- **Atomic write**: a new content is written to a temp file created with
  `tempfile.mkstemp()` in the *same directory* as the target (never `/tmp`,
  so the final `os.replace` is a same-filesystem rename), flushed and
  `fsync`'d, `chmod`'d to match the original file's mode (or `0644` for a new
  file — `mkstemp` itself creates `0600`, which would otherwise make the
  config unreadable for the rest of the user's session), then moved into
  place with `os.replace` (atomic on POSIX). The containing directory is
  then opened and `fsync`'d too, so a rename that already completed cannot be
  lost by a crash or power loss immediately after.
- No external data is ever interpolated into the embedded Python source.
  Every value that reaches the Python helper (JSON path, monitor name, image
  path) crosses the boundary as a quoted `argv` element or via `sys.argv`,
  never string-substituted into the script text itself.

### `~/.config/omarchy/shell.json` (the Omarchy system config)

Written **only** by `install.sh` and `uninstall.sh`, and only during an
explicit, user-run install or uninstall — never while the plugin or shell is
running. Both scripts:

- back up the existing file first, as `shell.json.bak.<timestamp>` (with
  nanosecond resolution to avoid same-second collisions between repeated
  runs), before making any change;
- write through a temp file (`mktemp`) plus `mv` into place, rather than
  editing in place;
- merge with `jq`, reading and rewriting only the `plugins[]`,
  `disabledPlugins[]` and `cloneSourceRestores[]` arrays (deduplicated by
  plugin `id`), leaving every other field in `shell.json` untouched;
- are idempotent — re-running `install.sh` does not add a duplicate
  `plugins[]` entry, and `uninstall.sh` only removes `omarchy.background`
  from `disabledPlugins[]` if this plugin's own id is still present in
  `plugins[]` at the time it runs, since `shell.json` does not record which
  installer disabled the native plugin.

Neither script is invoked automatically by Omarchy (there is no install or
uninstall hook), and neither is invoked by anything at plugin runtime.

## Input validation

- **Image paths** (`wallpaper-monitor set`/`set-portrait`/`set-landscape`,
  and QML's `selectOverride`): a relative path is rejected. QML's
  `selectOverride` only accepts a path that starts with `/` or with `~/`
  (expanded against `$HOME`); anything else resolves to `""` and falls
  through to the next item in the precedence order. The CLI additionally
  resolves the path with `realpath -m`, requires the target to exist, and
  checks its MIME type with `file --mime-type` (falling back to an
  extension allow-list if `file` is unavailable) before writing it into the
  config.
- **Monitor names** (`wallpaper-monitor set`/`clear`, `wp`'s internal
  handling of `hyprctl` output): validated against
  `^[A-Za-z0-9._:-]+$`. Monitor names come from kernel connector identifiers
  (`DP-2`, `HDMI-A-1`, `eDP-1`, …), which are always in that shape; this
  check exists to catch a typo or a garbled name before it is silently
  written into the config and the wallpaper just fails to appear — it is not
  a defense against code injection, because monitor names and image paths
  are never interpolated into a command string or into the embedded Python
  source in the first place; they always cross into both the shell script
  and the Python helper as separate `argv` elements.
- **Malformed JSON**: in `Background.qml`, `loadPerMonitorOverrides` wraps
  `JSON.parse` in `try/catch` and falls back to `{}` with a `console.warn`,
  so a broken config file degrades to "no overrides" rather than crashing the
  shell. In the CLIs, the equivalent condition (existing file, unreadable or
  not a JSON object) aborts the command with a non-zero exit and changes
  nothing on disk — see "Read validation" above.

## Network and credentials

This plugin makes no network requests and reads no credentials. `Background.qml`
only starts the three local processes listed under "Execution surface"
above (`readlink`, and the two Omarchy switcher commands on user
double-click); `wallpaper-monitor` and `wp` call `hyprctl`, `python3`, `file`
and standard coreutils, all local. This was confirmed by reading the full
source of `Background.qml`, `bin/wallpaper-monitor`, and `bin/wp` — none of
them contain a URL fetch, a socket call, or any reference to a credential
store.

## Symlinks

No symlink exists inside this plugin's source tree or its installed copy —
confirmed against the repository contents. Omarchy's plugin rules prohibit
symlinks inside an installed plugin directory
(`~/.config/omarchy/plugins/<id>/`), which is why `install.sh` populates that
directory with `rsync`, not `ln -s`.

The three symlinks `install.sh` creates
(`~/.local/bin/{wallpaper-monitor,wp,wallpaper-monitor-menu}`) are outside
the plugin directory and are permitted: the no-symlink rule is about the
installed plugin's own contents, not about `PATH` shortcuts that point into
it. `install.sh` refuses to overwrite a pre-existing file at any of those
three paths unless it is already a symlink of its own making, and
`uninstall.sh` only removes a symlink whose resolved target lives inside this
plugin's installed `bin/` directory — a real file, or a symlink to something
else, is left untouched.

## Scope and limitations

This plugin is intended for a single user's local desktop. Reports involving
a malicious local user, shared runtime directories, symlink races, JSON
config tampering, `IpcHandler`/target collisions, or the install/uninstall
scripts' handling of `shell.json` are relevant even if the impact is limited
to the user's own session. A report should explain the required
preconditions and whether it affects confidentiality, integrity or
availability.

Omarchy, Quickshell, and Hyprland are separate projects. Vulnerabilities in
those projects should be reported to their respective maintainers, but
integration impact in this plugin is still useful to document here.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
private vulnerability reporting for this repository when it is available. If
that option is not available, contact the maintainer privately through the
repository owner's GitHub profile before disclosing details publicly.

Include, when safe:

- a clear description of the impact;
- affected version or commit;
- the relevant operating-system and Omarchy versions;
- reproducible steps or a minimal proof of concept;
- any proposed mitigation.

Do not include passwords, access tokens, private configuration or personal
data in a report. Please allow time for triage and a coordinated fix before
public disclosure.
