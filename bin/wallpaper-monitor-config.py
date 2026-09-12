#!/usr/bin/python3
"""Descriptor-relative, no-follow, bounded, revalidating filesystem helper.

Port of the marketplace-approved
`omarchy-nightlight/bin/omarchy-nightlight-config.py` (commit 78d9fb4) onto
this plugin's boundaries, extended with the subcommand surface DESIGN.md
section 3.3 specifies. Function names, flag sets, validation order and the
publish transaction are kept deliberately identical to the reference so a
reviewer diffing the two files sees the same code; every divergence is marked
with a comment saying WHY.

Invocation
----------
    "$PYTHON3" -I -B "$WPM_HELPER" <subcommand> [options] [-- <child argv>]

Never executed directly: it ships mode 0644 with no executable bit, so the
shebang above is never read by the kernel (DESIGN.md D3 -- the missing
executable bit is the control, not the shebang text). `-I` neutralises
PYTHONPATH/PYTHONHOME/site; `-B` keeps __pycache__ out of the plugin dir.

Subcommand surface (DESIGN.md section 3.3 -- exactly these thirteen)
--------------------------------------------------------------------
  read          --root R --rel P [--max-bytes N] [--allow-missing]
  stat          --root R --rel P [--allow-missing]
  edit          --root R --rel P [--mode OCT] [--max-output-bytes N]
                [--deadline-ms N] -- <filter argv>
  mkdir-chain   --root R --rel D [--mode OCT]
  install-file  --src-root R1 --src-rel A --dst-root R2 --dst-rel B --mode OCT
                [--max-bytes N]
  prune-dir     --root R --rel D (--keep REL)... [--remove-all] [--if-exists]
                [--max-entries M]
  unlink        --root R --rel P [--if-exists] [--expect-dev-ino DEV:INO]
  rmdir         --root R --rel P [--if-exists]
  symlink       --root R --rel P --target T [--replace]
  rename        --root R --rel-from A --rel-to B
  resolve-link  --root R --rel P [--max-hops N] [--require-regular]
  run           [--setsid] [--deadline-ms N] [--kill-grace-ms N]
                [--max-output-bytes N] [--max-lines N] [--max-line-bytes N]
                [--stderr-to-null] -- <child argv>
  check-tool    (--path ABS)...

Common options (DESIGN.md section 3.2), accepted by the filesystem
subcommands: --root-follow-final, --trace, --expect-dev-ino, --if-exists,
--require-present, --json-errors, --max-bytes.

Call sites served
-----------------
  read          bin/wallpaper-monitor:188-253 (load_target), bin/wp:54-89,
                bin/wallpaper-monitor-menu:70-115 and :232-260 -- the four
                readers of background-per-monitor.json, three unhardened.
  edit          bin/wallpaper-monitor:256-296 (write_atomic) and every
                *_locked mutation; install.sh:299-363 and uninstall.sh:149-214
                (finalize_shell_json, duplicated verbatim) for both shell.json
                and the JSONC menu file; install.sh:452-473 / :628-640 and
                uninstall.sh:353-366 / :258-262, whose jq and awk programs are
                reused BYTE-IDENTICAL as the filter argv.
  mkdir-chain   install.sh:218, :286, :560; uninstall.sh:82, :97;
                bin/wallpaper-monitor:167.
  install-file  install.sh:234-247 (`rsync -a --delete` copy half + `chmod +x`);
                also the backup copies at install.sh:372-373, :604-605 and
                uninstall.sh:248-249, :340-341, which are a same-directory
                install-file with the source's mode.
  prune-dir     install.sh:234 (`--delete` half); uninstall.sh:390 (`rm -rf`).
  stat          every `[[ -L ]]` / `[[ -f ]]` / `stat -c %a` probe:
                install.sh:210, :265, :313, :326-327, :494-508;
                uninstall.sh:163, :179, :292.
  resolve-link  `readlink -f`: install.sh:495, :508; uninstall.sh:105, :295;
                bin/wp:19; bin/wallpaper-monitor-menu:30.
  symlink       install.sh:530 (`ln -s` in link_one).
  unlink/rmdir  uninstall.sh:296; bin/wallpaper-monitor:114-147 (lock teardown).
  rename        install.sh:350 / uninstall.sh:201 where a rename is not part of
                an edit transaction.
  run           every unbounded `$( ... )`: hyprctl (bin/wp:117, :172,
                bin/wallpaper-monitor:611), `file -b --mime-type`
                (bin/wallpaper-monitor:379), omarchy-menu-select /
                omarchy-menu-images (bin/wallpaper-monitor-menu:338, :381),
                and Background.qml's Process blocks.
  check-tool    the preamble's resolve-once tool table (DESIGN.md D4).

Exit codes (DESIGN.md section 3.4)
----------------------------------
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

`bin/wallpaper-monitor`'s own EXIT_UNREADABLE=2 / EXIT_LOCK=3 are unchanged and
are reached through the caller-side `wpm_map_exit()` of DESIGN.md section 3.4
(1|4|5|6 -> EXIT_UNREADABLE, 3|7 -> EXIT_LOCK, 2 -> 1), so no user-visible exit
code changes.

Errors are ONE bounded line on stderr:
    wallpaper-monitor-config: <subcommand>: <message>
or, with --json-errors, one line of JSON. A traceback is never printed: it
leaks absolute paths and interpreter internals into whatever log the caller is
teeing, and callers branch only on the exit code.

THE ONE DELIBERATE DIVERGENCE FROM THE APPROVED REFERENCE
---------------------------------------------------------
The reference always publishes mode 0600, because nightlight.conf is read by
nothing but nightlight. This plugin writes files the Omarchy shell reads --
notably ~/.config/omarchy/shell.json, typically 0644 -- and stamping 0600 onto
them would be a behaviour regression, not a hardening. So:

  * an EXISTING target keeps its own mode: the temp is fchmod'ed, on the held
    temp descriptor, to the mode read off the TARGET'S OWN VALIDATED
    DESCRIPTOR -- never off a pathname `stat`, which is what install.sh:327
    does today and which reports a symlink's 0777 and then stamps it onto the
    real file;
  * a NEW target gets 0600, or --mode when the caller declares one;
  * either way a group- or other-writable target is REFUSED, and a --mode with
    0o022 bits set is REFUSED. Preserving a mode is not accepting any mode: we
    preserve only modes that already passed the boundary check.

`install-file` is the documented exception and says so at its definition: a
payload file's mode is declared by the installer's allowlist (0644/0755), so
there --mode is authoritative. That is what replaces `chmod +x` at
install.sh:247, making the executable bit travel with the allowlist entry.

Python 3 standard library only, so it runs under the system python3 with -I.
"""

from __future__ import annotations

import ctypes
import errno
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
# The inventory flagged the status quo as both too loose and inconsistent:
# bin/wallpaper-monitor:185 uses 1 MiB, and bin/wp:57 /
# bin/wallpaper-monitor-menu:75 / :237 each re-declare the same 1 MiB as a bare
# literal next to an UNBOUNDED `fh.read()`. Four copies of a number only one of
# them enforces.
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

# run / edit supervision defaults (DESIGN.md D10).
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

# Set from argv in main(). Module-level because this is a single-shot CLI and
# threading them through every walk would add a parameter to every signature
# for no behavioural gain.
TRACE = False
JSON_ERRORS = False


class ConfigError(Exception):
    """An unsafe, malformed, or unavailable filesystem boundary.

    Carries the exit code the caller should see. The default is
    EXIT_BOUNDARY, because that is the honest answer for a rejection: the
    boundary did not hold up, and nothing was changed.
    """

    def __init__(self, message: str, code: int = EXIT_BOUNDARY) -> None:
        super().__init__(message)
        self.code = code
        self.errno_name = ""


def fail(message: str, code: int = EXIT_BOUNDARY) -> None:
    raise ConfigError(message, code)


def fail_os(message: str, error: OSError, code: int = EXIT_BOUNDARY) -> None:
    problem = ConfigError("%s: %s" % (message, error.strerror or error), code)
    problem.errno_name = errno.errorcode.get(error.errno or 0, "")
    raise problem


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
    """os.write loop. Short writes are normal on a pipe, and a partial write
    the caller then parses as a whole file is a correctness bug."""
    offset = 0
    while offset < len(data):
        try:
            offset += os.write(fd, data[offset:])
        except BrokenPipeError:
            # The consumer left. Every transaction is already committed or
            # already rolled back by the time payload is emitted.
            return


def emit_line(text: str) -> None:
    write_fd(1, (sanitize(text) + "\n").encode("utf-8", "replace"))


def emit_bytes(data: bytes) -> None:
    """File payload. `data` is already capped by read_bounded."""
    write_fd(1, data)


def trace(index: int, info: os.stat_result) -> None:
    """Per-component identity, on stderr (stdout stays reserved for payload).

    Component NAMES are deliberately not echoed: they came from the caller's
    own argv, and printing an attacker-influenced name into a log is a
    liability with no diagnostic value the numbers do not already carry.
    """
    if not TRACE:
        return
    sys.stderr.write(
        "wpm-config-trace: component=%d dev=%d ino=%d mode=%04o uid=%d gid=%d nlink=%d\n"
        % (index, info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode),
           info.st_uid, info.st_gid, info.st_nlink)
    )


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
    state the inventory flagged across the four existing readers.
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
            trace(index, info)
            if owner_rule == "system":
                if info.st_uid not in (0, os.geteuid()):
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


def open_root(root: str, follow_final: bool = False) -> int:
    """Open and validate the trusted root, holding its descriptor.

    Note the asymmetry, which is the reference's (config.py:70-86) and is
    deliberate: components ABOVE the root are traversed O_NOFOLLOW but not
    owner-checked, because / and /home belong to root and always will. The
    root itself gets the full fstat validation. A symlinked $HOME therefore
    fails -- intentionally, and identically to the approved reference.

    --root-follow-final is the documented escape hatch for a symlinked $HOME:
    it re-opens only the LAST component following symlinks, then applies the
    same fstat validation. Off by default; the shipped code never passes it.
    """
    components = check_root(root)
    if follow_final and components:
        parent = open_directory_path(components[:-1], False, DIR_MODE_DEFAULT, "none")
        if parent is None:
            fail("root directory does not exist", EXIT_ABSENT)
        try:
            dirfd = os.open(components[-1],
                            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC,
                            dir_fd=parent)
        except FileNotFoundError:
            os.close(parent)
            fail("root directory does not exist", EXIT_ABSENT)
        except OSError as error:
            os.close(parent)
            fail_os("could not open the root", error)
        os.close(parent)
    else:
        opened = open_directory_path(components, False, DIR_MODE_DEFAULT, "none")
        if opened is None:
            fail("root directory does not exist", EXIT_ABSENT)
        dirfd = opened
    try:
        trace(0, validate_dirfd(dirfd))
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
            trace(index, validate_dirfd(current))
        return current
    except BaseException:
        os.close(current)
        raise


def open_parent(root: str, rel: str, create: bool = False,
                mode: int = DIR_MODE_DEFAULT,
                follow_final_root: bool = False) -> tuple[int, str]:
    """Return (parent dirfd, basename) for a --root/--rel target.

    The returned descriptor is THE descriptor for the whole transaction. It is
    never re-derived from a pathname: validation, temp creation, revalidation,
    rename and fsync all go through this one fd. That is the invariant the
    shell code breaks at install.sh:356 and bin/wallpaper-monitor:289, where
    the directory is re-opened by name AFTER the rename -- possibly a
    different directory than the one the rename landed in.
    """
    components = split_rel(rel)
    basename = components[-1]
    rootfd = open_root(root, follow_final_root)
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
    arrives. A single os.read(fd, CAP) -- what bin/wallpaper-monitor:221 does
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
    bin/wallpaper-monitor:277 and install.sh:350 rename over whatever is at
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
    timestamp, and no fixed `.tmp` suffix. bin/wallpaper-monitor:267 uses
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
            # OWN VALIDATED DESCRIPTOR -- not a pathname stat. install.sh:327
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
        # landed in. install.sh:356 and bin/wallpaper-monitor:289 open the
        # directory by name after the fact and may fsync a different one.
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
    """DESIGN.md D4's authoritative tool check.

    Every parent from `/` is walked O_NOFOLLOW with uid in {0, euid} and no
    group/other write bit; the file itself must be a regular file with the
    same ownership and mode rule, plus the executable bit when required.

    DIVERGENCE FROM DESIGN.md's wording, stated plainly: the design says
    "same-directory-symlink policy". On Debian and Ubuntu /usr/bin/python3 is
    a symlink to /etc/alternatives/python3, which is NOT in the same
    directory, so a same-directory-only rule would reject the very interpreter
    the design pins. Instead a final-component symlink is followed for at most
    MAX_LINK_HOPS hops and EACH hop is re-anchored and re-validated through
    this same full walk. That is strictly stronger than "same directory" (a
    same-directory symlink to a world-writable file would pass the design's
    wording and fails here) and it does not break the default install.
    """
    if not path.startswith("/"):
        usage_error("tool path must be absolute")
    current = normalize_absolute(path)
    for _ in range(MAX_LINK_HOPS + 1):
        components = check_root(current)
        if not components:
            fail("tool path names the root directory")
        parent = open_directory_path(components[:-1], False, DIR_MODE_DEFAULT,
                                     "system")
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
                if info.st_uid not in (0, os.geteuid()):
                    fail("tool is owned by another user")
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


# --- Bounded, supervised child processes (DESIGN.md D10) ------------------


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


def teardown(pid: int, pgid: int | None, grace_ms: int) -> None:
    """SIGTERM -> grace -> SIGKILL on the GROUP, then reap to ECHILD.

    grace_ms defaults to 1000 and Background.qml's watchdog is 2000, so the
    helper always finishes escalating and reaping before QML gives up on the
    helper itself. Inverting that ordering is how grandchildren escape.
    """
    signal_group(pgid, pid, signal.SIGTERM)
    if wait_for(pid, grace_ms / 1000.0) == -1:
        signal_group(pgid, pid, signal.SIGKILL)
        wait_for(pid, 2.0)
    reap_remaining()


class Supervision:
    """Caps applied on the PRODUCER side, before anything is forwarded.

    Consumer-side bounding (`| head -c N`) was explicitly rejected: by the time
    the consumer truncates, the producer has already produced, and a producer
    that never stops is never stopped. Here the caps are checked as bytes
    arrive, and a breach tears the group down.
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
    """Run a child with its own session, a hard deadline and producer-side
    caps, and tear its whole group down on any failure.

    PR_SET_PDEATHSIG is set in the child so that if THIS process dies
    unexpectedly -- SIGKILL, a crash, the QML side giving up -- the kernel
    signals the child immediately instead of leaving an orphan attached to the
    user's session forever.
    """
    if not argv:
        usage_error("no child argv after '--'")
    validate_tool(argv[0], require_exec=True)
    libc()  # warm the loader BEFORE forking

    out_r, out_w = os.pipe()
    in_r, in_w = os.pipe()
    null_fd = os.open(os.devnull, os.O_WRONLY | os.O_CLOEXEC) if stderr_to_null else -1

    pid = os.fork()
    if pid == 0:                                        # --- child ---
        try:
            if use_setsid:
                os.setsid()
            handle = libc()
            if handle is not None:
                handle.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0)
            os.dup2(in_r, 0)
            os.dup2(out_w, 1)
            if null_fd >= 0:
                os.dup2(null_fd, 2)
            for fd in (in_r, in_w, out_r, out_w):
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
            os.execv(argv[0], argv)
        except BaseException:
            os._exit(127)
        os._exit(127)

    # --- parent ---
    os.close(in_r)
    os.close(out_w)
    if null_fd >= 0:
        os.close(null_fd)
    # setsid() makes the child a group leader, so its pid IS its pgid. Without
    # --setsid we only have the child itself to signal.
    pgid = pid if use_setsid else None

    caps = Supervision(max_output_bytes, max_lines, max_line_bytes)
    deadline = time.monotonic() + deadline_ms / 1000.0
    pending = stdin_data
    breach: str | None = None
    expired = False

    os.set_blocking(out_r, False)
    os.set_blocking(in_w, False)
    poller = select.poll()
    poller.register(out_r, select.POLLIN)
    if pending:
        poller.register(in_w, select.POLLOUT)
    else:
        os.close(in_w)
        in_w = -1

    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                expired = True
                break
            for fd, event in poller.poll(int(min(remaining, 0.25) * 1000.0)):
                if fd == out_r and event & (select.POLLIN | select.POLLHUP):
                    chunk = os.read(out_r, READ_CHUNK)
                    if not chunk:
                        poller.unregister(out_r)
                        os.close(out_r)
                        out_r = -1
                        break
                    breach = caps.feed(chunk)
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
            if breach or out_r == -1:
                break
    finally:
        for fd in (out_r, in_w):
            if fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass

    if breach:
        teardown(pid, pgid, grace_ms)
        fail(breach, EXIT_OUTPUT_CAP)
    if expired:
        teardown(pid, pgid, grace_ms)
        fail("child exceeded the %d ms deadline" % deadline_ms, EXIT_DEADLINE)

    # A floor of one second: stdout is closed, so the child is exiting; a
    # zero-length wait here would report a bogus deadline breach for a child
    # that simply had not been reaped yet.
    status = wait_for(pid, max(1.0, deadline - time.monotonic()))
    if status == -1:
        teardown(pid, pgid, grace_ms)
        fail("child exceeded the %d ms deadline" % deadline_ms, EXIT_DEADLINE)
    reap_remaining()
    if status is not None:
        if os.WIFSIGNALED(status):
            transaction_error("child was killed by signal %d" % os.WTERMSIG(status))
        if os.WIFEXITED(status) and os.WEXITSTATUS(status) != 0:
            transaction_error("child exited %d" % os.WEXITSTATUS(status))
    return caps.data()


# --- Subcommands ---------------------------------------------------------


def check_entry_cap(data: bytes) -> None:
    """Bound the ENTRY COUNT of a JSON payload before it is published.

    The reference has this (config.py:16 / :161-162) and this repo has it
    nowhere: `data["monitors"][monitor] = image` at bin/wallpaper-monitor:440
    grows without limit, and Background.qml:97 JSON.parse accepts an object of
    any size. A config that is under the byte cap can still be an object with
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
            if opts.flag("allow-missing") and not opts.flag("require-present"):
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
            if opts.flag("allow-missing") and not opts.flag("require-present"):
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
    ONE dirfd (DESIGN.md D8).

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
            if opts.flag("require-present"):
                fail("target does not exist", EXIT_ABSENT)
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
    rootfd = open_root(opts.require("root"), opts.flag("root-follow-final"))
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

    Replaces the per-file half of `rsync -a --delete` (install.sh:234-246) and
    the `chmod +x` at :247. rsync re-resolves every path by name inside a
    process we do not control, so no descriptor can be held across validation
    and copy; the scar at install.sh:205-217 -- a symlinked plugin dir whose
    target's contents `--delete` erased -- is that property showing up as a
    bug report.

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
    # redirecting the payload -- which is the bug install.sh:210 guards by
    # hand, and only for the final component.
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
    the difference from `rm -rf "$PLUGIN_DIR"` at uninstall.sh:390, whose only
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
    max_entries = min(parse_positive(opts.value("max-entries"), "--max-entries")
                      if opts.value("max-entries") else MAX_PRUNE_ENTRIES,
                      MAX_PRUNE_ENTRIES)
    keep = build_keep_tree(opts.repeated("keep"))
    remove_all = opts.flag("remove-all")
    if remove_all and keep:
        usage_error("--remove-all and --keep are mutually exclusive")

    components = split_rel(opts.require("rel"))
    rootfd = open_root(opts.require("root"), opts.flag("root-follow-final"))
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
            fail("target is a directory; use rmdir or prune-dir")

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


def command_rmdir(opts: Options) -> None:
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
        if stat.S_ISLNK(info.st_mode):
            # rmdir on a symlink-to-directory would fail anyway; saying so is
            # better than surfacing ENOTDIR.
            fail("target is a symlink, not a directory")
        if not stat.S_ISDIR(info.st_mode):
            fail("target is not a directory")
        check_expected_identity(info, opts.value("expect-dev-ino"))
        try:
            os.rmdir(basename, dir_fd=dirfd)
        except OSError as error:
            fail_os("could not remove the directory", error)
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


def command_rename(opts: Options) -> None:
    """renameat(dirfd_a, A, dirfd_b, B), both ends descriptor-relative."""
    from_dirfd, from_name = opts.open_parent(rel_key="rel-from")
    to_dirfd = -1
    try:
        to_dirfd, to_name = opts.open_parent(rel_key="rel-to")
        if os.fstat(from_dirfd).st_dev != os.fstat(to_dirfd).st_dev:
            # rename(2) cannot cross filesystems, and the caller almost
            # certainly meant an atomic replace. Failing here beats a
            # half-copied file: /tmp is tmpfs and $HOME is btrfs on the
            # developer's own machine, which is why install.sh:378-384 puts
            # its temp file in the destination directory in the first place.
            fail("source and destination are on different filesystems")
        try:
            os.replace(from_name, to_name, src_dir_fd=from_dirfd,
                       dst_dir_fd=to_dirfd)
        except OSError as error:
            fail_os("could not rename", error, EXIT_TRANSACTION)
        os.fsync(from_dirfd)
        os.fsync(to_dirfd)
    finally:
        os.close(from_dirfd)
        if to_dirfd >= 0:
            os.close(to_dirfd)


def command_resolve_link(opts: Options) -> None:
    """`readlink -f`, bounded and without following a directory symlink.

    Hops are resolved only while the result stays inside --root: a target that
    leaves the trusted subtree is reported as-is rather than chased through
    directories we have no business validating. Callers (install.sh:495,
    uninstall.sh:295) compare the answer to a path they already know, so a
    string is exactly what they need.
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
        if not (resolved == root or resolved.startswith(root + "/")):
            # The chain left the trusted subtree. Report where it pointed
            # rather than walking directories we have no standing to validate.
            break
        relative = resolved[len(root):].lstrip("/")
        if not relative:
            break
        try:
            dirfd, basename = open_parent(
                root, relative, follow_final_root=opts.flag("root-follow-final"))
        except ConfigError as error:
            # A missing directory BELOW the first hop means the link dangles.
            # `readlink -f` reports the path anyway, and install.sh:504-516
            # depends on being told about a dangling link rather than an
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


def command_run(opts: Options) -> None:
    """Bounded, supervised child (DESIGN.md D10).

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

# Common options every filesystem subcommand accepts (DESIGN.md section 3.2).
COMMON_VALUED = {"expect-dev-ino"}
COMMON_FLAGS = {"root-follow-final", "trace", "json-errors", "if-exists",
                "require-present"}

# (valued options, boolean flags, repeatable options, takes a `-- child argv`)
SPEC: dict[str, tuple[set[str], set[str], set[str], bool]] = {
    "read": ({"root", "rel", "max-bytes"}, {"allow-missing"}, set(), False),
    "stat": ({"root", "rel"}, {"allow-missing"}, set(), False),
    "edit": ({"root", "rel", "mode", "max-bytes", "max-output-bytes",
              "deadline-ms"}, set(), set(), True),
    "mkdir-chain": ({"root", "rel", "mode"}, set(), set(), False),
    "install-file": ({"src-root", "src-rel", "dst-root", "dst-rel", "mode",
                      "max-bytes"}, set(), set(), False),
    "prune-dir": ({"root", "rel", "max-entries"}, {"remove-all"}, {"keep"}, False),
    "unlink": ({"root", "rel"}, set(), set(), False),
    "rmdir": ({"root", "rel"}, set(), set(), False),
    "symlink": ({"root", "rel", "target"}, {"replace"}, set(), False),
    "rename": ({"root", "rel-from", "rel-to"}, set(), set(), False),
    "resolve-link": ({"root", "rel", "max-hops"}, {"require-regular"}, set(), False),
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
                           create=create,
                           follow_final_root=self.flag("root-follow-final"))


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
    "read": command_read,
    "stat": command_stat,
    "edit": command_edit,
    "mkdir-chain": command_mkdir_chain,
    "install-file": command_install_file,
    "prune-dir": command_prune_dir,
    "unlink": command_unlink,
    "rmdir": command_rmdir,
    "symlink": command_symlink,
    "rename": command_rename,
    "resolve-link": command_resolve_link,
    "run": command_run,
    "check-tool": command_check_tool,
}


def report(command: str, message: str, code: int, errno_name: str = "") -> None:
    """ONE bounded line on stderr. Never a traceback: it leaks absolute paths
    and interpreter internals into whatever log the caller is teeing, and no
    caller branches on anything but the exit code."""
    if JSON_ERRORS:
        line = json.dumps({
            "tool": PROGNAME,
            "cmd": sanitize(command),
            "code": code,
            "errno": errno_name,
            "message": sanitize(message),
        }, ensure_ascii=True)
        sys.stderr.write(line[:MAX_MESSAGE_BYTES * 2] + "\n")
        return
    sys.stderr.write("%s: %s: %s\n"
                     % (PROGNAME, sanitize(command), sanitize(message)))


def main(argv: list[str]) -> int:
    global TRACE, JSON_ERRORS
    TRACE = "--trace" in argv
    JSON_ERRORS = "--json-errors" in argv
    command = "?"
    try:
        opts = parse_argv(argv)
        command = opts.command
        HANDLERS[command](opts)
    except ConfigError as error:
        report(command, str(error), error.code, error.errno_name)
        return error.code
    except OSError as error:
        report(command, error.strerror or str(error), EXIT_BOUNDARY,
               errno.errorcode.get(error.errno or 0, ""))
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
    `finally` blocks run: the temp file is unlinked dirfd-relatively, the
    supervised child's group is torn down, and the descriptors are closed. A
    SIGTERM mid-transaction otherwise leaves an unpredictably named 0600 file
    in the user's config directory forever, and an orphaned process group.
    128+signum is the shell's own convention for "killed by N", so callers
    reading $? see what they expect.
    """
    raise SystemExit(128 + signum)


signal.signal(signal.SIGINT, terminate)
signal.signal(signal.SIGTERM, terminate)

if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
