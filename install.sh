#!/usr/bin/bash -p
# OPTIONAL AND MANUAL. Nothing runs this for you: Omarchy has no install hook,
# and `omarchy plugin remove` runs nothing either.
#
# Unlike a bar-widget plugin, this one is a "service" that REPLACES the native
# background (it disables omarchy.background in shell.json), so installing it
# does three things, in order:
#
#   1. Copies this repo into ~/.config/omarchy/plugins/vitorcanoas.background-per-monitor/
#      -- but only the files named in the WPM_PAYLOAD allowlist in
#      bin/wallpaper-monitor-common.sh (manifest.json, the QML, bin/, and the
#      docs a user may want to read in place). Anything not on that list is
#      NOT installed, including any file added to the repo later.
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

set -uo pipefail

# The user's login PATH, captured BEFORE the preamble pins PATH to
# /usr/bin:/bin. Read for exactly one purpose -- the advisory note at the end
# of this script about ~/.local/bin not being on PATH -- and never used to
# resolve a program. Without capturing it here that note would always fire,
# because the pinned PATH cannot contain a home directory by construction.
WPM_LOGIN_PATH="${PATH:-}"

# --- Closed-environment bootstrap ------------------------------------------
# Builtins only: finding the trustworthy tools is the very thing this is
# bootstrapping, so it cannot call one. See the header of
# bin/wallpaper-monitor-common.sh for what these four tests do and do not
# prove.
wpm_bootstrap() {
  local self=${BASH_SOURCE[1]} dir candidate
  dir=${self%/*}
  [[ $dir == "$self" ]] && dir=.
  dir=$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P) || dir=""
  local -a candidates=(
    "$dir/wallpaper-monitor-common.sh"
    "$dir/bin/wallpaper-monitor-common.sh"
    "$HOME/.config/omarchy/plugins/vitorcanoas.background-per-monitor/bin/wallpaper-monitor-common.sh"
  )
  for candidate in "${candidates[@]}"; do
    [[ -f $candidate && ! -L $candidate && -r $candidate && -O $candidate ]] || continue
    WPM_COMMON=$candidate
    return 0
  done
  printf 'wallpaper-monitor: shared preamble not found or not trustworthy\n' >&2
  exit 1
}
wpm_bootstrap
# shellcheck source=bin/wallpaper-monitor-common.sh
. "$WPM_COMMON"
# The preamble deliberately never sets errexit (bin/wp needs it off); this
# script has always run with it on.
set -e

# The repo root. The preamble re-derives WPM_BIN_DIR from its OWN BASH_SOURCE
# with `CDPATH='' cd -P` + `pwd -P`, which is what this line used to do by
# hand with neither the CDPATH reset nor -P.
HERE="${WPM_BIN_DIR%/*}"

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

# One no-follow `fstatat` answering the questions `[[ -e ]]`, `[[ -L ]]`,
# `[[ -f ]]` and `stat -c %a` used to answer by pathname. Every one of those
# tests resolved the whole path afresh -- including its parent chain -- so the
# thing tested was never provably the thing later written; the helper walks
# the chain component by component with O_NOFOLLOW and reports on the
# descriptor it ends up holding.
#
# Prints the value of KEY ("type", "mode", "dev", "ino", ...) for $2 below
# root $1, or nothing when the key is absent. A missing target yields
# type=absent and no other key, so `[[ -z $mode ]]` means "not there".
stat_key() {
  local out line rc=0
  out=$(wpm_cfg stat --root "$1" --rel "$2" --allow-missing 2>/dev/null) || rc=$?
  if (( rc == 4 )); then
    # --allow-missing covers a missing FINAL component; a missing parent
    # directory is reported as absent (exit 4) by the walk itself. Both mean
    # the same thing to every caller here: there is nothing at that path.
    out="type=absent"
  elif (( rc != 0 )); then
    # Re-run without the stderr redirection so the helper's own one-line
    # diagnosis (symlinked component, wrong owner, group-writable parent, ...)
    # is what the user sees before we give up.
    wpm_cfg stat --root "$1" --rel "$2" --allow-missing >/dev/null || true
    wpm_die "could not inspect $1/$2 safely"
  fi
  while IFS= read -r line; do
    if [[ $line == "$3="* ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done <<<"$out"
  return 0
}

# Backup suffix: the same <date>-<time>-<subsecond> shape the `date
# +%Y%m%d-%H%M%S-%N` calls produced, built from bash builtins so no ambient
# `date` is involved. The sub-second part is still what stops two runs in the
# same second from clobbering each other's backup of the ORIGINAL state; it is
# microseconds now rather than nanoseconds, which is finer than any two
# sequential runs of this script can be.
backup_stamp() {
  printf '%(%Y%m%d-%H%M%S)T-%s\n' -1 "${EPOCHREALTIME#*.}"
}

# Single cleanup trap for the whole script (the DRY_RUN staging dir) -- a
# second `trap ... EXIT` would silently replace this one rather than stack, so
# anything that needs cleanup on exit must be added to this same function
# instead of calling `trap` again.
#
# The transaction temp files this used to remove (TMP_JSON, TMP_MENU) are
# gone: every write now goes through the helper's `edit`, which stages inside
# the destination directory under an unpredictable 128-bit name on a held
# descriptor and unlinks it dirfd-relatively in its own `finally`. There is no
# longer a temp pathname for this script to know about, let alone clean up.
cleanup() {
  if [[ -n "${STAGE_REL:-}" ]]; then
    wpm_cfg prune-dir --root "$HOME" --rel "$STAGE_REL" --remove-all --if-exists \
      >/dev/null 2>&1 || true
  fi
  return 0
}
trap cleanup EXIT

# --- 0. Dependencies -------------------------------------------------------
#
# Moved ahead of the DRY_RUN staging below, which now needs the pinned tools
# itself. Resolving them first also means a machine missing one fails before
# anything has been created, rather than after.
#
# `command -v jq` and friends are gone. A probe answers a question about the
# PATH at probe time and the bare-name call forty lines later re-answers it;
# nothing made the two agree. wpm_require/wpm_optional resolve each tool ONCE
# from a fixed absolute candidate list, hand it to the helper's `check-tool`
# for the ownership/mode/parent-chain checks bash cannot do, and freeze it
# into a readonly variable that every call site below uses by name.
#
# python3 needs no check here: sourcing the preamble already resolved and
# validated it. It has always been a hard dependency of this script (the
# fsync steps of the old finalize_shell_json shelled out to it, and
# README.md lists it), but nothing checked for it, so a machine without
# python3 failed MID-INSTALL, after shell.json had been touched.
#
# rsync is no longer a dependency at all -- see step 1.
wpm_require AWK GREP
wpm_optional JQ OMARCHY OMARCHY_SHELL

if [[ -z $JQ ]]; then
  printf >&2 '%s\n' \
    "jq is required to edit shell.json safely and was not found." \
    "" \
    "    yay -S jq" \
    ""
  exit 1
fi

if [[ -z $OMARCHY ]]; then
  printf >&2 '%s\n' \
    "omarchy was not found at /usr/bin/omarchy or /usr/local/bin/omarchy." \
    "This installer registers a plugin in ~/.config/omarchy/shell.json for" \
    "Omarchy's Quickshell to load -- without Omarchy actually installed, that" \
    "file being created/edited would look like a successful install while" \
    "there is no shell around to ever load the plugin." \
    ""
  exit 1
fi

if [[ -z $OMARCHY_SHELL ]]; then
  printf >&2 '%s\n' \
    "Warning: omarchy-shell was not found at /usr/bin/omarchy-shell or" \
    "/usr/local/bin/omarchy-shell. Installing will proceed, but the running" \
    "shell will not pick up the new plugin until you restart it (or run" \
    "omarchy-shell yourself once it is available)." \
    ""
fi

# --- Where everything lives ------------------------------------------------
#
# Every filesystem operation below is expressed as a trusted ROOT plus a
# relative path under it, because that is what the helper takes: it opens the
# root once, validates it on the descriptor, then walks the relative path one
# component at a time with O_NOFOLLOW. DRY_RUN is therefore exactly the root
# substitution it always claimed to be -- $HOME for a real run, the staging
# directory for a dry one -- and the same code runs either way.
#
# The absolute PLUGIN_DIR/SHELL_JSON/BIN_DIR/MENU_JSONC variables survive
# because they are what the messages print and what the symlinks point at.
if [[ $DRY_RUN == 1 ]]; then
  wpm_require MKTEMP SED

  # The staging directory lives under $HOME rather than in /tmp. It has to:
  # the helper refuses to treat a directory it cannot validate as a trusted
  # root, and /tmp is mode 1777 and root-owned, so nothing rooted there can be
  # created or torn down through it. $HOME is the root this script already
  # keys everything else off.
  STAGE="$("$MKTEMP" -d -p "$HOME" .wallpaper-monitor-dryrun.XXXXXXXXXX)"
  STAGE_REL="${STAGE##*/}"

  ROOT="$STAGE"
  REL_PLUGIN_DIR="plugins/$PLUGIN_ID"
  REL_SHELL_JSON="shell.json"
  REL_BIN_DIR="local-bin"
  REL_MENU_JSONC="extensions/omarchy-menu.jsonc"

  PLUGIN_DIR="$STAGE/$REL_PLUGIN_DIR"
  SHELL_JSON="$STAGE/$REL_SHELL_JSON"
  MENU_JSONC="$STAGE/$REL_MENU_JSONC"

  wpm_cfg mkdir-chain --root "$ROOT" --rel plugins --mode 0755
  wpm_cfg mkdir-chain --root "$ROOT" --rel extensions --mode 0755
  # Unchanged from before this migration: BIN_DIR was still the REAL
  # ~/.local/bin at this point, so `mkdir -p "$(dirname "$BIN_DIR")"` created
  # the real ~/.local. Kept as it was rather than quietly changed.
  wpm_cfg mkdir-chain --root "$HOME" --rel .local --mode 0755
  BIN_DIR="$STAGE/$REL_BIN_DIR"

  # Seed a shell.json so the dry run has something realistic to show a diff
  # against, if a real one already exists; otherwise start from empty. The
  # real file's mode is carried across too, so the mode-preservation the real
  # run performs is visible in the staged one.
  seed_mode="$(stat_key "$HOME" ".config/omarchy/shell.json" mode)"
  if [[ -n $seed_mode ]]; then
    wpm_cfg install-file \
      --src-root "$HOME" --src-rel ".config/omarchy/shell.json" \
      --dst-root "$ROOT" --dst-rel "$REL_SHELL_JSON" \
      --mode "$seed_mode" --max-bytes "$WPM_MAX_CONFIG_BYTES"
  else
    wpm_cfg edit --root "$ROOT" --rel "$REL_SHELL_JSON" --mode 0600 -- "$JQ" -n '{}' \
      || wpm_die "could not create $SHELL_JSON"
  fi
  # Same for the menu extension file: seed the staging copy from the real one
  # (when it exists) so the dry run reports exactly what a real run would do
  # -- in particular whether our block is already present.
  seed_mode="$(stat_key "$HOME" ".config/omarchy/extensions/omarchy-menu.jsonc" mode)"
  if [[ -n $seed_mode ]]; then
    wpm_cfg install-file \
      --src-root "$HOME" --src-rel ".config/omarchy/extensions/omarchy-menu.jsonc" \
      --dst-root "$ROOT" --dst-rel "$REL_MENU_JSONC" \
      --mode "$seed_mode" --max-bytes "$WPM_MAX_CONFIG_BYTES"
  fi
  printf 'DRY RUN: no real files under ~/.config/omarchy or ~/.local/bin will be touched.\n'
  printf 'DRY RUN: staging in %s\n\n' "$STAGE"
else
  ROOT="$HOME"
  REL_PLUGIN_DIR=".config/omarchy/plugins/$PLUGIN_ID"
  REL_SHELL_JSON=".config/omarchy/shell.json"
  REL_BIN_DIR=".local/bin"
  REL_MENU_JSONC=".config/omarchy/extensions/omarchy-menu.jsonc"

  PLUGIN_DIR="$OMARCHY_CONFIG_DIR/plugins/$PLUGIN_ID"
  SHELL_JSON="$OMARCHY_CONFIG_DIR/shell.json"
fi

# PLUGIN_DIR is the symlink TARGET, and link_one below compares it against
# what `resolve-link` says an existing symlink points at. Those two strings
# have to be produced by the same code or the comparison is not a comparison:
# `resolve-link` answers with a LEXICALLY NORMALISED absolute path (its
# documented `realpath -m` contract), while the line above builds one by
# concatenating $HOME. A $HOME that is merely SPELLED differently -- a
# trailing slash, a doubled separator -- names the same directory but a
# different string, and then our own symlink reads as a foreign file:
# install refuses with "already exists and is not this plugin's symlink" on
# the second run, and uninstall leaves the link behind. Normalising here
# makes both sides come out of the helper's normaliser.
#
# `--rel .` is pure string work: the helper's normaliser is documented as
# doing no filesystem access at all, so it neither follows nor requires anything
# on disk, and it is emphatically NOT a `readlink -f` coming back in. It also
# cannot widen what the helper accepts as a --root, because PLUGIN_DIR is
# never used as one -- it is a message and a symlink target, nothing else.
PLUGIN_DIR="$(wpm_cfg resolve-link --root "$PLUGIN_DIR" --rel .)" \
  || wpm_die "could not normalise the plugin directory path"

# --- 1. Copy the plugin payload -------------------------------------------
#
# A copy rather than a symlink: omarchy-plugin-validate refuses symlinks
# inside a plugin directory, and a stray edit to the installed copy should
# not silently leak back into the git checkout (or vice versa).
printf '==> installing plugin files to %s\n' "$PLUGIN_DIR"

# `rsync -a --delete` is gone, and pinning its path would not have been
# enough: rsync re-resolves every pathname it is given inside a process we do
# not control, so no descriptor can be held across the validation and the
# copy. The scar below is that property showing up as a bug report -- a
# symlinked plugin directory whose target's unrelated files `--delete` erased,
# because `mkdir -p` is a silent no-op on a symlink-to-directory and rsync
# then followed it.
#
# The copy half is now one `install-file` per allowlist entry and the
# `--delete` half is one `prune-dir`, both descriptor-relative and both
# driven by the SAME list, so they cannot disagree about what belongs here.
# A symlink anywhere in the chain -- not merely at the final component, which
# is all the `[[ -L ]]` test below could ever see -- makes the openat fail
# with ELOOP and nothing is written.
#
# The test is kept because it produces a message a user can act on; it is no
# longer what makes the operation safe.
#
# Assigned first and tested afterwards, never `[[ "$(stat_key ...)" == x ]]`:
# a command substitution that fails INSIDE `[[ ]]` is invisible to errexit, so
# a boundary refusal would read as "absent" and the script would carry on. In
# an assignment the failure propagates and the run stops.
plugin_dir_type="$(stat_key "$ROOT" "$REL_PLUGIN_DIR" type)"
if [[ $plugin_dir_type == lnk ]]; then
  printf >&2 '%s\n' \
    "error: $PLUGIN_DIR is a symlink." \
    "Refusing to install: the plugin directory must be a real directory," \
    "not a link into somebody else's tree." \
    "Remove or move the symlink aside, then run this installer again."
  exit 1
fi

# ALLOWLIST, not a list of exclusions -- now WPM_PAYLOAD in
# bin/wallpaper-monitor-common.sh, shared with the prune below so the two
# cannot drift apart, and carrying each file's mode so the executable bit
# travels with the entry instead of a separate `chmod +x` that can go stale.
# The payload is exactly the files the plugin needs at runtime, and anything
# new in the repo is NOT installed unless it is named there.
#
# This used to be a deny-list, which shipped whatever nobody had thought to
# exclude. That is how a maintainer-only file that has no business on an
# installed plugin ended up written into the user's plugin directory. A
# deny-list cannot fix the class of bug -- the next such file ships the same
# way, by omission.
# An allowlist fails closed instead: a new file is left out until someone
# adds it deliberately. It fails closed in the other direction too -- a file
# named in the list but missing from the repo aborts the install loudly
# rather than being skipped into a half-installed plugin.
#
# The destination directories are created here at 0755 rather than left to
# install-file, which would create a missing parent at 0700: `mkdir -p` under
# the default umask and `rsync -a` copying the repo's own bin/ both produced
# 0755, and a plugin directory the shell has to read is not the place to
# silently narrow a mode.
wpm_cfg mkdir-chain --root "$ROOT" --rel "$REL_PLUGIN_DIR" --mode 0755
declare -A payload_dirs=()
for entry in "${WPM_PAYLOAD[@]}"; do
  payload_rel="${entry%:*}"
  if [[ $payload_rel == */* ]]; then
    payload_dirs["${payload_rel%/*}"]=1
  fi
done
for payload_dir in "${!payload_dirs[@]}"; do
  wpm_cfg mkdir-chain --root "$ROOT" --rel "$REL_PLUGIN_DIR/$payload_dir" --mode 0755
done

# The allowlist fails closed in both directions: nothing outside WPM_PAYLOAD
# is ever installed, and a payload file that is named but cannot be copied
# aborts the install loudly below rather than producing a half-installed
# plugin.
payload_keep=()
for entry in "${WPM_PAYLOAD[@]}"; do
  payload_rel="${entry%:*}"
  payload_mode="${entry##*:}"
  payload_keep+=(--keep "$payload_rel")
  wpm_cfg install-file \
    --src-root "$HERE" --src-rel "$payload_rel" \
    --dst-root "$ROOT" --dst-rel "$REL_PLUGIN_DIR/$payload_rel" \
    --mode "$payload_mode" \
    || wpm_die "could not install $payload_rel -- it is named in WPM_PAYLOAD but could not be copied from $HERE"
done

# The `--delete` half of the old rsync: everything in the installed plugin
# directory that the allowlist does not name goes, so an upgrade that drops a
# file does not leave it behind.
wpm_cfg prune-dir --root "$ROOT" --rel "$REL_PLUGIN_DIR" "${payload_keep[@]}" >/dev/null \
  || wpm_die "could not remove stale files from $PLUGIN_DIR"

# --- 1b. Pre-flight check that all symlinks CAN be created -----------------
#
# Deliberately done before touching shell.json (step 2&3 below). shell.json
# edits and symlink creation are not one atomic transaction, and the shell.json
# edit has no rollback -- so if a later link_one call died (e.g. an
# unrelated ~/.local/bin/wp from another tool), the user would be left with
# shell.json already pointing at this plugin and the native background
# already disabled, but the CLI not actually reachable, with an error message
# that never mentions shell.json was touched. Running a side-effect-free dry
# pass over all 3 links first means the real work in step 4 either succeeds
# for all of them or step 2&3 never runs at all.
#
# This pass and link_one below are what the shell.json transaction sits
# between, which used to make it the widest validate-then-reuse window in the
# repo: `[[ -e ]]`/`[[ -L ]]` here, `ln -s` two hundred lines later, both by
# pathname. It is still a pre-flight -- its job is the error message -- but
# the creation itself now goes through `symlink`, which resolves the parent
# directory descriptor-relatively at the moment it acts.
check_link_one() {
  local name=$1
  local target="$PLUGIN_DIR/bin/$name"
  local link="$BIN_DIR/$name"
  local kind
  kind="$(stat_key "$ROOT" "$REL_BIN_DIR/$name" type)"

  if [[ $kind != absent ]]; then
    # Our own symlink (live or dangling) is fine -- link_one in step 4 will
    # either skip it (already correct) or report it.
    if [[ $kind == lnk ]]; then
      return 0
    fi

    printf >&2 '%s\n' \
      "$link already exists and is not this plugin's symlink." \
      "" \
      "Refusing to install. Nothing has been changed yet -- shell.json and the" \
      "plugin's other symlinks are untouched. Move $link aside first, or skip the" \
      "symlink step and call the plugin's bin/ directly:" \
      "" \
      "    $target" \
      ""
    exit 1
  fi
}

wpm_cfg mkdir-chain --root "$ROOT" --rel "$REL_BIN_DIR" --mode 0755
check_link_one wallpaper-monitor
check_link_one wp
check_link_one wallpaper-monitor-menu

# --- 2 & 3. Register the plugin and disable the native one ----------------
#
# finalize_shell_json() is gone, and so is the mktemp/jq/mv dance around it.
# It refused a symlinked destination, read the destination's mode with `stat`,
# chmod'ed the temp, renamed, and then fsynced the directory -- five separate
# resolutions of the same pathname, with the jq run in the middle of them, and
# a `mktemp -p ... .shell.json.XXXXXX` temp name whose six random characters
# and fixed prefix were the predictable staging name the review blocked.
#
# All of it is now one `edit` transaction: the helper opens the parent
# directory by walking it component by component with O_NOFOLLOW, holds THAT
# descriptor for the whole operation, snapshots the target on its own
# descriptor, runs the jq program below as a pure stdin->stdout filter,
# stages the result under an unpredictable 128-bit name in the same
# directory, re-checks that the target is still byte-for-byte the object it
# snapshotted, and only then renames through the descriptor it has held all
# along. The destination's existing mode is preserved from that validated
# descriptor rather than from a pathname `stat` (which reports 0777 for a
# symlink and would have stamped it onto the real file); a group- or
# other-writable destination is refused outright instead of having its mode
# copied forward.

# Back up shell.json before touching it -- it is hand-edited, human-owned
# config, not something regenerated on demand.
shell_json_type="$(stat_key "$ROOT" "$REL_SHELL_JSON" type)"
if [[ $shell_json_type != absent ]]; then
  # Sub-second resolution rather than whole seconds: two installs run
  # back-to-back (e.g. testing idempotency, or a script driving this) can land
  # in the same second, and second-resolution backups would then silently
  # clobber each other -- losing the backup of the ORIGINAL state.
  BACKUP_SUFFIX=".bak.$(backup_stamp)"
  BACKUP="$SHELL_JSON$BACKUP_SUFFIX"
  shell_json_mode="$(stat_key "$ROOT" "$REL_SHELL_JSON" mode)"
  wpm_cfg install-file \
    --src-root "$ROOT" --src-rel "$REL_SHELL_JSON" \
    --dst-root "$ROOT" --dst-rel "$REL_SHELL_JSON$BACKUP_SUFFIX" \
    --mode "$shell_json_mode" \
    --max-bytes "$WPM_MAX_CONFIG_BYTES" \
    || wpm_die "could not back up $SHELL_JSON; if it is group- or other-writable, chmod go-w it first"
  printf '==> backed up %s -> %s\n' "$SHELL_JSON" "$BACKUP"
else
  # A shell.json this installer creates itself is 0600, which is what
  # finalize_shell_json always said it would be. An existing one keeps its own
  # mode, whatever it is.
  wpm_cfg edit --root "$ROOT" --rel "$REL_SHELL_JSON" --mode 0600 -- "$JQ" -n '{}' \
      || wpm_die "could not create $SHELL_JSON"
fi

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
#
# The jq program is byte-identical to the one that used to read $SHELL_JSON by
# name and redirect into a temp file; it is now handed the file's contents on
# stdin by the transaction above and its stdout is the new contents.
# shellcheck disable=SC2016  # jq/awk program text -- the single quotes are
# what keep $plugin / $0 as the filter's own variables, not the shell's.
wpm_cfg edit --root "$ROOT" --rel "$REL_SHELL_JSON" --mode 0600 \
  --max-bytes "$WPM_MAX_CONFIG_BYTES" -- \
  "$JQ" \
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
  || wpm_die "could not update $SHELL_JSON; if it is group- or other-writable, chmod go-w it first"
printf '==> registered %s and disabled %s in %s\n' "$PLUGIN_ID" "$NATIVE_PLUGIN_ID" "$SHELL_JSON"

# --- 4. Symlink the CLIs into ~/.local/bin ---------------------------------
# BIN_DIR was already created during the pre-flight check above; the check
# already ruled out any foreign (non-symlink) file at each of these paths,
# so the only things link_one can still find here are: nothing, our own live
# symlink, or our own dangling symlink -- all handled below.
link_one() {
  local name=$1
  local target="$PLUGIN_DIR/bin/$name"
  local rel_link="$REL_BIN_DIR/$name"
  local link="$BIN_DIR/$name"
  local kind resolved rc

  kind="$(stat_key "$ROOT" "$rel_link" type)"
  if [[ $kind != absent ]]; then
    # `readlink -f` is replaced by `resolve-link`, which re-anchors and
    # re-validates the parent chain at every hop instead of handing the whole
    # pathname to the kernel once. --require-regular is what tells a live
    # link from a dangling one: a dangling chain comes back as exit 4.
    #
    # The comparison below is string equality, and it is only sound because
    # BOTH sides come out of the helper's normaliser: $resolved by definition,
    # $target because PLUGIN_DIR was normalised where it is assigned. Compare
    # a normalised answer against a hand-concatenated path and an install of
    # our own symlink starts refusing itself (see the note there).
    rc=0
    resolved="$(wpm_cfg resolve-link --root "$ROOT" --rel "$rel_link" \
                  --max-hops 4 --require-regular 2>/dev/null)" || rc=$?

    if [[ $rc == 0 ]]; then
      if [[ $kind == lnk && $resolved == "$target" ]]; then
        printf 'already linked: %s\n' "$link"
        return 0
      fi
    elif [[ $rc == 4 && $kind == lnk ]]; then
      # A dangling symlink of our own name is almost always this installer's
      # earlier work, from a plugin folder that has since moved or been
      # reinstalled. Treated as a foreign file, it would refuse to replace a
      # dead link nothing else can repair. Say what it is and offer the fix.
      resolved="$(wpm_cfg resolve-link --root "$ROOT" --rel "$rel_link" --max-hops 4)" \
        || resolved="(could not be resolved safely)"
      printf >&2 '%s\n' \
        "$link is a broken symlink, pointing at:" \
        "" \
        "    $resolved" \
        "" \
        "That target no longer exists. Clear it before installing again:" \
        "" \
        "    rm -f \"$link\" && \"$HERE/install.sh\"" \
        ""
      exit 1
    fi

    printf >&2 '%s\n' \
      "$link already exists and is not this plugin's symlink." \
      "" \
      "Refusing to replace it. Move it aside first, or skip the symlink step and" \
      "call the plugin's bin/ directly:" \
      "" \
      "    $target" \
      ""
    exit 1
  fi

  wpm_cfg symlink --root "$ROOT" --rel "$rel_link" --target "$target" \
    || wpm_die "could not create the symlink $link"
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
# markers, leaving every other byte exactly as it was. That is still true
# here: the awk program below is handed the file's bytes on stdin and its
# stdout becomes the file's new bytes.
#
# Idempotent: a run that finds the markers already present changes nothing.
# Reversible: uninstall.sh cuts the same marker block back out.
add_menu_entry() {
  local menu_text menu_type menu_mode
  wpm_cfg mkdir-chain --root "$ROOT" --rel "${REL_MENU_JSONC%/*}" --mode 0755

  # Nothing to merge into yet -- create the minimal valid JSONC object. (The
  # file Omarchy ships as an example is all comments plus an empty {}.) 0644
  # is the mode the shell redirection that used to do this produced under the
  # default umask, and this file outlives the plugin, so it keeps it.
  menu_type="$(stat_key "$ROOT" "$REL_MENU_JSONC" type)"
  if [[ $menu_type == absent ]]; then
    wpm_cfg edit --root "$ROOT" --rel "$REL_MENU_JSONC" --mode 0644 -- \
      "$AWK" 'BEGIN { printf "{\n}\n" }' \
      || wpm_die "could not create $MENU_JSONC"
    printf '==> created %s\n' "$MENU_JSONC"
  fi

  # One bounded, no-follow read feeds every test below, instead of grep, awk
  # and sed each opening the pathname again. The file is refused here on the
  # same terms the edit would refuse it (symlink, not a regular file, not
  # ours, group/other-writable, over budget), so a file we cannot safely edit
  # is never even inspected.
  menu_text="$(wpm_cfg read --root "$ROOT" --rel "$REL_MENU_JSONC" \
                 --max-bytes "$WPM_MAX_CONFIG_BYTES")" \
    || wpm_die "could not read $MENU_JSONC safely"

  if "$GREP" -qF -- "$MENU_MARK_BEGIN" <<<"$menu_text"; then
    printf 'menu entry already present in %s\n' "$MENU_JSONC"
    return 0
  fi

  # The row must land INSIDE the top-level object, so insert it before the
  # LAST "}" in the file rather than appending at EOF. Refuse rather than
  # guess if there is no closing brace to insert before -- appending after it
  # would produce a file the shell cannot parse, silently killing the user's
  # own menu extensions along with ours.
  # shellcheck disable=SC2016  # jq/awk program text -- the single quotes are
  # what keep $plugin / $0 as the filter's own variables, not the shell's.
  if ! "$AWK" '{ l = $0
              sub(/\r$/, "", l); sub(/^\xef\xbb\xbf/, "", l)
              gsub(/^[ \t]+|[ \t]+$/, "", l)
              if (l == "{") { ok = 1; exit } }
            END { exit !ok }' <<<"$menu_text"; then
    printf >&2 '%s\n' \
      "$MENU_JSONC has no line containing just the opening \"{\" -- it does not look" \
      "like the JSONC object this installer knows how to extend. Refusing to edit it." \
      "" \
      "Everything else was installed. To add the menu row by hand, put this line" \
      "inside the top-level object of that file:" \
      "" \
      "$(menu_entry_line)" \
      ""
    return 0
  fi

  # Back up before touching a hand-edited, human-owned file -- same rule and
  # same sub-second timestamp as the shell.json backup above. The backup is a
  # descriptor-relative copy now rather than a `cp` that followed symlinks
  # onto a predictable path, and it carries the source's own validated mode.
  local backup_suffix backup
  backup_suffix=".bak.$(backup_stamp)"
  backup="$MENU_JSONC$backup_suffix"
  menu_mode="$(stat_key "$ROOT" "$REL_MENU_JSONC" mode)"
  wpm_cfg install-file \
    --src-root "$ROOT" --src-rel "$REL_MENU_JSONC" \
    --dst-root "$ROOT" --dst-rel "$REL_MENU_JSONC$backup_suffix" \
    --mode "$menu_mode" \
    --max-bytes "$WPM_MAX_CONFIG_BYTES" \
    || wpm_die "could not back up $MENU_JSONC; if it is group- or other-writable, chmod go-w it first"
  printf '==> backed up %s -> %s\n' "$MENU_JSONC" "$backup"

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
  #
  # The awk program is byte-identical to the one that used to read the file by
  # name and redirect into a mktemp'ed temp file. It is a pure stdin->stdout
  # filter inside the same transaction the shell.json write uses: the
  # destination's mode is preserved from its own validated descriptor, the
  # staged copy has an unpredictable name, the target is re-checked
  # immediately before the rename, and the rename and both fsyncs go through
  # the one directory descriptor held throughout. awk exiting 3 (no standalone
  # "{" after all) aborts the transaction before anything is written.
  local rc=0
  # shellcheck disable=SC2016  # jq/awk program text -- the single quotes are
  # what keep $plugin / $0 as the filter's own variables, not the shell's.
  wpm_cfg edit --root "$ROOT" --rel "$REL_MENU_JSONC" \
         --max-bytes "$WPM_MAX_CONFIG_BYTES" -- \
         "$AWK" -v blk="$(menu_entry_block)" '
    !ins { l = $0
           sub(/\r$/, "", l); sub(/^\xef\xbb\xbf/, "", l)
           gsub(/^[ \t]+|[ \t]+$/, "", l)
           if (l == "{") { print; print blk; ins = 1; next } }
    { print }
    END { if (!ins) exit 3 }
  ' || rc=$?
  # Exit 3 is the helper's "the filter exited non-zero" -- i.e. awk's exit 3
  # above, the no-standalone-"{" case this branch has always reported and
  # survived. Anything else is a boundary refusal (symlink, wrong owner,
  # group/other-writable, over budget) and must not be reported as a parse
  # problem, so it stays fatal. Nothing was written either way.
  if (( rc == 3 )); then
    printf 'refused: %s has no standalone opening "{" -- left untouched\n' \
      "$MENU_JSONC" >&2
    return 0
  elif (( rc != 0 )); then
    wpm_die "could not update $MENU_JSONC; if it is group- or other-writable, chmod go-w it first"
  fi
  printf '==> added menu entry to %s\n' "$MENU_JSONC"
}

add_menu_entry

case ":$WPM_LOGIN_PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'note: %s is not on your PATH\n' "$BIN_DIR" >&2 ;;
esac

if [[ $DRY_RUN == 1 ]]; then
  printf '\nDRY RUN complete. Nothing under ~/.config/omarchy or ~/.local/bin was changed.\n'
  printf 'Resulting shell.json would contain:\n'
  # cloneSourceRestores is projected too: it is now one of the three arrays
  # this installer writes, and a preview that hid it would hide the very field
  # that makes uninstall able to restore the native background.
  "$JQ" '{plugins, disabledPlugins, cloneSourceRestores}' \
    <<<"$(wpm_cfg read --root "$ROOT" --rel "$REL_SHELL_JSON" --max-bytes "$WPM_MAX_CONFIG_BYTES")"
  printf '\nResulting menu extension block:\n'
  menu_preview="$(wpm_cfg read --root "$ROOT" --rel "$REL_MENU_JSONC" \
                    --max-bytes "$WPM_MAX_CONFIG_BYTES" --allow-missing)"
  if [[ -n $menu_preview ]]; then
    "$SED" -n "/$(printf '%s' "$MENU_MARK_BEGIN" | "$SED" 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$MENU_MARK_END" | "$SED" 's/[][\.*^$/]/\\&/g')/p" <<<"$menu_preview"
  fi
else
  printf '\nInstalled. Restart omarchy-shell (or your session) to load the plugin.\n'
  printf 'The menu row appears under Style > Wallpaper per monitor (SUPER+SPACE);\n'
  printf 'the menu extension file is watched live, so that part needs no restart.\n'
fi
