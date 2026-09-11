#!/bin/bash
# OPTIONAL AND MANUAL. Nothing runs this for you: Omarchy has no install hook,
# and `omarchy plugin remove` runs nothing either.
#
# Unlike a bar-widget plugin, this one is a "service" that REPLACES the native
# background (it disables omarchy.background in shell.json), so installing it
# does three things, in order:
#
#   1. Copies this repo into ~/.config/omarchy/plugins/vitorcanoas.background-per-monitor/
#      -- but only the files named in the allowlist at step 1 below
#      (manifest.json, Background.qml, bin/, and the docs a user may want to
#      read in place). Anything not on that list is NOT installed, including
#      any file added to the repo later.
#   2. Registers the plugin and disables the native one in
#      ~/.config/omarchy/shell.json (backed up first), and records in
#      cloneSourceRestores[] that THIS plugin is what disabled the native
#      one -- which is what lets uninstall.sh put it back. manifest.json
#      declares omarchy.clonedFrom for the same reason.
#   3. Symlinks wallpaper-monitor, wp and wallpaper-monitor-menu into
#      ~/.local/bin, so they work as bare commands from anywhere.
#   4. Adds a "Wallpaper per monitor" row to the SUPER+SPACE menu, by
#      appending a marker-delimited block to
#      ~/.config/omarchy/extensions/omarchy-menu.jsonc (backed up first, and
#      edited as text -- it is JSONC, so it is never re-serialized as JSON;
#      see add_menu_entry below).
#
# DRY_RUN=1 ./install.sh prints every step above without touching the real
# plugin directory or the real shell.json -- it copies into a throwaway
# staging directory instead. Use it to see what the script would do before
# trusting it near a shell.json that is in active use:
#
#     DRY_RUN=1 ./install.sh
#
# To undo a real install, run ./uninstall.sh (mirrors this script's safety
# rules: $HOME-explicit, DRY_RUN=1 to preview, idempotent). It does not
# touch ~/.config/omarchy/shell.json.bak.* -- see below.
#
# Every real (non-DRY_RUN) run that finds an existing shell.json backs it up
# first as shell.json.bak.<timestamp>, and these backups are NOT rotated or
# cleaned up automatically, by this script or by uninstall.sh -- they
# accumulate in ~/.config/omarchy/ across repeated installs. Remove old ones
# by hand once you no longer need them:
#
#     rm -f ~/.config/omarchy/shell.json.bak.*

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PLUGIN_ID="vitorcanoas.background-per-monitor"
NATIVE_PLUGIN_ID="omarchy.background"

DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in
  0|1) ;;
  *)
    printf 'DRY_RUN must be 0 or 1 (got %q). Refusing to guess -- e.g. "true" is\nnot 1 and would otherwise silently run a REAL install.\n' "$DRY_RUN" >&2
    exit 1
    ;;
esac

## Deliberately NOT honoring XDG_CONFIG_HOME/XDG_BIN_HOME here: Omarchy's own
## migrations always resolve shell.json as "$HOME/.config/omarchy/shell.json"
## (see e.g. /usr/share/omarchy/migrations/1785344985.sh), never through the
## XDG variable. Following that same convention keeps this installer
## consistent with the shell.json Omarchy itself will read/write, and -- as a
## bonus -- makes `HOME=/fake/home bash install.sh` fully sandboxed: on a
## real desktop session XDG_CONFIG_HOME is exported (e.g. by the display
## manager) as an ABSOLUTE path pointing at the real home, so it does not
## follow a test HOME override, and reading it here would silently escape
## the fake home and touch the real ~/.config/omarchy/shell.json.
OMARCHY_CONFIG_DIR="$HOME/.config/omarchy"
BIN_DIR="$HOME/.local/bin"

# The SUPER+SPACE menu is extended through this JSONC file, which Omarchy's
# shell merges over its own default menu at runtime (watchChanges: true, so an
# edit shows up without restarting the shell).
MENU_JSONC="$OMARCHY_CONFIG_DIR/extensions/omarchy-menu.jsonc"

# Our menu row is delimited by these comment markers so it can be removed
# again byte-for-byte. See add_menu_entry() for why the file is edited as
# TEXT and never re-serialized as JSON.
MENU_MARK_BEGIN="// >>> $PLUGIN_ID (managed by install.sh -- do not edit inside)"
MENU_MARK_END="// <<< $PLUGIN_ID"

# The menu row itself.
#
# id "style.wallpaper-per-monitor": a NEW id under the existing "style"
# submenu, so the row lands right next to the native "Background" it
# complements. Reusing an existing id would OVERRIDE that native entry rather
# than sit beside it -- "style.background" in particular is the native theme
# wallpaper row, and taking it over would remove a feature while adding ours.
#
# aliases deliberately avoid "background" and "wallpaper": the native
# "style.background" already claims both, and duplicating them would make
# typing "wallpaper" return two competing rows. "per-monitor" and
# "monitor-wallpaper" are unambiguous, and `description` gives the search
# index extra words to match on without that collision.
#
# The action is a bare command, not the native
# `x=$(switcher); [[ -n $x ]] && apply "$x"` two-step: our script runs the
# whole flow (pick monitor -> pick image -> apply) and already exits 0 without
# applying anything when the user cancels, so there is no intermediate value
# for the menu to test.
menu_entry_line() {
  printf '  "style.wallpaper-per-monitor": {"icon":"󰹑","label":"Wallpaper per monitor","aliases":["per-monitor","monitor-wallpaper"],"description":"Set a different wallpaper on each monitor","action":"wallpaper-monitor-menu"},\n'
}

menu_entry_block() {
  printf '%s\n' "$MENU_MARK_BEGIN"
  menu_entry_line
  printf '%s\n' "$MENU_MARK_END"
}

# Single cleanup trap for the whole script (DRY_RUN staging dir and/or the
# real-path TMP_JSON below) -- a second `trap ... EXIT` would silently
# replace this one rather than stack, so anything that needs cleanup on exit
# must be added to this same function instead of calling `trap` again.
cleanup() {
  [[ -n "${STAGE:-}" ]] && rm -rf "$STAGE"
  [[ -n "${TMP_JSON:-}" ]] && rm -f "$TMP_JSON"
  [[ -n "${TMP_MENU:-}" ]] && rm -f "$TMP_MENU"
  return 0
}
trap cleanup EXIT

if [[ $DRY_RUN == 1 ]]; then
  STAGE="$(mktemp -d)"
  PLUGIN_DIR="$STAGE/plugins/$PLUGIN_ID"
  SHELL_JSON="$STAGE/shell.json"
  mkdir -p "$STAGE/plugins" "$(dirname "$BIN_DIR")"
  BIN_DIR="$STAGE/local-bin"
  # Seed a shell.json so the dry run has something realistic to show a diff
  # against, if a real one already exists; otherwise start from empty.
  if [[ -f "$OMARCHY_CONFIG_DIR/shell.json" ]]; then
    cp "$OMARCHY_CONFIG_DIR/shell.json" "$SHELL_JSON"
  else
    printf '{}\n' >"$SHELL_JSON"
  fi
  # Same for the menu extension file: seed the staging copy from the real one
  # (when it exists) so the dry run reports exactly what a real run would do
  # -- in particular whether our block is already present.
  real_menu_jsonc="$MENU_JSONC"
  MENU_JSONC="$STAGE/extensions/omarchy-menu.jsonc"
  mkdir -p "$STAGE/extensions"
  if [[ -f "$real_menu_jsonc" ]]; then
    cp "$real_menu_jsonc" "$MENU_JSONC"
  fi
  printf 'DRY RUN: no real files under ~/.config/omarchy or ~/.local/bin will be touched.\n'
  printf 'DRY RUN: staging in %s\n\n' "$STAGE"
else
  PLUGIN_DIR="$OMARCHY_CONFIG_DIR/plugins/$PLUGIN_ID"
  SHELL_JSON="$OMARCHY_CONFIG_DIR/shell.json"
fi

if ! command -v jq >/dev/null 2>&1; then
  cat >&2 <<'MSG'
jq is required to edit shell.json safely and was not found.

    yay -S jq

MSG
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  cat >&2 <<'MSG'
rsync is required to copy the plugin files and was not found.

    yay -S rsync

MSG
  exit 1
fi

if ! command -v omarchy >/dev/null 2>&1; then
  cat >&2 <<'MSG'
omarchy was not found on PATH. This installer registers a plugin in
~/.config/omarchy/shell.json for Omarchy's Quickshell to load -- without
Omarchy actually installed, that file being created/edited would look like a
successful install while there is no shell around to ever load the plugin.

MSG
  exit 1
fi

if ! command -v omarchy-shell >/dev/null 2>&1; then
  cat >&2 <<'MSG'
Warning: omarchy-shell is not on PATH. Installing will proceed, but the
running shell will not pick up the new plugin until you restart it (or run
omarchy-shell yourself once it is available).

MSG
fi

# --- 1. Copy the plugin payload -------------------------------------------
#
# rsync rather than a symlink: omarchy-plugin-validate refuses symlinks
# inside a plugin directory, and a stray edit to the installed copy should
# not silently leak back into the git checkout (or vice versa).
printf '==> installing plugin files to %s\n' "$PLUGIN_DIR"

# Refuse a symlinked plugin directory before rsync --delete runs. `mkdir -p` is
# a silent no-op on an existing symlink-to-directory, and rsync then follows it
# and applies --delete INSIDE the link's target: every file there that is not
# part of this plugin is erased. Reproduced with a link to a directory holding
# unrelated files -- all of them were deleted by the first ./install.sh.
# Omarchy's validator already refuses symlinks inside a plugin directory, so
# there is no legitimate reason for this path to be one.
if [[ -L $PLUGIN_DIR ]]; then
  printf >&2 '%s\n' \
    "error: $PLUGIN_DIR is a symlink." \
    "Refusing to install: rsync --delete would erase the contents of whatever" \
    "it points at ($(readlink -- "$PLUGIN_DIR"))." \
    "Remove or move the symlink aside, then run this installer again."
  exit 1
fi
mkdir -p "$PLUGIN_DIR"

# ALLOWLIST, not a list of exclusions. The payload is exactly the files the
# plugin needs at runtime, and anything new in the repo is NOT installed unless
# it is named here.
#
# This used to be a deny-list, which shipped whatever nobody had thought to
# exclude. That is how a maintainer-only file that has no business on an
# installed plugin ended up written into the user's plugin directory. A
# deny-list cannot fix the class of bug -- the next such file ships the same
# way, by omission.
# An allowlist fails closed instead: a new file is left out until someone
# adds it deliberately.
#
# `--include` order matters: directories must be included before their
# contents, and the final `--exclude '*'` drops everything unnamed.
rsync -a --delete \
  --include 'Background.qml' \
  --include 'manifest.json' \
  --include 'install.sh' \
  --include 'uninstall.sh' \
  --include 'README.md' \
  --include 'LICENSE' \
  --include 'bin/' \
  --include 'bin/wallpaper-monitor' \
  --include 'bin/wp' \
  --include 'bin/wallpaper-monitor-menu' \
  --exclude '*' \
  "$HERE"/ "$PLUGIN_DIR"/
chmod +x "$PLUGIN_DIR/bin/wallpaper-monitor" "$PLUGIN_DIR/bin/wp" "$PLUGIN_DIR/bin/wallpaper-monitor-menu"

# --- 1b. Pre-flight check that all symlinks CAN be created -----------------
#
# Deliberately done before touching shell.json (step 2&3 below). shell.json
# edits and symlink creation are not one atomic transaction, and jq/mv on
# shell.json has no rollback -- so if a later link_one call died (e.g. an
# unrelated ~/.local/bin/wp from another tool), the user would be left with
# shell.json already pointing at this plugin and the native background
# already disabled, but the CLI not actually reachable, with an error message
# that never mentions shell.json was touched. Running a side-effect-free dry
# pass over all 3 links first means the real work in step 4 either succeeds
# for all of them or step 2&3 never runs at all.
check_link_one() {
  local name=$1
  local target="$PLUGIN_DIR/bin/$name"
  local link="$BIN_DIR/$name"

  if [[ -e $link || -L $link ]]; then
    # Our own symlink (live or dangling) is fine -- link_one in step 4 will
    # either skip it (already correct) or replace it (dangling/stale).
    if [[ -L $link ]]; then
      return 0
    fi

    cat >&2 <<MSG
$link already exists and is not this plugin's symlink.

Refusing to install. Nothing has been changed yet -- shell.json and the
plugin's other symlinks are untouched. Move $link aside first, or skip the
symlink step and call the plugin's bin/ directly:

    $target

MSG
    exit 1
  fi
}

mkdir -p "$BIN_DIR"
check_link_one wallpaper-monitor
check_link_one wp
check_link_one wallpaper-monitor-menu

# --- 2 & 3. Register the plugin and disable the native one ----------------
#
# Preserves the target's existing permission mode (mktemp always creates the
# temp file 0600, and a plain `mv` would carry that into shell.json) and
# fsyncs the temp file + its directory before and after the rename, so the
# write is durable and not just atomic-for-visibility. Same approach as
# bin/wallpaper-monitor's write_atomic(): chmod before rename, fsync(file)
# before rename, fsync(dir) after.
finalize_shell_json() {
  local tmp=$1
  local dest=$2
  local dir
  dir="$(dirname "$dest")"

  # A symlink here is refused rather than followed. `[[ -f ]]` is true for a
  # symlink to a regular file, and `stat` without -L reports the LINK's own
  # mode (0777 on Linux), which chmod would then stamp onto the real file this
  # function creates -- a world-writable shell.json, editable by any local
  # user, from a config the shell loads at startup. The rename would also
  # replace the user's link with a regular file, and the caller's backup would
  # have copied the link target's contents to a predictable path. None of that
  # is recoverable automatically, so stop and let the user decide.
  if [[ -L $dest ]]; then
    printf >&2 '%s\n' \
      "error: $dest is a symlink." \
      "Refusing to replace it: this would create a regular file with the" \
      "symlink's own permissions and discard the link." \
      "Resolve it to a regular file first, then run this again."
    exit 1
  fi

  # New file (fresh install, no prior shell.json) gets 0600 -- same default
  # write_atomic() picks when stat() fails. An existing file keeps its own
  # mode instead of silently inheriting mktemp's 0600.
  local mode=600
  if [[ -f $dest ]]; then
    mode="$(stat -c %a -- "$dest")"
  fi
  chmod "$mode" "$tmp"

  # fsync the temp file's contents, THEN rename, THEN fsync the directory.
  # rename(2) is atomic for visibility (a reader never sees a half-written
  # file) but says nothing about durability -- without this, a power cut
  # right after install/uninstall can leave the rename durable while the
  # data behind it is not, corrupting the file the whole shell reads at
  # startup. A failure here must abort before the rename, not be swallowed:
  # under `set -e` a non-zero exit from python3 does exactly that.
  python3 -c '
import os
import sys

tmp_path = sys.argv[1]
fd = os.open(tmp_path, os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
' "$tmp"

  mv "$tmp" "$dest"

  python3 -c '
import os
import sys

directory = sys.argv[1]
dfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(dfd)
finally:
    os.close(dfd)
' "$dir"
}

# Back up shell.json before touching it -- it is hand-edited, human-owned
# config, not something regenerated on demand.
if [[ -f $SHELL_JSON ]]; then
  # %N (nanoseconds, GNU date) rather than second resolution: two installs
  # run back-to-back (e.g. testing idempotency, or a script driving this)
  # can land in the same second, and second-resolution backups would then
  # silently clobber each other -- losing the backup of the ORIGINAL state.
  BACKUP="$SHELL_JSON.bak.$(date +%Y%m%d-%H%M%S-%N)"
  cp "$SHELL_JSON" "$BACKUP"
  printf '==> backed up %s -> %s\n' "$SHELL_JSON" "$BACKUP"
else
  printf '{}\n' >"$SHELL_JSON"
fi

# Temp file in the DESTINATION directory, not /tmp: on this system /tmp is
# tmpfs and $HOME is btrfs, so `mv` across them is copy+unlink, not an atomic
# rename. A crash mid-copy would leave a TRUNCATED shell.json -- which is the
# file the whole shell reads at startup. Same directory means same filesystem
# means rename(2), which is atomic: readers see either the old file or the new
# one, never half of one.
TMP_JSON="$(mktemp -p "$(dirname "$SHELL_JSON")" .shell.json.XXXXXX)"
# plugins[] entries are objects ({"id": "..."}, sometimes with extra
# per-plugin settings alongside), not bare strings -- confirmed against a
# real shell.json. disabledPlugins[] is a flat string array. Dedupe plugins[]
# by .id so re-running this script never produces two entries for the same
# plugin.
#
# cloneSourceRestores[] is the third array, and it is the reason manifest.json
# declares `omarchy.clonedFrom`. It records WHICH clone is responsible for its
# source being in disabledPlugins[] -- the ownership fact whose absence used to
# make uninstall unable to restore the native background safely.
#
# We write all three arrays here rather than shelling out to
# `omarchy plugin enable`, even though that CLI would produce the same result
# via the shell's PluginRegistry.setEnabled(). Two measured reasons:
#
#   1. `omarchy plugin enable` is IPC to the RUNNING shell (omarchy-shell
#      shell enablePlugin). On a fresh machine, or from an install script run
#      before the shell is up, there is no shell to answer and the install
#      would fail at the one step that matters.
#   2. It always targets the real ~/.config/omarchy/shell.json. DRY_RUN=1
#      stages a throwaway copy, so an IPC call would ignore $SHELL_JSON and
#      mutate the user's live config -- exactly what DRY_RUN promises not to do.
#
# So this stays a file edit, but it must be byte-compatible with what the
# shell writes, because `omarchy plugin disable` may later read it. Shape
# taken from PluginRegistry.qml: setEnabled() appends the source to
# disabledPlugins[] and calls setCloneShouldRestoreSource(clone, true) only
# when the source is not ALREADY disabled.
#
# We cannot copy that guard literally. The shell's version runs only on the
# off->on TRANSITION, so "already disabled" there means "somebody else did
# it". install.sh is idempotent and re-runnable, so on every run after the
# first the native IS already disabled -- by US. Reusing the literal guard
# would therefore refuse to claim ownership on re-install and quietly leave
# uninstall unable to restore, which is the very bug this change fixes.
#
# Note also that cloneSourceRestores[] stores only CLONE ids, never which
# source each one claims. On this developer's own machine it contains
# "vitorcanoas.lock", which claims omarchy.lock -- nothing to do with the
# background. So the array cannot be read to learn who disabled
# omarchy.background; that ambiguity is in Omarchy's format, not something we
# can resolve here.
#
# What we can state truthfully is our own claim. We add our id when we are the
# plugin taking over the background, and uninstall.sh removes only our own id
# and only restores the native when our id is the one present. If a future
# second clone of omarchy.background is ever installed alongside this one,
# whichever is uninstalled last restores the native -- the same
# last-one-out behaviour the shell has.
#
# But we claim ONLY when the disable is ours to claim. Three cases, and the
# guard below is the one expression that gets all three right:
#
#   1. native ENABLED  -> we are the ones disabling it, so we claim. Restore
#      on uninstall is correct and is the whole point of this change.
#   2. native already disabled AND our id already in cloneSourceRestores[]
#      -> this is a re-install, the claim was already ours, keep it. This is
#      the idempotence case the shell's literal `!isDisabled` guard gets
#      wrong, which is why we do not copy that guard verbatim.
#   3. native already disabled and our id is NOT there -> somebody else did
#      it: the user by hand (`omarchy plugin disable omarchy.background`) or
#      another clone. We must NOT claim. Claiming would make our uninstall
#      re-enable a plugin the user deliberately turned off, or steal a
#      foreign clone's claim and then re-enable the native to draw over it.
#      We still disable the native (idempotent no-op here) because we need it
#      off to run; we simply do not assert ownership of that state.
jq \
  --arg plugin "$PLUGIN_ID" \
  --arg native "$NATIVE_PLUGIN_ID" \
  '
  .plugins = (
    if ((.plugins // []) | any(.id == $plugin))
    then (.plugins // [])
    else ((.plugins // []) + [{id: $plugin}])
    end
  ) |
  .cloneSourceRestores = (
    if ((.disabledPlugins // []) | index($native)) == null
       or ((.cloneSourceRestores // []) | index($plugin)) != null
    then ((.cloneSourceRestores // []) + [$plugin] | unique)
    else (.cloneSourceRestores // [])
    end
  ) |
  .disabledPlugins = ((.disabledPlugins // []) + [$native] | unique) |
  (if (.cloneSourceRestores | length) == 0
   then del(.cloneSourceRestores) else . end)
  ' \
  "$SHELL_JSON" >"$TMP_JSON"
# jq wrote through the shell's redirection, which opened $TMP_JSON at
# mktemp's mode 0600 -- a plain `mv` would carry that mode into $SHELL_JSON,
# silently narrowing it if the user's file was e.g. 0644. fsync both the file
# and its directory before the rename lands, matching the durability
# discipline bin/wallpaper-monitor's write_atomic() uses for the same reason:
# rename(2) is atomic for visibility but not for durability, and this is the
# file the whole shell reads at startup.
finalize_shell_json "$TMP_JSON" "$SHELL_JSON"
printf '==> registered %s and disabled %s in %s\n' "$PLUGIN_ID" "$NATIVE_PLUGIN_ID" "$SHELL_JSON"

# --- 4. Symlink the CLIs into ~/.local/bin ---------------------------------
# BIN_DIR was already created during the pre-flight check above; the check
# already ruled out any foreign (non-symlink) file at each of these paths,
# so the only things link_one can still find here are: nothing, our own live
# symlink, or our own dangling symlink -- all handled below.
link_one() {
  local name=$1
  local target="$PLUGIN_DIR/bin/$name"
  local link="$BIN_DIR/$name"

  if [[ -e $link || -L $link ]]; then
    if [[ -L $link && $(readlink -f "$link") == "$(readlink -f "$target")" ]]; then
      printf 'already linked: %s\n' "$link"
      return 0
    fi

    # A dangling symlink of our own name is almost always this installer's
    # earlier work, from a plugin folder that has since moved or been
    # reinstalled. Treated as a foreign file, it would refuse to replace a
    # dead link nothing else can repair. Say what it is and offer the fix.
    if [[ -L $link && ! -e $link ]]; then
      cat >&2 <<MSG
$link is a broken symlink, pointing at:

    $(readlink "$link")

That target no longer exists. Clear it before installing again:

    rm -f "$link" && "$HERE/install.sh"

MSG
      exit 1
    fi

    cat >&2 <<MSG
$link already exists and is not this plugin's symlink.

Refusing to replace it. Move it aside first, or skip the symlink step and
call the plugin's bin/ directly:

    $target

MSG
    exit 1
  fi

  ln -s "$target" "$link"
  printf 'linked %s -> %s\n' "$link" "$target"
}

link_one wallpaper-monitor
link_one wp
link_one wallpaper-monitor-menu

# --- 5. Add the row to the SUPER+SPACE menu --------------------------------
#
# ~/.config/omarchy/extensions/omarchy-menu.jsonc is merged over Omarchy's own
# default menu at runtime. Adding a row there is what makes the plugin
# reachable from SUPER+SPACE; the plugin itself stays kinds:["service"] (a
# kind:"menu" plugin opens a SEPARATE window over IPC, it does not add a row
# to the main menu, so it is not what we want here).
#
# THIS FILE IS EDITED AS TEXT, NEVER RE-SERIALIZED.
#
# It is the user's own file and it is JSONC: comments and trailing commas are
# legal in it, and both are things a strict JSON parser rejects. Round-tripping
# it through jq/python would either fail outright or -- worse -- succeed and
# silently write back a normalized file with every one of the user's comments
# deleted. So we only ever append or cut a block delimited by our own comment
# markers, leaving every other byte exactly as it was.
#
# Idempotent: a run that finds the markers already present changes nothing.
# Reversible: uninstall.sh cuts the same marker block back out.
add_menu_entry() {
  local dir
  dir="$(dirname "$MENU_JSONC")"
  mkdir -p "$dir"

  # Nothing to merge into yet -- create the minimal valid JSONC object. (The
  # file Omarchy ships as an example is all comments plus an empty {}.)
  if [[ ! -f $MENU_JSONC ]]; then
    printf '{\n}\n' >"$MENU_JSONC"
    printf '==> created %s\n' "$MENU_JSONC"
  fi

  if grep -qF "$MENU_MARK_BEGIN" "$MENU_JSONC"; then
    printf 'menu entry already present in %s\n' "$MENU_JSONC"
    return 0
  fi

  # The row must land INSIDE the top-level object, so insert it before the
  # LAST "}" in the file rather than appending at EOF. Refuse rather than
  # guess if there is no closing brace to insert before -- appending after it
  # would produce a file the shell cannot parse, silently killing the user's
  # own menu extensions along with ours.
  if ! awk '{ l = $0
              sub(/\r$/, "", l); sub(/^\xef\xbb\xbf/, "", l)
              gsub(/^[ \t]+|[ \t]+$/, "", l)
              if (l == "{") { ok = 1; exit } }
            END { exit !ok }' "$MENU_JSONC"; then
    cat >&2 <<MSG
$MENU_JSONC has no line containing just the opening "{" -- it does not look
like the JSONC object this installer knows how to extend. Refusing to edit it.

Everything else was installed. To add the menu row by hand, put this line
inside the top-level object of that file:

$(menu_entry_line)

MSG
    return 0
  fi

  # Back up before touching a hand-edited, human-owned file -- same rule and
  # same nanosecond-resolution timestamp as the shell.json backup above.
  #
  # Declared and assigned separately (SC2155): `local x="$(cmd)"` takes the
  # exit status of `local`, which is always 0, so a failing date would be
  # swallowed and the backup would land on a truncated name.
  local backup
  backup="$MENU_JSONC.bak.$(date +%Y%m%d-%H%M%S-%N)"
  cp "$MENU_JSONC" "$backup"
  printf '==> backed up %s -> %s\n' "$MENU_JSONC" "$backup"

  # temp + mv, so a failure part-way through never leaves a truncated menu
  # file behind (an unparseable one costs the user their whole menu).
  # Same reason as TMP_JSON above: temp file in the DESTINATION directory, so
  # the mv is an atomic rename(2). A truncated omarchy-menu.jsonc costs the
  # user their whole menu.
  TMP_MENU="$(mktemp -p "$(dirname "$MENU_JSONC")" .omarchy-menu.jsonc.XXXXXX)"
  # Insert right AFTER the opening "{", not before the final "}".
  #
  # Inserting at the end looks natural and is wrong: the line would land after
  # the user's LAST entry, which -- being the last -- does not end in a comma.
  # The file becomes invalid JSON, and MenuModel.js does JSON.parse inside a
  # try/catch that returns an empty list: the user loses their OWN menu
  # entries, with no message at all, and ours does not show up either. There
  # were more traps on the same path: a "}" inside a string
  # ("action":"echo }"), an array closing at the end, a comment with a "}"
  # after the closing brace (the line would land OUTSIDE the root object).
  #
  # After the "{" none of these cases exist: our line already ends in a
  # comma, and a trailing comma before "}" is legal in JSONC -- Omarchy's own
  # stripJsonc removes it.
  awk -v blk="$(menu_entry_block)" '
    !ins { l = $0
           sub(/\r$/, "", l); sub(/^\xef\xbb\xbf/, "", l)
           gsub(/^[ \t]+|[ \t]+$/, "", l)
           if (l == "{") { print; print blk; ins = 1; next } }
    { print }
    END { if (!ins) exit 3 }
  ' "$MENU_JSONC" >"$TMP_MENU" || {
    rm -f "$TMP_MENU"; TMP_MENU=""
    printf 'refused: %s has no standalone opening "{" -- left untouched\n' \
      "$MENU_JSONC" >&2
    return 0
  }
  # Same finalizer the shell.json write uses: preserve the destination's mode
  # instead of inheriting mktemp's 0600, fsync the file, rename, fsync the
  # directory. A plain `mv` here used to narrow a user's 0644
  # omarchy-menu.jsonc to 0600 -- the identical defect finalize_shell_json was
  # written to fix, which this write simply never adopted.
  finalize_shell_json "$TMP_MENU" "$MENU_JSONC"
  TMP_MENU=""
  printf '==> added menu entry to %s\n' "$MENU_JSONC"
}

add_menu_entry

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'note: %s is not on your PATH\n' "$BIN_DIR" >&2 ;;
esac

if [[ $DRY_RUN == 1 ]]; then
  printf '\nDRY RUN complete. Nothing under ~/.config/omarchy or ~/.local/bin was changed.\n'
  printf 'Resulting shell.json would contain:\n'
  # cloneSourceRestores is projected too: it is now one of the three arrays
  # this installer writes, and a preview that hid it would hide the very field
  # that makes uninstall able to restore the native background.
  jq '{plugins, disabledPlugins, cloneSourceRestores}' "$SHELL_JSON"
  printf '\nResulting menu extension block:\n'
  if [[ -f $MENU_JSONC ]]; then
    sed -n "/$(printf '%s' "$MENU_MARK_BEGIN" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MENU_MARK_END" | sed 's/[][\.*^$/]/\\&/g')/p" "$MENU_JSONC"
  fi
else
  printf '\nInstalled. Restart omarchy-shell (or your session) to load the plugin.\n'
  printf 'The menu row appears under Style > Wallpaper per monitor (SUPER+SPACE);\n'
  printf 'the menu extension file is watched live, so that part needs no restart.\n'
fi
