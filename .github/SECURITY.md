# Security policy

This plugin replaces `omarchy.background` inside the user's Quickshell session.
It runs with the user's permissions, without a sandbox. Its public IPC target
remains `background`, with `refresh`, `set`, `setInstant`, `transition` and
`themeTransition`, because Omarchy calls those interfaces directly.

## Execution and environment

The five shell entry points use `/usr/bin/bash -p`, which ignores inherited
Bash startup files and exported functions. Invoke the scripts directly; an
explicit `bash script` invocation bypasses the shebang's startup options.
The shared preamble removes export attributes outside an explicit session
allowlist, fixes the interpreter and tool paths, and validates system tools
as root-owned regular executable files under non-writable root-owned parents.
The installed plugin code itself is trusted code owned by the user.

QML clears the process environment before launching any child. The Python
helper uses isolated mode (`-I -B`) and constructs a child environment with
fixed PATH and OMARCHY_PATH. GUI/session addresses needed by Omarchy and
Hyprland are passed explicitly.

The helper supervises local tools with stdout and stderr byte/line limits,
a deadline, a separate session/process group, Linux child-subreaper adoption,
and TERM followed by KILL. Cleanup checks that the group and adopted children
are gone. Linux `/proc` is required. The QML watchdog allows the helper time to
finish cleanup before escalating. Interactive pickers have a 120-second
selection deadline. Root-owned Omarchy helpers remain an upstream trust
boundary, including the user hooks and theme configuration they intentionally
execute.

## Configuration and files

- `~/.config/omarchy/background-per-monitor.json`: read by the bounded helper;
  written only by explicit CLI commands. QML polls metadata about every two
  seconds and never opens this JSON through FileView.
- `~/.local/state/omarchy/current/background`: the standard wallpaper link,
  resolved through bounded link traversal. Image paths are passed to Qt for
  rendering; this plugin does not sandbox Qt's image decoders.
- `~/.config/omarchy/shell.json`: the installer registers this plugin, disables
  the native background and records `cloneSourceRestores`. Uninstall reverses
  this plugin's entries while preserving unrelated configuration.
- `~/.config/omarchy/extensions/omarchy-menu.jsonc`: a marker-delimited menu
  entry is added/removed as text, preserving the surrounding JSONC.
- `~/.config/omarchy/plugins/vitorcanoas.background-per-monitor/`: only the
  explicit runtime/documentation payload allowlist is copied here.
- `~/.local/bin/{wallpaper-monitor,wp,wallpaper-monitor-menu}`: symlinks to the
  installed CLI scripts; foreign files/links are preserved.

Configuration path components are opened relative to directory descriptors
with `O_NOFOLLOW`; validated parent descriptors remain open through writes,
renames and removal. User configuration directories must be owned by the user
and not group/other writable. Files must be regular, user-owned, not
group/other writable, and within the 256 KiB configuration budget. Reads use
`O_NONBLOCK` plus type checks so a FIFO is rejected without blocking.

Updates stage an unpredictable exclusive file in the held parent directory,
preserve existing permission bits, fsync, revalidate the original target,
rename relative to the parent descriptor, and fsync that directory. CLI
read/migration/write sequences hold an advisory flock on the validated config
directory; there is no pathname-opened pid file or stale-lock cleanup.
Advisory locks serialize cooperating CLI processes, not arbitrary programs
running with the same UID. Descriptor retention prevents directory symlink
redirection; it does not stop that user from modifying their own plugin code.

Malformed or unsafe override configuration is refused. The CLI reports an
error without treating corrupt content as an empty configuration. QML falls
back to the normal theme background for an invalid override. Installers back
up existing configuration and offer `DRY_RUN=1` staging under HOME. Neither
installation nor runtime downloads code, requests privilege elevation, or
installs system services.

## Reporting

Reports about local symlink races, configuration tampering, process cleanup,
resource bounds and install/uninstall behavior are in scope. Include the
commit, prerequisites, a minimal reproducer and the observed impact. Do not
include credentials or private configuration.

Use GitHub private vulnerability reporting when available; otherwise contact
the maintainer privately through the repository owner's profile before public
disclosure. Upstream Omarchy, Hyprland and Quickshell vulnerabilities should
also be reported to their respective maintainers.
