#!/usr/bin/python3
"""Descriptor-relative, no-follow, bounded, revalidating filesystem helper.

Port of the marketplace-approved
`omarchy-nightlight/bin/omarchy-nightlight-config.py` (commit 78d9fb4) onto
this plugin's boundaries, extended with exactly the subcommands this plugin's
five callers invoke. Function names, flag sets, validation order and the
publish transaction are kept deliberately identical to the reference so a
reviewer diffing the two files sees the same code; every divergence is marked
with a comment saying WHY.

Invocation
----------
    "$PYTHON3" -I -B "$WPM_HELPER" <subcommand> [options] [-- <child argv>]

Never executed directly. Line 1 above IS a shebang, and it is never consulted:
this file ships mode 0644 with no executable bit, and every call site spells
the interpreter out as an absolute path ("$PYTHON3" -I -B <helper>, where
$PYTHON3 is /usr/bin/python3 validated by check-tool), so the kernel is never
asked to read line 1. The missing executable bit is the control, not the
shebang text; the shebang is kept only so a reader who opens the file knows
which interpreter it is written for. `-I` neutralises
PYTHONPATH/PYTHONHOME/site; `-B` keeps __pycache__ out of the plugin dir.

Subcommand surface -- exactly these eleven
------------------------------------------
One per operation the five callers actually perform. Nothing is defined here
that nothing calls: an unreachable subcommand is attack surface that no test
and no reviewer ever exercises.

  read          --root R --rel P [--max-bytes N] [--allow-missing]
  stat          --root R --rel P [--allow-missing]
  edit          --root R --rel P [--mode OCT] [--max-output-bytes N]
                [--deadline-ms N] -- <filter argv>
  mkdir-chain   --root R --rel D [--mode OCT]
  install-file  --src-root R1 --src-rel A --dst-root R2 --dst-rel B --mode OCT
                [--max-bytes N]
  prune-dir     --root R --rel D (--keep REL)... [--remove-all] [--if-exists]
  unlink        --root R --rel P [--if-exists] [--expect-dev-ino DEV:INO]
  symlink       --root R --rel P --target T [--replace]
  resolve-link  --root R --rel P [--max-hops N] [--require-regular]
  run           [--setsid] [--deadline-ms N] [--kill-grace-ms N]
                [--max-output-bytes N] [--max-lines N] [--max-line-bytes N]
                [--stderr-to-null] -- <child argv>
  check-tool    (--path ABS)...

Common options, accepted by every filesystem subcommand: --expect-dev-ino and
--if-exists. That is the whole common set, for the same reason: an option no
caller passes is a code path nobody exercises.

Call sites served
-----------------
Line numbers are deliberately NOT quoted below -- they go stale the moment any
of the five callers is edited, and a stale pointer is worse than a description.

  read          the four readers of ~/.config/omarchy/background-per-monitor.json
                -- load_target() in bin/wallpaper-monitor, bin/wp's resolver,
                bin/wallpaper-monitor-menu's two readers -- and Background.qml's
                bounded read of the same file.
  edit          write_atomic() in bin/wallpaper-monitor and every *_locked
                mutation; finalize_shell_json() in install.sh and uninstall.sh
                (duplicated verbatim) for both shell.json and the JSONC menu
                file. Their jq and awk programs are reused BYTE-IDENTICAL as
                the filter argv.
  mkdir-chain   every `mkdir -p` in install.sh, uninstall.sh and
                bin/wallpaper-monitor's config-directory setup.
  install-file  the per-file half of install.sh's `rsync -a --delete` copy plus
                the `chmod +x` that followed it, and the backup copies in
                install.sh and uninstall.sh, which are a same-directory
                install-file carrying the source's mode.
  prune-dir     the `--delete` half of that same rsync, and uninstall.sh's
                `rm -rf` of the plugin directory.
  stat          every `[[ -L ]]` / `[[ -f ]]` / `stat -c %a` probe in install.sh
                and uninstall.sh, and bin/wallpaper-monitor's pre-write probe.
  resolve-link  every `readlink -f`: the symlink audits in install.sh and
                uninstall.sh, bin/wp's and bin/wallpaper-monitor-menu's resolver,
                and Background.qml's current-background resolution.
  symlink       link_one() in install.sh and the restore path in uninstall.sh.
  unlink        uninstall.sh's unlink_one().
  run           every unbounded `$( ... )`: hyprctl in bin/wp and
                bin/wallpaper-monitor, `file -b --mime-type` in
                bin/wallpaper-monitor, omarchy-menu-select / omarchy-menu-images
                in bin/wallpaper-monitor-menu, and Background.qml's two selector
                stages -- the picker and omarchy-theme-set.
  check-tool    the shared preamble's resolve-once tool table, and the four
                lock primitives bin/wallpaper-monitor pins by absolute path.

Exit codes
----------
  0  success
  1  boundary violation -- symlink encountered, not a regular file, wrong
     owner, group/other-writable, over the byte cap, malformed, ELOOP, ENOTDIR.
     NOTHING WAS CHANGED.
  2  usage -- bad argv, unknown subcommand, invalid --rel component
  3  transaction failed -- same_target() mismatch, temp creation exhausted,
     filter exited non-zero, publish failed.  NOTHING WAS PUBLISHED.
  4  absent -- target missing where presence was required
  5  identity mismatch -- --expect-dev-ino did not match
  6  output cap exceeded -- producer over budget; its group was torn down
  7  deadline exceeded -- group was torn down and reaped
  128+N  killed by signal N

These eleven numbers are load-bearing: Background.qml, install.sh, uninstall.sh
and the three CLIs all branch on them today, and `bin/wallpaper-monitor`'s own
EXIT_UNREADABLE=2 / EXIT_LOCK=3 are reached through the caller-side
`wpm_map_exit()` in bin/wallpaper-monitor-common.sh (1|4|5|6 -> EXIT_UNREADABLE,
3|7 -> EXIT_LOCK, 2 -> 1). No user-visible exit code changed in the migration,
and none may change now.

Errors are ONE bounded line on stderr:
    wallpaper-monitor-config: <subcommand>: <message>
A traceback is never printed: it leaks absolute paths and interpreter internals
into whatever log the caller is teeing, and callers branch only on the exit
code.

THE ONE DELIBERATE DIVERGENCE FROM THE APPROVED REFERENCE
---------------------------------------------------------
The reference always publishes mode 0600, because nightlight.conf is read by
nothing but nightlight. This plugin writes files the Omarchy shell reads --
notably ~/.config/omarchy/shell.json, typically 0644 -- and stamping 0600 onto
them would be a behaviour regression, not a hardening. So:

  * an EXISTING target keeps its own mode: the temp is fchmod'ed, on the held
    temp descriptor, to the mode read off the TARGET'S OWN VALIDATED
    DESCRIPTOR -- never off a pathname `stat`, which is what install.sh does
    today in finalize_shell_json's mode probe and which reports a symlink's
    0777 and then stamps it onto the real file;
  * a NEW target gets 0600, or --mode when the caller declares one;
  * either way a group- or other-writable target is REFUSED, and a --mode with
    0o022 bits set is REFUSED. Preserving a mode is not accepting any mode: we
    preserve only modes that already passed the boundary check.

`install-file` is the documented exception and says so at its definition: a
payload file's mode is declared by the installer's allowlist (0644/0755), so
there --mode is authoritative. That is what replaces the installer's separate
`chmod +x`, making the executable bit travel with the allowlist entry.

Python 3 standard library only, so it runs under the system python3 with -I.
"""

from __future__ import annotations

import ctypes
import errno
import fcntl
import json
import os
import secrets
import select
import signal
import stat
import sys
import time


PROGNAME = "wallpaper-monitor-config"

EXIT_OK = 0
EXIT_BOUNDARY = 1
EXIT_USAGE = 2
EXIT_TRANSACTION = 3
EXIT_ABSENT = 4
EXIT_IDENTITY = 5
EXIT_OUTPUT_CAP = 6
EXIT_DEADLINE = 7

# --- Caps: ONE source of truth ------------------------------------------
#
# The status quo before this helper existed was both too loose and
# inconsistent, which is why the cap lives here and only here:
# bin/wallpaper-monitor declared a 1 MiB cap, and bin/wp and
# bin/wallpaper-monitor-menu (twice) each re-declared the same 1 MiB as a bare
# literal sitting next to an UNBOUNDED `fh.read()`. Four copies of a number
# only one of them enforced.
#
# 256 KiB -- not the reference's 64 KiB and not 1 MiB:
#   * the override map is a handful of monitor names and paths, a few hundred
#     bytes in practice, and MAX_ENTRIES is the real bound on it;
#   * shell.json is a whole-shell config carrying every plugin's settings, which
#     64 KiB could plausibly clip on a heavily configured machine -- and
#     clipping it is data loss, not a safety win;
#   * install-file also publishes the payload, whose largest member is
#     Background.qml at ~25 KiB;
#   * 256 KiB still bounds a hostile file to something the os.read loop
#     finishes in microseconds and that no caller can turn into memory
#     pressure. 1 MiB bought nothing over this and was 16x looser.
#
# --max-bytes may only LOWER this, never raise it (see bounded_budget), so this
# constant stays the ceiling no matter what a caller passes. That is what makes
# it a single source of truth rather than a default.
MAX_FILE_BYTES = 256 * 1024

# Entry cap for JSON objects. The reference used 1024; the override map is
# keyed by monitor name plus two orientation keys, and 64 monitors is already
# an absurd desk, so 256 is generous.
MAX_ENTRIES = 256

# A single path value, and the length of a symlink target.
MAX_PATH_BYTES = 4096

# Linux NAME_MAX. Longer components are rejected before reaching the kernel so
# the error says what happened instead of surfacing ENAMETOOLONG.
MAX_COMPONENT_BYTES = 255

READ_CHUNK = 8192           # matches the reference (config.py:121)
TEMP_ATTEMPTS = 16          # matches the reference (config.py:239)
DIR_MODE_DEFAULT = 0o700    # matches the reference (config.py:57)
FILE_MODE_DEFAULT = 0o600   # new-file mode; see the divergence note above

# prune-dir guards.
MAX_PRUNE_ENTRIES = 4096
MAX_PRUNE_DEPTH = 16

# resolve-link guards.
DEFAULT_LINK_HOPS = 1
MAX_LINK_HOPS = 8

# run / edit supervision defaults.
DEFAULT_DEADLINE_MS = 5000
# 1000 ms, and it is load-bearing: Background.qml's own watchdog is 2000 ms, so
# the helper must have finished escalating TERM -> KILL and reaped its group
# before QML gives up on the helper itself. If this ever exceeds that, QML
# starts killing a helper that is still cleaning up, and the grandchildren
# survive -- which is exactly the escape the moderator rejected.
DEFAULT_KILL_GRACE_MS = 1000
DEFAULT_MAX_OUTPUT_BYTES = 65536
DEFAULT_MAX_LINES = 4096
DEFAULT_MAX_LINE_BYTES = 8192

# Ceiling on anything printed that is not file payload (stat output, a resolved
# link, an error line). Payload output is bounded by the byte caps; this bounds
# everything else, so no code path can emit unbounded data.
MAX_MESSAGE_BYTES = 512

PR_SET_PDEATHSIG = 1


class ConfigError(Exception):
    """An unsafe, malformed, or unavailable filesystem boundary.

    Carries the exit code the caller should see. The default is
    EXIT_BOUNDARY, because that is the honest answer for a rejection: the
    boundary did not hold up, and nothing was changed.
    """

    def __init__(self, message: str, code: int = EXIT_BOUNDARY) -> None:
        super().__init__(message)
        self.code = code


def fail(message: str, code: int = EXIT_BOUNDARY) -> None:
    raise ConfigError(message, code)


def fail_os(message: str, error: OSError, code: int = EXIT_BOUNDARY) -> None:
    # strerror is already in the message, which is the whole of what the caller
    # sees; the symbolic errno name was only ever consumed by the removed
    # --json-errors output shape.
    raise ConfigError("%s: %s" % (message, error.strerror or error), code)


def usage_error(message: str) -> None:
    raise ConfigError(message, EXIT_USAGE)


def transaction_error(message: str) -> None:
    raise ConfigError(message, EXIT_TRANSACTION)


# --- Bounded output ------------------------------------------------------


def sanitize(text: str) -> str:
    """One line, no control characters, bounded length.

    Names and messages reaching here came from argv or from a directory an
    attacker may influence. Echoing a newline or an escape sequence into a log
    the caller greps is a needless liability, and an unbounded message is
    unbounded output.
    """
    flat = "".join(ch if ch.isprintable() else "?" for ch in text)
    encoded = flat.encode("utf-8", "replace")
    if len(encoded) > MAX_MESSAGE_BYTES:
        encoded = encoded[: MAX_MESSAGE_BYTES - 3] + b"..."
    return encoded.decode("utf-8", "replace")


def write_fd(fd: int, data: bytes) -> None:
    """Bound writes too: a stalled consumer must not hold a supervisor alive."""
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    deadline = time.monotonic() + 1.0
    poller = select.poll()
    poller.register(fd, select.POLLOUT)
    offset = 0
    try:
        while offset < len(data):
            if time.monotonic() >= deadline:
                fail("output consumer stopped reading", EXIT_DEADLINE)
            try:
                offset += os.write(fd, data[offset:])
            except BlockingIOError:
                poller.poll(50)
            except BrokenPipeError:
                return
    finally:
        fcntl.fcntl(fd, fcntl.F_SETFL, flags)


def emit_line(text: str) -> None:
    write_fd(1, (sanitize(text) + "\n").encode("utf-8", "replace"))


def emit_bytes(data: bytes) -> None:
    """File payload. `data` is already capped by read_bounded."""
    write_fd(1, data)


# --- Component and path validation ---------------------------------------


def check_component(component: str) -> str:
    """Validate ONE path component before it is handed to openat/mkdirat.

    Rejecting `.` and `..` here is what makes `--rel` unable to climb out of
    the validated root: every remaining component can only descend, and every
    descent is O_NOFOLLOW, so there is no way to leave the subtree.
    """
    if not component:
        usage_error("path contains an empty component")
    if component in (".", ".."):
        usage_error("path contains a '.' or '..' component")
    if "\0" in component:
        usage_error("path contains a NUL byte")
    if "/" in component:
        usage_error("path component contains a separator")
    if len(component.encode("utf-8", "surrogateescape")) > MAX_COMPONENT_BYTES:
        usage_error("path component is longer than %d bytes" % MAX_COMPONENT_BYTES)
    return component


def split_rel(rel: str) -> list[str]:
    """Split --rel into validated components.

    Splitting happens HERE, not in the shell, so a component cannot be
    smuggled past validation by quoting, and `a//b` or a trailing slash is an
    error rather than something silently normalised into a different path.
    """
    if not rel:
        usage_error("--rel is empty")
    if rel.startswith("/"):
        usage_error("--rel must be relative, not absolute")
    if rel.endswith("/"):
        usage_error("--rel must not end with '/'")
    return [check_component(part) for part in rel.split("/")]


def check_root(root: str) -> list[str]:
    if not root:
        usage_error("--root is empty")
    if not root.startswith("/"):
        usage_error("--root must be an absolute path")
    if "\0" in root:
        usage_error("--root contains a NUL byte")
    return [check_component(part) for part in root.split("/") if part]


def parse_mode(text: str) -> int:
    """Parse an octal mode and refuse one that hands write access away.

    A caller asking for 0666 is asking us to create the exact object the
    boundary checks exist to reject, so the refusal belongs here rather than
    two steps later at the fstat.
    """
    try:
        mode = int(text, 8)
    except ValueError:
        usage_error("mode is not octal")
    if not 0 <= mode <= 0o7777:
        usage_error("mode is out of range")
    if mode & 0o022:
        fail("refusing a group- or other-writable mode (%04o)" % mode)
    return mode


def parse_positive(text: str, what: str) -> int:
    try:
        value = int(text, 10)
    except ValueError:
        usage_error("%s is not a base-10 integer" % what)
    if value < 0:
        usage_error("%s is negative" % what)
    return value


def bounded_budget(text: str | None, ceiling: int = MAX_FILE_BYTES) -> int:
    """--max-bytes may only tighten a cap, never loosen it.

    If a caller could raise the ceiling, MAX_FILE_BYTES would be a default and
    the loosest call site would silently become the real limit -- exactly the
    state the four pre-existing readers were in, each with its own cap and
    only one of them enforcing it.
    """
    if text is None:
        return ceiling
    value = parse_positive(text, "--max-bytes")
    if value == 0:
        usage_error("--max-bytes must be greater than zero")
    return min(value, ceiling)


def parse_dev_ino(text: str) -> tuple[int, int]:
    parts = text.split(":")
    if len(parts) != 2:
        usage_error("--expect-dev-ino must be DEV:INO")
    return parse_positive(parts[0], "dev"), parse_positive(parts[1], "ino")


def normalize_absolute(path: str) -> str:
    """Lexical normalisation only -- NO filesystem access.

    This is `realpath -m`'s contract: collapse `.`, `..` and `//` without
    touching the disk. Anything that needs the disk goes through the
    descriptor walk instead, where each step can be validated.
    """
    parts: list[str] = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if parts:
                parts.pop()
            continue
        parts.append(part)
    return "/" + "/".join(parts)


# --- The no-follow walk (port of config.py:41-68) -------------------------


def open_directory_path(components: list[str], create: bool, mode: int,
                        owner_rule: str) -> int | None:
    """Walk an absolute path with openat-style no-following at every level.

    Straight port of the reference's open_directory_path (config.py:41-68).
    The whole pathname is NEVER handed to the kernel as one string: `/` is
    opened, then each component is opened relative to the previous descriptor
    with O_NOFOLLOW, and the previous descriptor is closed immediately.

    This is what defeats the same-UID directory swap. Resolving
    ~/.config/omarchy/shell.json as one pathname lets anything that can write
    ~/.config replace `omarchy` with a symlink between the check and the open,
    and the kernel follows it in silence. Here that swap makes the openat of
    `omarchy` return ELOOP and the operation aborts having changed nothing.

    owner_rule: "none" for the components above a trusted root (/ and /home
    belong to root and always will -- the reference makes the same exemption),
    or "system" for the tool walk, where root-owned or ours are both fine.
    """
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    dirfd: int | None = None
    try:
        dirfd = os.open("/", flags)
        index = 0
        for component in components:
            index += 1
            try:
                nextfd = os.open(component, flags, dir_fd=dirfd)
            except FileNotFoundError:
                if not create:
                    os.close(dirfd)
                    return None
                try:
                    os.mkdir(component, mode, dir_fd=dirfd)
                except FileExistsError:
                    # Someone created it between our open and our mkdir. The
                    # open below is still O_NOFOLLOW, so if what they created
                    # is a symlink we fail there rather than here.
                    pass
                nextfd = os.open(component, flags, dir_fd=dirfd)
            os.close(dirfd)
            dirfd = nextfd
            info = os.fstat(dirfd)
            if owner_rule in ("system", "tool"):
                if info.st_uid not in ((0,) if owner_rule == "tool" else (0, os.geteuid())):
                    fail("a parent directory is owned by another user")
                if info.st_mode & 0o022:
                    fail("a parent directory is writable by another user")
        return dirfd
    except OSError as error:
        if dirfd is not None:
            os.close(dirfd)
        fail_os("could not open directory safely", error)
    except BaseException:
        if dirfd is not None:
            os.close(dirfd)
        raise


def validate_dirfd(dirfd: int) -> os.stat_result:
    """Validate a directory on its OWN fstat (port of config.py:70-86).

    fstat, not stat: the descriptor is the thing we are about to write
    through, so it is the thing that must be checked. A pathname stat answers
    a question about whatever the name resolves to at that instant, which is a
    different object from the one the next syscall will use.
    """
    directory_stat = os.fstat(dirfd)
    if not stat.S_ISDIR(directory_stat.st_mode):
        fail("parent is not a directory")
    if directory_stat.st_uid != os.geteuid():
        fail("parent directory is not owned by the current user")
    if directory_stat.st_mode & 0o022:
        fail("parent directory is writable by another user")
    return directory_stat


def open_root(root: str) -> int:
    """Open and validate the trusted root, holding its descriptor.

    Note the asymmetry, which is the reference's (config.py:70-86) and is
    deliberate: components ABOVE the root are traversed O_NOFOLLOW but not
    owner-checked, because / and /home belong to root and always will. The
    root itself gets the full fstat validation. A symlinked $HOME therefore
    fails -- intentionally, and identically to the approved reference.

    There is no escape hatch for a symlinked $HOME. One used to exist here as
    a --root-follow-final flag that re-opened the last component following
    symlinks; no caller in the plugin ever passed it, so it was an unexercised
    way to weaken the root check and it is gone. If a symlinked $HOME ever has
    to be supported, it must be designed and tested, not left lying here.
    """
    components = check_root(root)
    opened = open_directory_path(components, False, DIR_MODE_DEFAULT, "none")
    if opened is None:
        fail("root directory does not exist", EXIT_ABSENT)
    dirfd = opened
    try:
        validate_dirfd(dirfd)
    except BaseException:
        os.close(dirfd)
        raise
    return dirfd


def descend(dirfd: int, components: list[str], create: bool, mode: int) -> int:
    """Descend below an already-validated root, one validated component at a
    time, closing the previous descriptor at each step.

    Every component below the root IS owner-checked: unlike / and /home these
    are all inside the user's own tree, so anything here owned by someone else
    is a finding, not a fact of life.

    Takes ownership of `dirfd`: on failure it is closed here, so callers must
    not close it again. (A double close is worse than a leak -- the second one
    can land on an unrelated descriptor opened in between.)
    """
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    current = dirfd
    index = 0
    try:
        for component in components:
            index += 1
            try:
                nextfd = os.open(component, flags, dir_fd=current)
            except FileNotFoundError:
                if not create:
                    fail("directory component does not exist", EXIT_ABSENT)
                try:
                    os.mkdir(component, mode, dir_fd=current)
                except FileExistsError:
                    pass
                nextfd = os.open(component, flags, dir_fd=current)
            except OSError as error:
                # ELOOP here is the symlinked-intermediate-component case:
                # exactly the swap the per-component walk exists to catch.
                fail_os("could not descend safely", error)
            os.close(current)
            current = nextfd
            validate_dirfd(current)
        return current
    except BaseException:
        os.close(current)
        raise


def open_parent(root: str, rel: str, create: bool = False,
                mode: int = DIR_MODE_DEFAULT) -> tuple[int, str]:
    """Return (parent dirfd, basename) for a --root/--rel target.

    The returned descriptor is THE descriptor for the whole transaction. It is
    never re-derived from a pathname: validation, temp creation, revalidation,
    rename and fsync all go through this one fd. That is the invariant the
    shell code breaks in install.sh's finalize_shell_json and in
    bin/wallpaper-monitor's write_atomic, where the directory is re-opened by
    name AFTER the rename -- possibly a different directory than the one the
    rename landed in.
    """
    components = split_rel(rel)
    basename = components[-1]
    rootfd = open_root(root)
    # descend() owns rootfd from here: it closes it as it walks, and on
    # failure. With no intermediate components it hands the same descriptor
    # straight back, which is correct -- the root IS the parent.
    dirfd = descend(rootfd, components[:-1], create, mode)
    return dirfd, basename


# --- Target validation and bounded reads (port of config.py:88-128) -------


def open_target_file(dirfd: int, basename: str,
                     max_bytes: int) -> tuple[int | None, os.stat_result | None]:
    """Open and validate the target on its own descriptor.

    Port of config.py:88-115. The flag set is load-bearing in four ways:

      O_RDONLY    we never write through this fd; the publish goes to a temp.
      O_NONBLOCK  a FIFO at this path returns immediately instead of blocking
                  forever waiting for a writer. Without it, pointing the config
                  path at a FIFO wedges the caller -- a denial of service that
                  needs no privileges at all. The S_ISREG check below then
                  rejects it; dropping O_NONBLOCK makes that check unreachable
                  because we never arrive at it.
      O_CLOEXEC   nothing we spawn inherits a descriptor to the user's config.
      O_NOFOLLOW  a symlink here is refused, not followed.

    And it is opened relative to dirfd, so the parent that was validated is
    the parent this open resolves against.
    """
    try:
        fd = os.open(
            basename,
            os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=dirfd,
        )
    except FileNotFoundError:
        return None, None
    except OSError as error:
        # ELOOP lands here: O_NOFOLLOW met a symlink.
        fail_os("could not open target without following a symlink", error)

    try:
        file_stat = os.fstat(fd)
        if not stat.S_ISREG(file_stat.st_mode):
            fail("target is not a regular file")
        if file_stat.st_uid != os.geteuid():
            fail("target is not owned by the current user")
        if file_stat.st_mode & 0o022:
            fail("target is writable by another user")
        if file_stat.st_size > max_bytes:
            fail("target exceeds the %d-byte limit" % max_bytes)
    except BaseException:
        os.close(fd)
        raise
    return fd, file_stat


def read_bounded(fd: int, max_bytes: int) -> bytes:
    """Incremental bounded read (port of config.py:117-128).

    The st_size check in open_target_file is NOT the bound. st_size is a
    snapshot; a file can grow between the fstat and the read, and for some
    objects it lies outright. The bound is this loop: never ask for more than
    the remaining budget plus one byte, and fail the moment that extra byte
    arrives. A single os.read(fd, CAP) -- what bin/wallpaper-monitor's old
    load_target did
    today -- silently TRUNCATES instead, which for a JSON config means the
    caller parses a prefix of the file as if it were the file.
    """
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = os.read(fd, min(READ_CHUNK, max_bytes + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > max_bytes:
            fail("target exceeds the %d-byte limit" % max_bytes)
    return b"".join(chunks)


# --- Revalidation (port of config.py:219-235) -----------------------------


def same_target(dirfd: int, basename: str, original: os.stat_result | None) -> bool:
    """Is the target still the exact object we validated?

    Port of config.py:219-235 with the comparison tuple unchanged. This is the
    single largest gap between this repo and the approved reference: today
    bin/wallpaper-monitor's write_atomic and install.sh's finalize_shell_json
    rename over whatever is at
    the path at that instant, with no re-check at all.

    Every field earns its place:
      st_dev + st_ino   the object was replaced (unlink+create, or rename).
      st_uid            it changed hands.
      S_IFMT            a regular file became a FIFO, a directory, a device.
      S_IMODE           its permissions changed -- including becoming
                        world-writable, which our publish would then preserve.
      st_size           it was written to.
      st_mtime_ns       it was written to without changing size.
      st_ctime_ns       its metadata changed -- this catches a rename-over and
                        a chown that restored the old mode, and an
                        unprivileged writer cannot forge it.

    stat with dir_fd and follow_symlinks=False: a symlink appearing at the
    name must read as "different", not be followed and read as "same".
    """
    try:
        current = os.stat(basename, dir_fd=dirfd, follow_symlinks=False)
    except FileNotFoundError:
        # Absent now: that matches only if it was absent when we snapshotted.
        return original is None
    except OSError as error:
        fail_os("could not re-check the target", error)
    if original is None:
        # It did not exist when we snapshotted and it does now: somebody else
        # is writing here. Refuse rather than clobber their file.
        return False
    return (
        current.st_dev == original.st_dev
        and current.st_ino == original.st_ino
        and current.st_uid == original.st_uid
        and stat.S_IFMT(current.st_mode) == stat.S_IFMT(original.st_mode)
        and stat.S_IMODE(current.st_mode) == stat.S_IMODE(original.st_mode)
        and current.st_size == original.st_size
        and current.st_mtime_ns == original.st_mtime_ns
        and current.st_ctime_ns == original.st_ctime_ns
    )


def check_expected_identity(info: os.stat_result, spec: str | None) -> None:
    if spec is None:
        return
    want_dev, want_ino = parse_dev_ino(spec)
    if (info.st_dev, info.st_ino) != (want_dev, want_ino):
        fail("target is no longer the object that was inspected", EXIT_IDENTITY)


# --- Unpredictable temp + publish (port of config.py:238-309) -------------


def temp_name_for(basename: str) -> str:
    """An UNPREDICTABLE temp name (port of config.py:240).

    secrets.token_hex(16) = 128 bits from the OS CSPRNG. Not
    tempfile.mkstemp (8 characters, and no O_NOFOLLOW), not the PID, not a
    timestamp, and no fixed `.tmp` suffix. bin/wallpaper-monitor's old temp
    name used
    mkstemp(prefix=".background-per-monitor.", suffix=".tmp") today: the
    random middle does not help when the pattern around it is fixed, because
    an attacker never needs to guess the exact name -- they pre-create every
    name matching the pattern, or watch the directory and race the one that
    appears.
    """
    name = ".%s.%s" % (basename, secrets.token_hex(16))
    if len(name.encode("utf-8", "surrogateescape")) > MAX_COMPONENT_BYTES:
        # A long basename plus 32 hex characters can exceed NAME_MAX. Drop the
        # basename rather than the entropy.
        name = ".wpm.%s" % secrets.token_hex(16)
    return name


def create_temp(dirfd: int, basename: str) -> tuple[int, str]:
    """Create the temp file (port of config.py:238-257).

    O_EXCL: we never open something that already exists.
    O_NOFOLLOW: a symlink planted at the name we chose is refused rather than
    followed to wherever it points.
    0o600: unreadable by anyone else for the whole window before the fchmod.
    16 retries: covers the vanishingly unlikely genuine collision.
    """
    for _ in range(TEMP_ATTEMPTS):
        name = temp_name_for(basename)
        try:
            fd = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=dirfd,
            )
            return fd, name
        except FileExistsError:
            continue
        except OSError as error:
            fail_os("could not create a private temporary file", error,
                    EXIT_TRANSACTION)
    transaction_error("could not create an unpredictable temporary file")


def write_all(fd: int, data: bytes) -> None:
    """Write and fsync the CONTENT (port of config.py:260-264).

    fsync before the rename, not after: rename(2) is atomic for visibility but
    says nothing about durability. Without this a power cut right after the
    rename can leave the directory entry durable and the bytes behind it not
    -- which for shell.json means the shell reads a zero-length config at the
    next boot.
    """
    offset = 0
    while offset < len(data):
        offset += os.write(fd, data[offset:])
    os.fsync(fd)


def publish(dirfd: int, basename: str, data: bytes,
            old_stat: os.stat_result | None,
            new_mode: int, force_mode: int | None = None) -> None:
    """The transaction: temp -> write -> fsync -> fchmod -> REVALIDATE ->
    renameat -> fsync(dirfd), all through the one descriptor `dirfd`.

    Port of config.py:286-309, with the mode step diverging as documented in
    the module docstring.

    `old_stat` is the snapshot the caller took through THIS dirfd, before any
    producer ran.
    """
    temp_name: str | None = None
    try:
        temp_fd, temp_name = create_temp(dirfd, basename)
        try:
            write_all(temp_fd, data)

            # --- THE DELIBERATE DIVERGENCE FROM THE REFERENCE -------------
            # The reference publishes 0600 unconditionally. We preserve an
            # existing target's mode instead, because
            # ~/.config/omarchy/shell.json is read by the Omarchy shell and
            # forcing 0600 on it is a behaviour regression, not a hardening.
            #
            # The mode comes off old_stat, which is the fstat of the target's
            # OWN VALIDATED DESCRIPTOR -- not a pathname stat. install.sh's
            # `stat -c %a` mode probe
            # runs `stat -c %a -- "$dest"`, which on a symlink reports the
            # LINK's 0777 and then chmods the real file world-writable; that
            # whole class is unreachable from here, because old_stat can only
            # come from a descriptor that already passed S_ISREG, the owner
            # check and the `& 0o022` check.
            #
            # fchmod, not chmod: the temp is identified by descriptor, so
            # nothing can substitute a different file at its name between the
            # write and the mode change.
            if force_mode is not None:
                mode = force_mode           # install-file: the allowlist decides
            elif old_stat is not None:
                mode = stat.S_IMODE(old_stat.st_mode)   # preserve
            else:
                mode = new_mode             # brand-new file
            if mode & 0o022:
                # Unreachable via preservation (open_target_file already
                # refused such a target) and via parse_mode. Belt and braces:
                # the one line between a bug upstream and a world-writable
                # config the whole shell reads at startup.
                fail("refusing to publish a group- or other-writable mode")
            os.fchmod(temp_fd, mode)
        finally:
            os.close(temp_fd)

        # --- REVALIDATE IMMEDIATELY BEFORE PUBLISHING ------------------
        # Everything above -- running the filter, creating and filling the
        # temp -- took time, and the target sits in a directory the user's
        # other processes can write. If it is not byte-for-byte the object we
        # validated, we do not know what we would be replacing, so we replace
        # nothing.
        if not same_target(dirfd, basename, old_stat):
            transaction_error("target changed while it was being updated")

        # renameat(dirfd, temp, dirfd, name): both ends descriptor-relative.
        # A pathname os.replace would re-resolve the directory for a third
        # time, reopening the exact window the walk above closed.
        os.replace(temp_name, basename, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        temp_name = None

        # Durability of the rename itself, through the SAME descriptor held
        # all along -- so this necessarily fsyncs the directory the rename
        # landed in. install.sh's finalize_shell_json and
        # bin/wallpaper-monitor's write_atomic open the directory by name after
        # the fact and may fsync a different one.
        os.fsync(dirfd)
    finally:
        # Clean up dirfd-relatively. `rm /path/to/.name.hex` would re-resolve
        # the directory yet again, and an unlink by pathname is precisely the
        # operation an attacker would like to redirect.
        if temp_name is not None:
            try:
                os.unlink(temp_name, dir_fd=dirfd)
            except OSError:
                pass


# --- Tool validation (check-tool, and argv[0] for run/edit) ---------------


def validate_tool(path: str, require_exec: bool) -> None:
    """The authoritative tool check: pin an executable by identity, not name.

    Every parent is walked O_NOFOLLOW and must be root-owned without group or
    other write permission. The target must be a root-owned regular file with
    the same mode rule, plus an executable bit when required.

    SYMLINK RULE, stated plainly. The obvious rule -- "a tool may be a symlink
    only within its own directory" -- cannot be used: on Debian and Ubuntu
    /usr/bin/python3 is a symlink to /etc/alternatives/python3, which is NOT in
    the same directory, so that rule would reject the very interpreter this
    plugin pins. Instead a final-component symlink is followed for at most
    MAX_LINK_HOPS hops and EACH hop is re-anchored and re-validated through
    this same full walk. That is strictly stronger than "same directory" -- a
    same-directory symlink to a world-writable file would pass the simple rule
    and fails here -- and it does not break the default install.
    """
    if not path.startswith("/"):
        usage_error("tool path must be absolute")
    current = normalize_absolute(path)
    for _ in range(MAX_LINK_HOPS + 1):
        components = check_root(current)
        if not components:
            fail("tool path names the root directory")
        parent = open_directory_path(components[:-1], False, DIR_MODE_DEFAULT,
                                     "tool")
        if parent is None:
            fail("tool does not exist", EXIT_ABSENT)
        try:
            try:
                fd = os.open(components[-1],
                             os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW,
                             dir_fd=parent)
            except FileNotFoundError:
                fail("tool does not exist", EXIT_ABSENT)
            except OSError as error:
                if error.errno not in (errno.ELOOP, errno.EMLINK):
                    fail_os("could not open the tool", error)
                # A symlink. Re-anchor against its own directory and loop.
                target = os.readlink(components[-1], dir_fd=parent)
                if len(target.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES:
                    fail("tool symlink target is too long")
                if target.startswith("/"):
                    current = normalize_absolute(target)
                else:
                    current = normalize_absolute(
                        "/" + "/".join(components[:-1]) + "/" + target)
                continue
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode):
                    fail("tool is not a regular file")
                if info.st_uid != 0:
                    fail("tool must be owned by root")
                if info.st_mode & 0o022:
                    fail("tool is writable by another user")
                if require_exec and not info.st_mode & 0o111:
                    fail("tool is not executable")
            finally:
                os.close(fd)
            return
        finally:
            os.close(parent)
    fail("tool symlink chain is too long")


# --- Bounded, supervised child processes ----------------------------------


_LIBC = None


def libc() -> object | None:
    """Resolved BEFORE any fork. Loading a shared library inside a forked
    child can deadlock on the loader lock, so this is warmed up in the parent
    and the child only makes the call."""
    global _LIBC
    if _LIBC is None:
        try:
            _LIBC = ctypes.CDLL("libc.so.6", use_errno=True)
        except OSError:
            _LIBC = False
    return _LIBC or None


# F4 -- the environment a supervised child is GIVEN, never the one it
# inherits.
#
# supervise() used to end in os.execv(), which hands the child this process's
# entire os.environ. Invocations from Background.qml are genuinely closed --
# `/usr/bin/env -i` plus an explicit list -- but invocations from the shell get
# only the preamble's DENYLIST, and a denylist has named survivors. The ones
# that matter are glibc code- and data-loading vectors of exactly the same
# class as the LD_* names the preamble does clear:
#
#   GCONV_PATH   loads iconv conversion modules (.so) from a caller's directory
#   LOCPATH      loads locale objects from a caller's directory
#   MAGIC        points `file` at a caller's magic database -- and `file -b
#                --mime-type` IS this plugin's image gate, so this one decides
#                what counts as an image
#   NLSPATH      loads message catalogues from a caller's path
#   HOSTALIASES  redirects name lookups
#   TZDIR        loads timezone data from a caller's directory
#
# A denylist cannot be finished, because the next glibc release may add another
# name. So the environment is CONSTRUCTED instead: only the names below cross
# into the child, taken from os.environ if they are set there, and nothing else
# does -- whatever the caller's own environment happens to contain.
#
# The list is exactly what the two closed call sites already hand us, so this
# is a NO-OP for a caller that was already closed: Background.qml's picker
# prefix passes PATH, HOME and the session names below, and filtering that set
# through this allowlist returns the same set. The names are here because a GUI
# picker genuinely needs them -- a Wayland/Hyprland client cannot find the
# compositor without WAYLAND_DISPLAY, HYPRLAND_INSTANCE_SIGNATURE and
# XDG_RUNTIME_DIR, cannot reach the session bus without
# DBUS_SESSION_BUS_ADDRESS, and omarchy-* scripts read OMARCHY_PATH. hyprctl,
# the other supervised child, needs the same first three.
#
# Nothing in this list selects code: no LD_*, no BASH_*, no PYTHON*, and no
# name that names a module, catalogue or database directory. PATH is the one
# entry that names directories programs are found in, and it is forwarded
# rather than reconstructed because both call sites set it themselves to a
# fixed, root-owned value.
CHILD_ENV_ALLOWLIST = (
    "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL",
    "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE", "XDG_SESSION_DESKTOP",
    "XDG_CURRENT_DESKTOP", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS",
    "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_STATE_HOME", "XDG_CACHE_HOME",
    "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE",
    "DBUS_SESSION_BUS_ADDRESS", "OMARCHY_PATH",
    "XCURSOR_THEME", "XCURSOR_SIZE",
)

# Used only when PATH is not set at all. Both shipped call sites set it, so
# this is never reached in the plugin; it exists so that a child can never be
# exec'd with NO PATH and fall back to whatever the C library's default is.
CHILD_PATH_FALLBACK = "/usr/bin:/bin"


def child_environment() -> dict[str, str]:
    """Build the child's environment from the allowlist. Never inherited."""
    env = {}
    for name in CHILD_ENV_ALLOWLIST:
        value = os.environ.get(name)
        if value is None:
            continue
        env[name] = value
    env["PATH"] = "/usr/bin:/usr/share/omarchy/bin"
    env["OMARCHY_PATH"] = "/usr/share/omarchy"
    return env


def signal_group(pgid: int | None, pid: int, signum: int) -> None:
    """Signal the whole group when we made one, otherwise just the child.

    Signalling the GROUP is the point: the moderator rejected a deadline that
    "does not establish termination/reaping of the whole spawned pipeline".
    Killing only the direct child leaves its own children running, holding the
    pipe open, and outliving us.
    """
    try:
        if pgid is not None:
            os.killpg(pgid, signum)
        else:
            os.kill(pid, signum)
    except (ProcessLookupError, PermissionError):
        pass


def wait_for(pid: int, timeout_s: float) -> int | None:
    """Reap `pid` within the timeout. None = already gone, -1 = still alive."""
    end = time.monotonic() + timeout_s
    while True:
        try:
            waited, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return None
        if waited == pid:
            return status
        if time.monotonic() >= end:
            return -1
        time.sleep(0.01)


def reap_remaining() -> None:
    """waitpid until ECHILD, so no zombie survives this process."""
    for _ in range(256):
        try:
            waited, _status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if waited == 0:
            return


def adopted_children() -> list[int]:
    # Linux subreapers adopt descendants even when they leave our process group.
    with open("/proc/self/task/%d/children" % os.getpid(), "rb", buffering=0) as stream:
        data = stream.read(65537)
    if len(data) > 65536:
        fail("too many child processes to supervise")
    return [int(value) for value in data.split()]


def teardown(pid: int, pgid: int | None, grace_ms: int) -> None:
    """Terminate the group AND adopted descendants; verify reaping, boundedly."""
    signal_group(pgid, pid, signal.SIGTERM)
    # Signal the direct child too: it may not yet have completed setsid().
    signal_group(None, pid, signal.SIGTERM)
    deadline = time.monotonic() + grace_ms / 1000.0
    kill_deadline = deadline + 2.0
    while True:
        reap_remaining()
        children = adopted_children()
        group_present = False
        if pgid is not None:
            try:
                os.killpg(pgid, 0)
                group_present = True
            except ProcessLookupError:
                pass
        if not children and not group_present:
            return
        now = time.monotonic()
        sig = signal.SIGKILL if now >= deadline else signal.SIGTERM
        if group_present:
            signal_group(pgid, pid, sig)
        for child in children:
            signal_group(None, child, sig)
        if now >= kill_deadline:
            fail("could not verify whole-process cleanup", EXIT_TRANSACTION)
        time.sleep(0.01)


def teardown_group_after_exit(pgid: int, grace_ms: int) -> None:
    teardown(pgid, pgid, grace_ms)


class Supervision:
    """Caps on the child's STDOUT, applied on the PRODUCER side, before
    anything is forwarded.

    Consumer-side bounding (`| head -c N`) was explicitly rejected: by the time
    the consumer truncates, the producer has already produced, and a producer
    that never stops is never stopped. Here the caps are checked as bytes
    arrive, and a breach tears the group down.

    WHAT IS **NOT** IN THIS BUDGET, stated so the claim above is not read as
    wider than it is: the child's STDERR. `run --stderr-to-null` sends it to
    /dev/null, but `edit` -- whose filter is jq or awk -- leaves it pointing at
    this process's own inherited fd 2, where it is neither counted nor
    buffered. That is deliberate, and it is a noise bound rather than a
    resource bound:
      * it is never buffered in memory by us, so no amount of it can grow this
        process; it goes straight to whatever the caller's fd 2 is;
      * charging it against a budget whose breach KILLS the child would mean a
        jq syntax error could abort the transaction by being wordy, and would
        throw away the only diagnostic the caller gets when a filter fails;
      * it is still bounded in TIME by the same deadline as stdout: the child
        is torn down at the deadline whatever it is writing.
    So stderr is unbounded in volume, and in exchange the filter's error
    message survives to reach the user. Nothing else escapes the budget.
    """

    def __init__(self, max_output_bytes: int, max_lines: int,
                 max_line_bytes: int) -> None:
        self.max_output_bytes = max_output_bytes
        self.max_lines = max_lines
        self.max_line_bytes = max_line_bytes
        self.chunks: list[bytes] = []
        self.total = 0
        self.lines = 0
        self.line_length = 0

    def feed(self, chunk: bytes) -> str | None:
        self.total += len(chunk)
        if self.total > self.max_output_bytes:
            return "producer exceeded the %d-byte output budget" % self.max_output_bytes
        for byte in chunk:
            if byte == 0x0A:
                self.lines += 1
                self.line_length = 0
                if self.lines > self.max_lines:
                    return "producer exceeded the %d-line budget" % self.max_lines
            else:
                self.line_length += 1
                if self.line_length > self.max_line_bytes:
                    return ("producer emitted a line longer than %d bytes"
                            % self.max_line_bytes)
        self.chunks.append(chunk)
        return None

    def data(self) -> bytes:
        return b"".join(self.chunks)


def supervise(argv: list[str], stdin_data: bytes, *, deadline_ms: int,
              grace_ms: int, max_output_bytes: int, max_lines: int,
              max_line_bytes: int, use_setsid: bool,
              stderr_to_null: bool) -> bytes:
    """Run a child in a constructed environment, with its own session, a hard
    deadline and producer-side stdout caps, and tear its whole group down on
    EVERY exit path -- including the one where the child succeeded.

    Every exit path, spelled out, because "on failure" was the bug:
      * cap breach and deadline: tear down, then exit 6 / 7;
      * signalled: SIGINT/SIGTERM reach this process as the SystemExit that
        terminate() raises, and the `except BaseException` arm below catches
        it, tears the group down and reaps it before letting the exit
        propagate as 128+signum;
      * child exited non-zero: same arm, then exit 3;
      * child exited ZERO: teardown_group_after_exit() runs after the status
        is collected. Without it a child could exit 0 having detached a
        grandchild with stdout redirected away -- EOF arrives, we return 0, and
        the grandchild outlives us. See that function.

    PR_SET_PDEATHSIG covers only the case this process CANNOT handle --
    SIGKILL, a crash, the QML side giving up -- and it covers only the DIRECT
    child, so it is a backstop and not the guarantee: the kernel signals that
    one child, while the child's own children are reached solely by the group
    teardown here.

    The environment is built, not inherited: see CHILD_ENV_ALLOWLIST and the
    execve() below.
    """
    if not argv:
        usage_error("no child argv after '--'")
    # System executable names and every parent are root-owned and not writable
    # by the session user. Configuration transactions use held fds separately.
    validate_tool(argv[0], require_exec=True)
    # F4 -- built in the PARENT, from an allowlist, and handed to execve below.
    # Nothing about the caller's own environment reaches the child implicitly.
    child_env = child_environment()
    handle = libc()
    if handle is None or handle.prctl(36, 1, 0, 0, 0) != 0:
        fail("Linux child subreaper support is required")
    supervisor_pid = os.getpid()

    out_r, out_w = os.pipe()
    err_r, err_w = os.pipe()
    in_r, in_w = os.pipe()
    null_fd = os.open(os.devnull, os.O_WRONLY | os.O_CLOEXEC) if stderr_to_null else -1

    pid = os.fork()
    if pid == 0:                                        # --- child ---
        try:
            if use_setsid:
                os.setsid()
            handle = libc()
            if handle is not None:
                if handle.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0) != 0:
                    os._exit(127)
                if os.getppid() != supervisor_pid:
                    os._exit(127)
            os.dup2(in_r, 0)
            os.dup2(out_w, 1)
            os.dup2(null_fd if null_fd >= 0 else err_w, 2)
            for fd in (in_r, in_w, out_r, out_w, err_r, err_w):
                try:
                    os.close(fd)
                except OSError:
                    pass
            if null_fd >= 0:
                try:
                    os.close(null_fd)
                except OSError:
                    pass
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            # execve, not execv: the third argument is the constructed
            # environment. execv would pass os.environ, and the child's
            # environment would then be whatever survived the caller's
            # denylist. See CHILD_ENV_ALLOWLIST.
            os.execve(argv[0], argv, child_env)
        except BaseException:
            os._exit(127)
        os._exit(127)

    # --- parent ---
    os.close(in_r)
    os.close(out_w)
    os.close(err_w)
    if null_fd >= 0:
        os.close(null_fd)
    # setsid() makes the child a group leader, so its pid IS its pgid. Without
    # --setsid we only have the child itself to signal.
    pgid = pid if use_setsid else None

    caps = Supervision(max_output_bytes, max_lines, max_line_bytes)
    err_caps = Supervision(16384, 256, 4096)
    deadline = time.monotonic() + deadline_ms / 1000.0
    pending = stdin_data
    breach: str | None = None
    expired = False
    torn_down = False

    def tear_down_once() -> None:
        """teardown(), at most once, whichever exit path arrives here first.

        Once the group leader has been reaped its pgid can in principle be
        recycled, so a second round of TERM/KILL could reach a group that is
        no longer ours. The second caller is therefore a no-op.
        """
        nonlocal torn_down
        if torn_down:
            return
        torn_down = True
        teardown(pid, pgid, grace_ms)

    os.set_blocking(err_r, False)
    os.set_blocking(out_r, False)
    os.set_blocking(in_w, False)
    poller = select.poll()
    poller.register(out_r, select.POLLIN)
    poller.register(err_r, select.POLLIN)
    if pending:
        poller.register(in_w, select.POLLOUT)
    else:
        os.close(in_w)
        in_w = -1

    # From here to the `return`, EVERY abnormal exit tears the group down: the
    # cap, deadline and unreaped-child paths call tear_down_once() explicitly,
    # and `except BaseException` catches everything else -- above all the
    # SystemExit that terminate() raises on SIGINT/SIGTERM. Without this arm a
    # signal unwound straight out of the poll loop and the group we created
    # outlived us: the direct child died via PR_SET_PDEATHSIG, but a
    # grandchild of it kept running, orphaned. The exception is re-raised
    # unchanged, so a signal still exits 128+signum and the cap and deadline
    # paths still exit with their own codes.
    try:
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    expired = True
                    break
                for fd, event in poller.poll(int(min(remaining, 0.25) * 1000.0)):
                    if fd in (out_r, err_r) and event & (select.POLLIN | select.POLLHUP):
                        chunk = os.read(fd, READ_CHUNK)
                        if not chunk:
                            poller.unregister(fd)
                            os.close(fd)
                            if fd == out_r:
                                out_r = -1
                            else:
                                err_r = -1
                            continue
                        breach = (caps if fd == out_r else err_caps).feed(chunk)
                        if breach:
                            break
                    elif fd == in_w and event & select.POLLOUT:
                        try:
                            written = os.write(in_w, pending)
                        except BrokenPipeError:
                            written = len(pending)
                        pending = pending[written:]
                        if not pending:
                            poller.unregister(in_w)
                            os.close(in_w)
                            in_w = -1
                    elif fd == in_w and event & (select.POLLERR | select.POLLHUP):
                        # The child closed stdin without reading it all. Normal for
                        # a filter that stops early; not our problem to report.
                        poller.unregister(in_w)
                        os.close(in_w)
                        in_w = -1
                if breach or (out_r == -1 and err_r == -1):
                    break
        finally:
            for fd in (out_r, err_r, in_w):
                if fd >= 0:
                    try:
                        os.close(fd)
                    except OSError:
                        pass

        if breach:
            tear_down_once()
            fail(breach, EXIT_OUTPUT_CAP)
        if expired:
            tear_down_once()
            fail("child exceeded the %d ms deadline" % deadline_ms, EXIT_DEADLINE)

        # Closing stdout does not grant extra runtime beyond the deadline.
        status = wait_for(pid, max(0.0, deadline - time.monotonic()))
        if status == -1:
            tear_down_once()
            fail("child exceeded the %d ms deadline" % deadline_ms, EXIT_DEADLINE)
        reap_remaining()

        # F6 -- the group comes down here too, on the path where NOTHING went
        # wrong. The child's own exit status has just been collected above, so
        # this can no longer change what we report; what it does is make sure
        # the child cannot leave a grandchild behind by exiting 0 after
        # detaching one with stdout redirected away. Only reachable with a
        # group of our own: without --setsid the "group" is this process's own,
        # and signalling it would signal us and our caller.
        if pgid is not None:
            torn_down = True
            teardown_group_after_exit(pgid, grace_ms)

        if err_caps.data():
            write_fd(2, err_caps.data())
        if status is not None:
            if os.WIFSIGNALED(status):
                transaction_error("child was killed by signal %d" % os.WTERMSIG(status))
            if os.WIFEXITED(status) and os.WEXITSTATUS(status) != 0:
                transaction_error("child exited %d" % os.WEXITSTATUS(status))
        return caps.data()
    except BaseException:
        tear_down_once()
        raise


# --- Subcommands ---------------------------------------------------------


def check_entry_cap(data: bytes) -> None:
    """Bound the ENTRY COUNT of a JSON payload before it is published.

    The reference has this (config.py:16 / :161-162) and this repo has it
    nowhere: the `data["monitors"][monitor] = image` assignment in
    bin/wallpaper-monitor's set path grows without limit, and Background.qml's
    JSON.parse of the same file accepts an object of any size. A config that is under the byte cap can still be an object with
    tens of thousands of keys, which is a memory and parse-time problem in the
    long-lived shell process rather than in this short-lived one.

    Applied opportunistically: a payload that does not parse as JSON is the
    JSONC menu file (comments are not JSON), which is bounded by the byte cap
    and has no entry semantics to cap. Nothing else in the repo publishes a
    format this could mistake.
    """
    try:
        parsed = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return
    if not isinstance(parsed, dict):
        return
    if len(parsed) > MAX_ENTRIES:
        fail("payload has more than %d top-level entries" % MAX_ENTRIES)
    for value in parsed.values():
        if isinstance(value, dict) and len(value) > MAX_ENTRIES:
            fail("payload has a nested object with more than %d entries"
                 % MAX_ENTRIES)


def command_read(opts: Options) -> None:
    max_bytes = bounded_budget(opts.value("max-bytes"))
    dirfd, basename = opts.open_parent()
    try:
        fd, info = open_target_file(dirfd, basename, max_bytes)
        if fd is None:
            if opts.flag("allow-missing"):
                return
            fail("target does not exist", EXIT_ABSENT)
        try:
            check_expected_identity(info, opts.value("expect-dev-ino"))
            emit_bytes(read_bounded(fd, max_bytes))
        finally:
            os.close(fd)
    finally:
        os.close(dirfd)


KIND_NAMES = (
    (stat.S_ISREG, "reg"),
    (stat.S_ISDIR, "dir"),
    (stat.S_ISLNK, "lnk"),
    (stat.S_ISFIFO, "fifo"),
    (stat.S_ISCHR, "chr"),
    (stat.S_ISBLK, "blk"),
    (stat.S_ISSOCK, "sock"),
)


def command_stat(opts: Options) -> None:
    """No-follow identity query (fstatat with AT_SYMLINK_NOFOLLOW).

    Replaces `[[ -L ]]`, `[[ -f ]]` and `stat -c %a`, all of which answer
    about the resolved pathname. Newline-safe by construction: the path is
    never echoed back -- it came from the caller's own argv.
    """
    dirfd, basename = opts.open_parent()
    try:
        try:
            info = os.stat(basename, dir_fd=dirfd, follow_symlinks=False)
        except FileNotFoundError:
            if opts.flag("allow-missing"):
                emit_line("type=absent")
                return
            fail("target does not exist", EXIT_ABSENT)
        except OSError as error:
            fail_os("could not stat the target", error)

        check_expected_identity(info, opts.value("expect-dev-ino"))

        kind = "unknown"
        for predicate, name in KIND_NAMES:
            if predicate(info.st_mode):
                kind = name
                break
        emit_line("type=%s" % kind)
        emit_line("mode=%04o" % stat.S_IMODE(info.st_mode))
        emit_line("uid=%d" % info.st_uid)
        emit_line("gid=%d" % info.st_gid)
        emit_line("size=%d" % info.st_size)
        emit_line("dev=%d" % info.st_dev)
        emit_line("ino=%d" % info.st_ino)
        emit_line("nlink=%d" % info.st_nlink)
        emit_line("mtime_ns=%d" % info.st_mtime_ns)
    finally:
        os.close(dirfd)


def command_edit(opts: Options) -> None:
    """Read -> pure stdin->stdout filter -> publish, in ONE process holding
    ONE dirfd.

    This is the decision that removes the largest real hole in install.sh and
    uninstall.sh. Today shell.json is touched three times by pathname --
    `[[ -f ]]` / `stat -c %a`, then `jq ... "$SHELL_JSON" > "$TMP_JSON"`, then
    `mv` -- three resolutions and three races, with `mktemp -p` names
    predictable enough to matter.

    The filter is the EXISTING jq or awk program, reused byte-identical: it
    never touches the filesystem, it only transforms stdin to stdout, so the
    whole transaction stays inside this process and inside this descriptor.

    Ordering matters and is deliberate: the target is snapshotted BEFORE the
    filter runs, so the revalidation below covers the filter's entire
    execution. That is where the window actually is -- jq reading and
    re-emitting a 40 KiB shell.json is not instantaneous.
    """
    max_bytes = bounded_budget(opts.value("max-bytes"))
    max_output = bounded_budget(opts.value("max-output-bytes"))
    new_mode = parse_mode(opts.value("mode")) if opts.value("mode") else FILE_MODE_DEFAULT
    deadline_ms = (parse_positive(opts.value("deadline-ms"), "--deadline-ms")
                   if opts.value("deadline-ms") else DEFAULT_DEADLINE_MS)
    if not opts.child:
        usage_error("edit needs a filter argv after '--'")

    dirfd, basename = opts.open_parent()
    old_fd: int | None = None
    try:
        old_fd, old_stat = open_target_file(dirfd, basename, max_bytes)
        if old_fd is None:
            # A missing target is created, not refused: every edit call site in
            # the plugin runs against a file that may legitimately not exist
            # yet (a fresh shell.json, a first override).
            content = b""
        else:
            check_expected_identity(old_stat, opts.value("expect-dev-ino"))
            content = read_bounded(old_fd, max_bytes)

        # A non-zero filter exit, a cap breach or a deadline hit raises here,
        # BEFORE anything is written.
        output = supervise(
            opts.child, content,
            deadline_ms=deadline_ms,
            grace_ms=DEFAULT_KILL_GRACE_MS,
            max_output_bytes=max_output,
            max_lines=DEFAULT_MAX_LINES,
            max_line_bytes=DEFAULT_MAX_LINE_BYTES,
            use_setsid=True,
            stderr_to_null=False,
        )
        if not output.strip():
            # An empty filter result would silently erase the file. Every
            # filter in this repo (jq object output, awk block insert/remove)
            # emits at least `{}`.
            fail("filter produced no output; refusing to erase the target")
        check_entry_cap(output)

        publish(dirfd, basename, output, old_stat, new_mode)
    finally:
        # Held open for the whole transaction: it pins the inode we validated,
        # so nothing can recycle that inode number underneath same_target().
        if old_fd is not None:
            os.close(old_fd)
        os.close(dirfd)


def command_mkdir_chain(opts: Options) -> None:
    mode = parse_mode(opts.value("mode")) if opts.value("mode") else DIR_MODE_DEFAULT
    components = split_rel(opts.require("rel"))
    rootfd = open_root(opts.require("root"))
    # descend() owns rootfd (see its docstring) -- never close it here too.
    dirfd = descend(rootfd, components, create=True, mode=mode)
    # fsync the leaf: a directory a caller is about to publish into must exist
    # durably before the publish, not merely in the page cache.
    try:
        os.fsync(dirfd)
    finally:
        os.close(dirfd)


def command_install_file(opts: Options) -> None:
    """Copy one payload file, both ends fully validated.

    Replaces the per-file half of install.sh's `rsync -a --delete` and the
    `chmod +x` that followed it. rsync re-resolves every path by name inside a
    process we do not control, so no descriptor can be held across validation
    and copy; the scar install.sh still carries a guard for -- a symlinked
    plugin dir whose target's contents `--delete` erased -- is that property
    showing up as a bug report.

    --mode is AUTHORITATIVE here, unlike edit's preserve rule: a payload
    file's mode is declared by the installer's allowlist, which is what makes
    the executable bit travel with the entry instead of being a separate chmod
    that can drift out of sync with it.
    """
    max_bytes = bounded_budget(opts.value("max-bytes"))
    mode = parse_mode(opts.require("mode"))

    src_dirfd, src_name = opts.open_parent(root_key="src-root", rel_key="src-rel")
    try:
        src_fd, _src_stat = open_target_file(src_dirfd, src_name, max_bytes)
        if src_fd is None:
            fail("source file does not exist", EXIT_ABSENT)
        try:
            data = read_bounded(src_fd, max_bytes)
        finally:
            os.close(src_fd)
    finally:
        os.close(src_dirfd)

    # create=True: the destination tree (the plugin dir and its bin/) is ours
    # to make, at 0o700. Anything already there is opened O_NOFOLLOW, so a
    # symlink planted at an intermediate component fails instead of
    # redirecting the payload -- which is the bug install.sh guards by hand,
    # and only for the final component.
    dst_dirfd, dst_name = opts.open_parent(root_key="dst-root", rel_key="dst-rel",
                                           create=True)
    old_fd: int | None = None
    try:
        old_fd, old_stat = open_target_file(dst_dirfd, dst_name, max_bytes)
        publish(dst_dirfd, dst_name, data, old_stat, mode, force_mode=mode)
    finally:
        if old_fd is not None:
            os.close(old_fd)
        os.close(dst_dirfd)


def build_keep_tree(keeps: list[str]) -> dict:
    """--keep a/b --keep c  ->  {"a": {"b": KEEP}, "c": KEEP}."""
    tree: dict = {}
    for keep in keeps:
        node = tree
        components = split_rel(keep)
        for component in components[:-1]:
            existing = node.get(component)
            if existing is True:
                # A broader keep already covers this one.
                node = {}
                break
            node = node.setdefault(component, {})
        else:
            node[components[-1]] = True
    return tree


def remove_tree(dirfd: int, name: str, depth: int, max_entries: int) -> int:
    """Recursively remove `name` below dirfd, descriptor-relatively.

    Never descends into a symlink: a symlink is unlinked as an entry, and a
    directory is opened O_NOFOLLOW so a component swapped underneath us fails
    with ELOOP instead of pointing the delete at somebody else's tree. That is
    the difference from uninstall.sh's `rm -rf "$PLUGIN_DIR"`, whose only
    guard is a `[[ -d ]]` that follows symlinks.
    """
    if depth > MAX_PRUNE_DEPTH:
        fail("directory tree is deeper than %d levels" % MAX_PRUNE_DEPTH)
    info = os.stat(name, dir_fd=dirfd, follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode):
        os.unlink(name, dir_fd=dirfd)
        return 1
    try:
        subfd = os.open(name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                        dir_fd=dirfd)
    except OSError as error:
        fail_os("could not open a subdirectory safely", error)
    removed = 0
    try:
        validate_dirfd(subfd)
        entries = os.listdir(subfd)
        if len(entries) > max_entries:
            fail("directory holds more than %d entries" % max_entries)
        for entry in entries:
            removed += remove_tree(subfd, entry, depth + 1, max_entries)
    finally:
        os.close(subfd)
    os.rmdir(name, dir_fd=dirfd)
    return removed + 1


def prune(dirfd: int, keep: dict, depth: int, max_entries: int) -> int:
    removed = 0
    entries = os.listdir(dirfd)
    if len(entries) > max_entries:
        fail("directory holds more than %d entries" % max_entries)
    for entry in entries:
        rule = keep.get(entry)
        if rule is True:
            continue
        info = os.stat(entry, dir_fd=dirfd, follow_symlinks=False)
        if rule is not None and stat.S_ISDIR(info.st_mode):
            if depth >= MAX_PRUNE_DEPTH:
                fail("directory tree is deeper than %d levels" % MAX_PRUNE_DEPTH)
            try:
                subfd = os.open(entry,
                                os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                                | os.O_NOFOLLOW,
                                dir_fd=dirfd)
            except OSError as error:
                fail_os("could not open a subdirectory safely", error)
            try:
                validate_dirfd(subfd)
                removed += prune(subfd, rule, depth + 1, max_entries)
            finally:
                os.close(subfd)
            continue
        removed += remove_tree(dirfd, entry, depth + 1, max_entries)
    return removed


def command_prune_dir(opts: Options) -> None:
    """`rsync --delete` semantics, and `rm -rf`, without either tool.

    The keep list is the installer's own payload allowlist, so the install and
    the prune cannot disagree about what belongs there -- which is the failure
    mode `--include` ordering rules invite.
    """
    # MAX_PRUNE_ENTRIES is the only entry bound, not a default a caller can
    # move: every prune in the plugin walks the plugin's own directory, and a
    # caller-supplied ceiling was an option nothing ever passed.
    max_entries = MAX_PRUNE_ENTRIES
    keep = build_keep_tree(opts.repeated("keep"))
    remove_all = opts.flag("remove-all")
    if remove_all and keep:
        usage_error("--remove-all and --keep are mutually exclusive")

    components = split_rel(opts.require("rel"))
    rootfd = open_root(opts.require("root"))
    parentfd = descend(rootfd, components[:-1], False, DIR_MODE_DEFAULT)
    basename = components[-1]
    try:
        try:
            info = os.stat(basename, dir_fd=parentfd, follow_symlinks=False)
        except FileNotFoundError:
            if opts.flag("if-exists"):
                emit_line("0")
                return
            fail("target does not exist", EXIT_ABSENT)
        if stat.S_ISLNK(info.st_mode):
            fail("target directory is a symlink")
        if not stat.S_ISDIR(info.st_mode):
            fail("target is not a directory")

        if remove_all:
            removed = remove_tree(parentfd, basename, 1, max_entries)
            os.fsync(parentfd)
            emit_line("%d" % removed)
            return

        try:
            dirfd = os.open(basename,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                            | os.O_NOFOLLOW,
                            dir_fd=parentfd)
        except OSError as error:
            fail_os("could not open the directory safely", error)
        try:
            validate_dirfd(dirfd)
            removed = prune(dirfd, keep, 1, max_entries)
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
        emit_line("%d" % removed)
    finally:
        os.close(parentfd)



def command_unlink(opts: Options) -> None:
    dirfd, basename = opts.open_parent()
    try:
        try:
            info = os.stat(basename, dir_fd=dirfd, follow_symlinks=False)
        except FileNotFoundError:
            if opts.flag("if-exists"):
                emit_line("absent")
                return
            fail("target does not exist", EXIT_ABSENT)
        except OSError as error:
            fail_os("could not inspect the target", error)

        if stat.S_ISDIR(info.st_mode):
            fail("target is a directory; use prune-dir")

        # Closes the check-then-act in uninstall.sh's unlink_one: the caller
        # passes back the identity `stat` reported, and we refuse if the
        # object was swapped in between.
        check_expected_identity(info, opts.value("expect-dev-ino"))

        try:
            os.unlink(basename, dir_fd=dirfd)
        except FileNotFoundError:
            if opts.flag("if-exists"):
                emit_line("absent")
                return
            fail("target does not exist", EXIT_ABSENT)
        except OSError as error:
            fail_os("could not remove the target", error)
        os.fsync(dirfd)
    finally:
        os.close(dirfd)


def command_symlink(opts: Options) -> None:
    target = opts.require("target")
    if not target or "\0" in target:
        usage_error("--target is empty or contains a NUL byte")
    if len(target.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES:
        usage_error("--target is longer than %d bytes" % MAX_PATH_BYTES)
    if not target.isprintable():
        usage_error("--target contains control characters")

    dirfd, basename = opts.open_parent()
    try:
        if not opts.flag("replace"):
            try:
                os.symlink(target, basename, dir_fd=dirfd)
            except FileExistsError:
                fail("something already exists at the link path")
            except OSError as error:
                fail_os("could not create the link", error)
            os.fsync(dirfd)
            return

        # --replace: create at an unpredictable name, then renameat over it.
        # `rm` + `ln -s` leaves a window in which the path does not exist and
        # whoever creates something there first wins.
        try:
            old_stat = os.stat(basename, dir_fd=dirfd, follow_symlinks=False)
        except FileNotFoundError:
            old_stat = None
        except OSError as error:
            fail_os("could not inspect the link path", error)
        if old_stat is not None:
            check_expected_identity(old_stat, opts.value("expect-dev-ino"))

        temp_name: str | None = None
        try:
            for _ in range(TEMP_ATTEMPTS):
                candidate = temp_name_for(basename)
                try:
                    os.symlink(target, candidate, dir_fd=dirfd)
                    temp_name = candidate
                    break
                except FileExistsError:
                    continue
                except OSError as error:
                    fail_os("could not stage the link", error, EXIT_TRANSACTION)
            if temp_name is None:
                transaction_error("could not create an unpredictable temporary link")
            if not same_target(dirfd, basename, old_stat):
                transaction_error("link path changed while it was being replaced")
            os.replace(temp_name, basename, src_dir_fd=dirfd, dst_dir_fd=dirfd)
            temp_name = None
            os.fsync(dirfd)
        finally:
            if temp_name is not None:
                try:
                    os.unlink(temp_name, dir_fd=dirfd)
                except OSError:
                    pass
    finally:
        os.close(dirfd)


def command_resolve_link(opts: Options) -> None:
    """`readlink -f`, bounded and without following a directory symlink.

    Hops are resolved only while the result stays inside --root: a target that
    leaves the trusted subtree is reported as-is rather than chased through
    directories we have no business validating. The callers -- the symlink
    audits in install.sh and uninstall.sh -- compare the answer to a path they
    already know, so a string is exactly what they need.
    """
    hops = (parse_positive(opts.value("max-hops"), "--max-hops")
            if opts.value("max-hops") else DEFAULT_LINK_HOPS)
    if hops > MAX_LINK_HOPS:
        usage_error("--max-hops is greater than %d" % MAX_LINK_HOPS)

    root = normalize_absolute(opts.require("root"))
    rel = opts.require("rel")
    resolved = normalize_absolute(root + "/" + rel)
    dangling = False
    first = True
    for _ in range(hops + 1):
        inside = resolved == root or resolved.startswith(root.rstrip("/") + "/")
        if not inside and not opts.flag("require-regular"):
            # Link audits compare the destination string, without opening it.
            break
        relative = resolved[len(root):].lstrip("/")
        if inside and not relative:
            if opts.flag("require-regular"):
                fail("target is a directory")
            break
        try:
            if inside and root != "/":
                dirfd, basename = open_parent(root, relative)
            else:
                components = check_root(resolved)
                dirfd = open_directory_path(components[:-1], False,
                                            DIR_MODE_DEFAULT, "system")
                if dirfd is None:
                    fail("target parent does not exist", EXIT_ABSENT)
                basename = components[-1]
        except ConfigError as error:
            # A missing directory BELOW the first hop means the link dangles.
            # `readlink -f` reports the path anyway, and install.sh's symlink
            # audit depends on being told about a dangling link rather than an
            # error -- it has a whole branch for that case.
            if first or error.code != EXIT_ABSENT:
                raise
            dangling = True
            break
        try:
            try:
                info = os.stat(basename, dir_fd=dirfd, follow_symlinks=False)
            except FileNotFoundError:
                if first:
                    fail("target does not exist", EXIT_ABSENT)
                dangling = True
                break
            except OSError as error:
                fail_os("could not inspect the target", error)
            if not stat.S_ISLNK(info.st_mode):
                if opts.flag("require-regular") and not stat.S_ISREG(info.st_mode):
                    fail("target is not a regular file")
                break
            target = os.readlink(basename, dir_fd=dirfd)
        finally:
            os.close(dirfd)
        first = False
        if len(target.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES:
            fail("symlink target is longer than %d bytes" % MAX_PATH_BYTES)
        if target.startswith("/"):
            resolved = normalize_absolute(target)
        else:
            parent = resolved.rsplit("/", 1)[0] or "/"
            resolved = normalize_absolute(parent + "/" + target)
    else:
        fail("symlink chain is longer than %d hops" % hops)

    if dangling and opts.flag("require-regular"):
        fail("resolved target does not exist", EXIT_ABSENT)

    if len(resolved.encode("utf-8", "surrogateescape")) > MAX_PATH_BYTES:
        fail("resolved path is longer than %d bytes" % MAX_PATH_BYTES)
    if not resolved.isprintable():
        fail("resolved path contains control characters")
    emit_line(resolved)


def command_lock_run(opts: Options) -> None:
    rootfd = open_root(opts.require("root"))
    dirfd = descend(rootfd, split_rel(opts.require("rel")), True, DIR_MODE_DEFAULT)
    try:
        end = time.monotonic() + 5.0
        while True:
            try:
                fcntl.flock(dirfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= end:
                    fail("another wallpaper-monitor is writing", EXIT_TRANSACTION)
                time.sleep(0.05)
        if not opts.child or opts.child[0] != "/usr/bin/bash":
            usage_error("lock-run requires the Bash CLI")
        validate_tool(opts.child[0], True)
        # exec preserves this fd and the lock until the complete CLI exits.
        os.set_inheritable(dirfd, True)
        os.execve(opts.child[0], opts.child, child_environment())
    finally:
        os.close(dirfd)


def command_run(opts: Options) -> None:
    """Bounded, supervised child.

    Replaces every unbounded `$( ... )` in the repo. QML's direct child is
    this helper, so the QML side never needs a process-group API: the helper
    owns the group and reaps it.
    """
    if not opts.child:
        usage_error("run needs a child argv after '--'")
    output = supervise(
        opts.child, b"",
        deadline_ms=(parse_positive(opts.value("deadline-ms"), "--deadline-ms")
                     if opts.value("deadline-ms") else DEFAULT_DEADLINE_MS),
        grace_ms=(parse_positive(opts.value("kill-grace-ms"), "--kill-grace-ms")
                  if opts.value("kill-grace-ms") else DEFAULT_KILL_GRACE_MS),
        max_output_bytes=bounded_budget(opts.value("max-output-bytes"),
                                        MAX_FILE_BYTES)
        if opts.value("max-output-bytes") else DEFAULT_MAX_OUTPUT_BYTES,
        max_lines=(parse_positive(opts.value("max-lines"), "--max-lines")
                   if opts.value("max-lines") else DEFAULT_MAX_LINES),
        max_line_bytes=(parse_positive(opts.value("max-line-bytes"),
                                       "--max-line-bytes")
                        if opts.value("max-line-bytes") else DEFAULT_MAX_LINE_BYTES),
        use_setsid=opts.flag("setsid"),
        stderr_to_null=opts.flag("stderr-to-null"),
    )
    emit_bytes(output)


def command_check_tool(opts: Options) -> None:
    paths = opts.repeated("path")
    if not paths:
        usage_error("--path is required")
    for path in paths:
        validate_tool(path, require_exec=True)
        # Bounded, and the path is echoed only after it passed every check --
        # at which point it is a path to a root-or-ours, non-writable regular
        # file, so it cannot carry a surprise.
        emit_line("ok %s" % path)


# --- argv parsing and dispatch -------------------------------------------

# Common options every filesystem subcommand accepts. Both have call sites:
# --expect-dev-ino closes uninstall.sh's check-then-act on unlink, --if-exists
# is how the installer and uninstaller ask for idempotent removal. Nothing else
# is accepted, because an option no caller passes is an unexercised code path.
COMMON_VALUED = {"expect-dev-ino"}
COMMON_FLAGS = {"if-exists"}

# (valued options, boolean flags, repeatable options, takes a `-- child argv`)
SPEC: dict[str, tuple[set[str], set[str], set[str], bool]] = {
    "read": ({"root", "rel", "max-bytes"}, {"allow-missing"}, set(), False),
    "stat": ({"root", "rel"}, {"allow-missing"}, set(), False),
    "edit": ({"root", "rel", "mode", "max-bytes", "max-output-bytes",
              "deadline-ms"}, set(), set(), True),
    "mkdir-chain": ({"root", "rel", "mode"}, set(), set(), False),
    "install-file": ({"src-root", "src-rel", "dst-root", "dst-rel", "mode",
                      "max-bytes"}, set(), set(), False),
    "prune-dir": ({"root", "rel"}, {"remove-all"}, {"keep"}, False),
    "unlink": ({"root", "rel"}, set(), set(), False),
    "symlink": ({"root", "rel", "target"}, {"replace"}, set(), False),
    "resolve-link": ({"root", "rel", "max-hops"}, {"require-regular"}, set(), False),
    "lock-run": ({"root", "rel"}, set(), set(), True),
    "run": ({"deadline-ms", "kill-grace-ms", "max-output-bytes", "max-lines",
             "max-line-bytes"}, {"setsid", "stderr-to-null"}, set(), True),
    "check-tool": (set(), set(), {"path"}, False),
}


class Options:
    """Parsed argv for one subcommand.

    Strict long options only: no abbreviation, no `-x` bundling, no positional
    arguments. Every value is named, so a value beginning with a dash cannot
    be mistaken for an option and a typo is an error rather than a silently
    different operation.
    """

    def __init__(self, command: str) -> None:
        self.command = command
        self.values: dict[str, str] = {}
        self.flags: set[str] = set()
        self.lists: dict[str, list[str]] = {}
        self.child: list[str] = []

    def value(self, name: str) -> str | None:
        return self.values.get(name)

    def flag(self, name: str) -> bool:
        return name in self.flags

    def repeated(self, name: str) -> list[str]:
        return self.lists.get(name, [])

    def require(self, name: str) -> str:
        if name not in self.values:
            usage_error("--%s is required" % name)
        return self.values[name]

    def open_parent(self, root_key: str = "root", rel_key: str = "rel",
                    create: bool = False) -> tuple[int, str]:
        return open_parent(self.require(root_key), self.require(rel_key),
                           create=create)


def parse_argv(argv: list[str]) -> Options:
    if not argv:
        usage_error("no subcommand")
    command = argv[0]
    if command not in SPEC:
        usage_error("unknown subcommand")
    valued, boolean, repeatable, takes_child = SPEC[command]
    valued = valued | COMMON_VALUED
    boolean = boolean | COMMON_FLAGS

    opts = Options(command)
    index = 1
    while index < len(argv):
        token = argv[index]
        if token == "--":
            if not takes_child:
                usage_error("this subcommand takes no child argv")
            opts.child = argv[index + 1:]
            break
        if not token.startswith("--"):
            usage_error("unexpected argument")
        name = token[2:]
        if name in boolean:
            opts.flags.add(name)
            index += 1
            continue
        if name in repeatable:
            if index + 1 >= len(argv):
                usage_error("--%s needs a value" % name)
            opts.lists.setdefault(name, []).append(argv[index + 1])
            index += 2
            continue
        if name in valued:
            if index + 1 >= len(argv):
                usage_error("--%s needs a value" % name)
            if name in opts.values:
                usage_error("--%s given twice" % name)
            opts.values[name] = argv[index + 1]
            index += 2
            continue
        usage_error("unknown option")
    return opts


HANDLERS = {
    "lock-run": command_lock_run,
    "read": command_read,
    "stat": command_stat,
    "edit": command_edit,
    "mkdir-chain": command_mkdir_chain,
    "install-file": command_install_file,
    "prune-dir": command_prune_dir,
    "unlink": command_unlink,
    "symlink": command_symlink,
    "resolve-link": command_resolve_link,
    "run": command_run,
    "check-tool": command_check_tool,
}


def report(command: str, message: str, code: int) -> None:
    """ONE bounded line on stderr. Never a traceback: it leaks absolute paths
    and interpreter internals into whatever log the caller is teeing, and no
    caller branches on anything but the exit code.

    There is exactly one format. A --json-errors variant used to live here and
    nothing in the plugin ever passed the flag, so the JSON branch was a second
    output shape that no caller parsed and no run exercised. `code` is kept in
    the signature because it is what the caller returns, not because it is
    printed.""" 
    try:
        write_fd(2, ("%s: %s: %s\n" %
                     (PROGNAME, sanitize(command), sanitize(message))).encode())
    except (ConfigError, OSError):
        pass  # Diagnostic failure must never block termination.


def main(argv: list[str]) -> int:
    command = "?"
    try:
        parent = os.getppid()
        handle = libc()
        if handle is None or handle.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0) != 0:
            fail("Linux parent-death notification is required")
        if os.getppid() != parent:
            raise SystemExit(143)
        opts = parse_argv(argv)
        command = opts.command
        HANDLERS[command](opts)
    except ConfigError as error:
        report(command, str(error), error.code)
        return error.code
    except OSError as error:
        report(command, error.strerror or str(error), EXIT_BOUNDARY)
        return EXIT_BOUNDARY
    except Exception:
        # Catch-all so an unforeseen bug still exits with a code the caller
        # understands, and still without a traceback. Deliberately says
        # nothing about what happened: if it is a bug, the detail would be
        # about our internals rather than about the user's filesystem.
        report(command, "internal error", EXIT_BOUNDARY)
        return EXIT_BOUNDARY
    return EXIT_OK


def terminate(signum: int, _frame: object) -> None:
    """Port of config.py:337-342.

    Raising SystemExit rather than dying in the default handler means the
    cleanup handlers run on the way out: the temp file is unlinked
    dirfd-relatively, the descriptors are closed, and supervise()'s
    `except BaseException` arm tears down and reaps the supervised child's
    whole process group before this exit propagates any further. A
    SIGTERM mid-transaction otherwise leaves an unpredictably named 0600 file
    in the user's config directory forever, and an orphaned process group.
    128+signum is the shell's own convention for "killed by N", so callers
    reading $? see what they expect.
    """
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise SystemExit(128 + signum)


signal.signal(signal.SIGINT, terminate)
signal.signal(signal.SIGTERM, terminate)

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
