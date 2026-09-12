#!/usr/bin/bash
# OPTIONAL AND MANUAL. Nothing runs this for you: Omarchy has no uninstall
# hook, and `omarchy plugin remove` runs nothing either.
#
# Reverses exactly what install.sh does, in reverse order:
#
#   0. Removes the "Wallpaper per monitor" row from the SUPER+SPACE menu, by
#      cutting the marker-delimited block install.sh appended to
#      ~/.config/omarchy/extensions/omarchy-menu.jsonc. Only that block is
#      touched; the rest of the file (the user's own rows and comments) is
#      preserved byte for byte, and a backup is made first.
#   1. Removes wallpaper-monitor, wp and wallpaper-monitor-menu from
#      ~/.local/bin -- but ONLY if each is a symlink pointing at THIS
#      plugin's installed bin/ directory. A file or a symlink to something
#      else is left alone (it is not ours to remove).
#   2. Removes "vitorcanoas.background-per-monitor" from plugins[] and from
#      cloneSourceRestores[] in ~/.config/omarchy/shell.json, and removes
#      "omarchy.background" from disabledPlugins[] -- that last step ONLY if
#      cloneSourceRestores[] names our plugin. That array is Omarchy's own
#      record of WHICH clone is responsible for its source being disabled
#      (PluginRegistry.qml: cloneShouldRestoreSource / restoreCloneSource),
#      and install.sh writes our id into it because manifest.json declares
#      omarchy.clonedFrom. So this is no longer a heuristic: with our claim
#      present the native background IS restored; without it we genuinely
#      did not do the disabling and disabledPlugins[] is left untouched,
#      and the script says so.
#   3. Removes ~/.config/omarchy/plugins/vitorcanoas.background-per-monitor/.
#
# It does NOT remove ~/.config/omarchy/background-per-monitor.json (the
# per-monitor override file managed by `wallpaper-monitor`/`wp`) -- that is
# the user's own config, not something this installer created on its
# behalf. If it exists, this script only prints where it is.
#
# It also does NOT remove ~/.config/omarchy/shell.json.bak.* backups left by
# install.sh -- see install.sh's header for why, and how to clean those up.
#
# DRY_RUN=1 ./uninstall.sh prints every step above without touching the real
# shell.json or the real plugin/symlink files -- same staging-based sandbox
# install.sh's DRY_RUN uses:
#
#     DRY_RUN=1 ./uninstall.sh

set -uo pipefail

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

PLUGIN_ID="vitorcanoas.background-per-monitor"
NATIVE_PLUGIN_ID="omarchy.background"

DRY_RUN="${DRY_RUN:-0}"
case "$DRY_RUN" in
  0|1) ;;
  *)
    printf 'DRY_RUN must be 0 or 1 (got %q). Refusing to guess -- e.g. "true" is\nnot 1 and would otherwise silently run a REAL uninstall.\n' "$DRY_RUN" >&2
    exit 1
    ;;
esac

## Same rationale as install.sh: "$HOME" explicit, never XDG_CONFIG_HOME --
## Omarchy's own migrations resolve shell.json the same way, and this keeps
## `HOME=/fake/home bash uninstall.sh` fully sandboxed for testing.
OMARCHY_CONFIG_DIR="$HOME/.config/omarchy"
BIN_DIR="$HOME/.local/bin"
OVERRIDE_JSON="$OMARCHY_CONFIG_DIR/background-per-monitor.json"
MENU_JSONC="$OMARCHY_CONFIG_DIR/extensions/omarchy-menu.jsonc"

# Must match install.sh exactly -- these delimit the block we appended.
MENU_MARK_BEGIN="// >>> $PLUGIN_ID (managed by install.sh -- do not edit inside)"
MENU_MARK_END="// <<< $PLUGIN_ID"

# Kept identical to install.sh's copy, for the same reason finalize_shell_json
# was: one reviewed behaviour rather than two that can drift.
#
# One no-follow `fstatat` answering the questions `[[ -e ]]`, `[[ -L ]]`,
# `[[ -f ]]`, `[[ -d ]]` and `stat -c %a` used to answer by pathname. Prints
# the value of KEY for $2 below root $1, or nothing when the key is absent; a
# missing target yields type=absent and no other key.
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

# Backup suffix: the same <date>-<time>-<subsecond> shape `date
# +%Y%m%d-%H%M%S-%N` produced, from bash builtins so no ambient `date` is
# involved.
backup_stamp() {
  printf '%(%Y%m%d-%H%M%S)T-%s\n' -1 "${EPOCHREALTIME#*.}"
}

# Single cleanup trap (the DRY_RUN staging dir). The transaction temp files
# this used to remove are gone: every write goes through the helper's `edit`,
# which stages under an unpredictable 128-bit name on a held directory
# descriptor and unlinks it dirfd-relatively in its own `finally`.
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
# Moved ahead of the DRY_RUN staging below, which needs the pinned tools
# itself. `command -v jq` is gone for the reason install.sh spells out: a
# probe answers a question about the PATH at probe time and the bare-name call
# later re-answers it. python3 is already resolved and validated by sourcing
# the preamble.
wpm_require AWK GREP
wpm_optional JQ

if [[ -z $JQ ]]; then
  printf >&2 '%s\n' \
    "jq is required to edit shell.json safely and was not found." \
    "" \
    "    yay -S jq" \
    ""
  exit 1
fi

# --- Where everything lives ------------------------------------------------
#
# As in install.sh: every filesystem operation is a trusted ROOT plus a
# relative path under it, and DRY_RUN is the root substitution it always
# claimed to be.
if [[ $DRY_RUN == 1 ]]; then
  wpm_require MKTEMP

  # Under $HOME, not /tmp: the helper refuses to treat a directory it cannot
  # validate as a trusted root, and /tmp is mode 1777 and root-owned, so
  # nothing rooted there could be created or torn down through it.
  STAGE="$("$MKTEMP" -d -p "$HOME" .wallpaper-monitor-dryrun.XXXXXXXXXX)"
  STAGE_REL="${STAGE##*/}"

  ROOT="$STAGE"
  REL_PLUGIN_DIR="plugins/$PLUGIN_ID"
  REL_SHELL_JSON="shell.json"
  REL_BIN_DIR="local-bin"
  REL_MENU_JSONC="extensions/omarchy-menu.jsonc"

  PLUGIN_DIR="$STAGE/$REL_PLUGIN_DIR"
  SHELL_JSON="$STAGE/$REL_SHELL_JSON"
  BIN_DIR="$STAGE/$REL_BIN_DIR"
  MENU_JSONC="$STAGE/$REL_MENU_JSONC"

  wpm_cfg mkdir-chain --root "$ROOT" --rel plugins --mode 0755
  wpm_cfg mkdir-chain --root "$ROOT" --rel "$REL_BIN_DIR" --mode 0755
  wpm_cfg mkdir-chain --root "$ROOT" --rel extensions --mode 0755

  # Mirror the real state into the staging dir so the dry run reflects what
  # a real uninstall would actually find and do.
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

  # The installed plugin directory is mirrored file by file from WPM_PAYLOAD
  # rather than with `cp -a`, which re-resolves every path by name inside a
  # process we do not control. An entry the installed copy does not have is
  # skipped: this is a preview of what a real uninstall would find, not the
  # fail-closed install path, and an older installed plugin legitimately
  # predates entries the current allowlist names. Files in the installed
  # directory that the allowlist does NOT name are not mirrored either; they
  # would be removed wholesale by step 3 regardless, so the dry run's output
  # is unaffected.
  REAL_PLUGIN_DIR_REL=".config/omarchy/plugins/$PLUGIN_ID"
  # Normalised for the same reason PLUGIN_DIR is below: the `case` further
  # down matches it against `resolve-link` output, which is always lexically
  # normalised. Left raw, a $HOME with a trailing slash or a doubled
  # separator makes every one of our own links look foreign, and the dry run
  # would preview "leaving it alone" for links a real uninstall removes.
  real_plugin_dir="$(wpm_cfg resolve-link \
    --root "$OMARCHY_CONFIG_DIR/plugins/$PLUGIN_ID" --rel .)" \
    || wpm_die "could not normalise the plugin directory path"
  # Assigned first and tested afterwards, never `[[ "$(stat_key ...)" == x ]]`:
  # a command substitution that fails INSIDE `[[ ]]` is invisible to errexit, so
  # a boundary refusal would read as "absent" and the script would carry on. In
  # an assignment the failure propagates and the run stops.
  real_plugin_dir_type="$(stat_key "$HOME" "$REAL_PLUGIN_DIR_REL" type)"
  if [[ $real_plugin_dir_type == dir ]]; then
    wpm_cfg mkdir-chain --root "$ROOT" --rel "$REL_PLUGIN_DIR" --mode 0755
    for entry in "${WPM_PAYLOAD[@]}"; do
      payload_rel="${entry%:*}"
      payload_mode="${entry##*:}"
      payload_src_type="$(stat_key "$HOME" "$REAL_PLUGIN_DIR_REL/$payload_rel" type)"
      if [[ $payload_src_type != reg ]]; then
        continue
      fi
      if [[ $payload_rel == */* ]]; then
        wpm_cfg mkdir-chain --root "$ROOT" \
          --rel "$REL_PLUGIN_DIR/${payload_rel%/*}" --mode 0755
      fi
      wpm_cfg install-file \
        --src-root "$HOME" --src-rel "$REAL_PLUGIN_DIR_REL/$payload_rel" \
        --dst-root "$ROOT" --dst-rel "$REL_PLUGIN_DIR/$payload_rel" \
        --mode "$payload_mode"
    done
  fi

  # Mirror the menu extension file too, so the dry run reports whether our
  # block is really there and what removing it would leave behind.
  seed_mode="$(stat_key "$HOME" ".config/omarchy/extensions/omarchy-menu.jsonc" mode)"
  if [[ -n $seed_mode ]]; then
    wpm_cfg install-file \
      --src-root "$HOME" --src-rel ".config/omarchy/extensions/omarchy-menu.jsonc" \
      --dst-root "$ROOT" --dst-rel "$REL_MENU_JSONC" \
      --mode "$seed_mode" --max-bytes "$WPM_MAX_CONFIG_BYTES"
  fi

  for name in wallpaper-monitor wp wallpaper-monitor-menu; do
    real_link_type="$(stat_key "$HOME" ".local/bin/$name" type)"
    if [[ $real_link_type != lnk ]]; then
      continue
    fi
    # `readlink -f` is replaced by `resolve-link`, which re-anchors and
    # re-validates the parent chain at every hop instead of handing the whole
    # pathname to the kernel once.
    real_target="$(wpm_cfg resolve-link --root "$HOME" --rel ".local/bin/$name" \
                     --max-hops 4)" || continue
    # Rewrite a target that points at the real plugin dir to point at the
    # STAGED plugin dir instead, so the dry run's "is this our symlink"
    # comparison (against the staged PLUGIN_DIR) matches the same way the
    # real uninstall's comparison (against the real PLUGIN_DIR) would.
    # A symlink pointing anywhere else is copied as-is, so it still shows
    # up as a foreign link the dry run correctly leaves alone.
    case "$real_target" in
      "$real_plugin_dir"/*)
        wpm_cfg symlink --root "$ROOT" --rel "$REL_BIN_DIR/$name" \
          --target "$PLUGIN_DIR/bin/$name"
        ;;
      *)
        wpm_cfg symlink --root "$ROOT" --rel "$REL_BIN_DIR/$name" \
          --target "$real_target"
        ;;
    esac
  done
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

# Same normalisation install.sh does where it assigns PLUGIN_DIR, and for the
# same reason: unlink_one below compares this string against what
# `resolve-link` reports a symlink points at, and `resolve-link` answers with
# a LEXICALLY NORMALISED absolute path while the line above builds one by
# concatenating $HOME. A $HOME spelled with a trailing slash or a doubled
# separator names the same directory but a different string, and then our own
# symlink fails to match -- uninstall would print "is not this plugin's
# symlink", exit 0, and LEAVE THE LINK BEHIND, now dangling, after step 3 has
# removed the plugin directory it points into. Both sides must come out of
# the same normaliser.
#
# `--rel .` is pure string work (the helper's normaliser does no filesystem
# access at all), so it is not a `readlink -f` in disguise: nothing is followed and
# nothing has to exist -- which matters here, because unlink_one deliberately
# still matches a DANGLING link whose target is already gone.
PLUGIN_DIR="$(wpm_cfg resolve-link --root "$PLUGIN_DIR" --rel .)" \
  || wpm_die "could not normalise the plugin directory path"

# --- 0. Remove our row from the SUPER+SPACE menu ---------------------------
#
# Cuts exactly the marker-delimited block install.sh appended to the user's
# JSONC menu extension, and nothing else. The file is edited as TEXT for the
# same reason install.sh writes it as text: it is JSONC (comments, trailing
# commas), so parsing it as JSON would either fail or silently rewrite the
# user's file with all their comments stripped.
#
# Nothing found -> nothing done, and we say so (idempotent: a second run is a
# no-op, not an error).
#
# finalize_shell_json() is gone from this file too. It was a byte-for-byte
# twin of install.sh's, and carried the same four defects four times over: a
# `[[ -L ]]` test, a `stat -c %a`, a `chmod` and an `mv`, each resolving the
# destination pathname again, with the directory fsynced by pathname
# afterwards -- so it could fsync a different directory than the one the
# rename landed in. The helper's `edit` does the whole transaction on one
# directory descriptor it never re-derives, and revalidates the target
# immediately before publishing.
remove_menu_entry() {
  local menu_text menu_type menu_mode backup_suffix backup

  menu_type="$(stat_key "$ROOT" "$REL_MENU_JSONC" type)"
  if [[ $menu_type == absent ]]; then
    printf 'not present, skipping: %s\n' "$MENU_JSONC"
    return 0
  fi

  # One bounded, no-follow read feeds both marker tests, instead of two greps
  # each opening the pathname again. The file is refused here on the same
  # terms the edit below would refuse it.
  menu_text="$(wpm_cfg read --root "$ROOT" --rel "$REL_MENU_JSONC" \
                 --max-bytes "$WPM_MAX_CONFIG_BYTES")" \
    || wpm_die "could not read $MENU_JSONC safely"

  if ! "$GREP" -qF -- "$MENU_MARK_BEGIN" <<<"$menu_text"; then
    printf 'no menu entry of ours in %s -- nothing to remove.\n' "$MENU_JSONC"
    return 0
  fi

  # If the closing marker is missing, the block has been hand-edited and we
  # cannot tell where it ends. Deleting from the opening marker to EOF would
  # eat the user's own rows below it, so refuse and let them look.
  if ! "$GREP" -qF -- "$MENU_MARK_END" <<<"$menu_text"; then
    printf >&2 '%s\n' \
      "$MENU_JSONC contains our opening marker but not the closing one:" \
      "" \
      "    $MENU_MARK_END" \
      "" \
      "The block has been edited by hand and its end cannot be determined safely." \
      "Leaving the file alone -- remove the row for" \
      "\"style.wallpaper-per-monitor\" yourself." \
      ""
    return 0
  fi

  # Back up before touching a hand-edited, human-owned file. A
  # descriptor-relative copy now rather than a `cp` that followed symlinks
  # onto a predictable path, carrying the source's own validated mode.
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

  # awk with fixed-string comparison (index/==), never a regex: the markers
  # contain "/" and "." and ">", which in a regex would match more than the
  # literal marker line. The program is byte-identical to the one that used to
  # read the file by name and redirect into a mktemp'ed temp file; it is now a
  # pure stdin->stdout filter inside the transaction, which preserves the
  # destination's mode from its own validated descriptor -- the mode matters
  # more here than anywhere else, because this file is what the user is left
  # with AFTER the plugin is gone, so a wrong one would outlive the uninstall.
  # shellcheck disable=SC2016  # jq/awk program text -- the single quotes are
  # what keep $plugin / $0 as the filter's own variables, not the shell's.
  wpm_cfg edit --root "$ROOT" --rel "$REL_MENU_JSONC" \
    --max-bytes "$WPM_MAX_CONFIG_BYTES" -- \
    "$AWK" -v b="$MENU_MARK_BEGIN" -v e="$MENU_MARK_END" '
    index($0, b) { skip = 1; next }
    skip && index($0, e) { skip = 0; next }
    !skip { print }
  ' || wpm_die "could not update $MENU_JSONC; if it is group- or other-writable, chmod go-w it first"
  printf '==> removed menu entry from %s\n' "$MENU_JSONC"
}

remove_menu_entry

# --- 1. Remove the symlinks from ~/.local/bin, but only our own -----------
#
# "Our own" means: a symlink whose resolved target lives inside THIS
# plugin's installed bin/ directory. Anything else (a real file, a symlink
# to some other tool) is left alone -- it is not ours to remove, the same
# way install.sh refuses to overwrite a foreign file at that path.
unlink_one() {
  local name=$1
  local rel_link="$REL_BIN_DIR/$name"
  local link="$BIN_DIR/$name"
  local expected_target="$PLUGIN_DIR/bin/$name"
  local kind resolved dev ino

  kind="$(stat_key "$ROOT" "$rel_link" type)"
  if [[ $kind == absent ]]; then
    printf 'not present, skipping: %s\n' "$link"
    return 0
  fi

  if [[ $kind == lnk ]]; then
    # resolve-link on a dangling symlink still reports the (non-existent)
    # target path, which is exactly what we want to compare here -- the same
    # property `readlink -f` had, minus handing the whole pathname to the
    # kernel in one go.
    #
    # The equality below is sound only because BOTH sides are normalised by
    # the same code: $resolved by definition, $expected_target because
    # PLUGIN_DIR was normalised where it is assigned. A raw, concatenated
    # expected path is how this stops removing our own symlinks.
    resolved="$(wpm_cfg resolve-link --root "$ROOT" --rel "$rel_link" --max-hops 4)" \
      || resolved=""
    if [[ -n $resolved && $resolved == "$expected_target" ]]; then
      # --expect-dev-ino closes the check-then-act: the identity `stat`
      # reported above is handed back, and the unlink refuses if the object at
      # that name is no longer the one we inspected. --if-exists keeps a
      # second run a no-op rather than an error.
      dev="$(stat_key "$ROOT" "$rel_link" dev)"
      ino="$(stat_key "$ROOT" "$rel_link" ino)"
      wpm_cfg unlink --root "$ROOT" --rel "$rel_link" --if-exists \
        --expect-dev-ino "$dev:$ino" >/dev/null \
        || wpm_die "could not remove the symlink $link"
      printf 'removed symlink: %s\n' "$link"
      return 0
    fi
  fi

  printf '%s exists but is not this plugin'"'"'s symlink -- leaving it alone.\n' "$link" >&2
}

unlink_one wallpaper-monitor
unlink_one wp
unlink_one wallpaper-monitor-menu

# --- 2. Unregister the plugin and (conditionally) restore the native one --
#
# One `edit` transaction, as in install.sh: the parent directory is walked
# component by component with O_NOFOLLOW and its descriptor held throughout,
# the target is snapshotted on its own descriptor, the jq program runs as a
# pure stdin->stdout filter, the result is staged under an unpredictable
# 128-bit name in the same directory, the target is re-checked byte for byte
# immediately before the rename, and the rename and both fsyncs go through
# that one held descriptor. The destination's existing mode is preserved from
# the validated descriptor rather than from a pathname `stat`; a group- or
# other-writable destination is refused outright.
#
# Assigned first and tested afterwards, never `[[ "$(stat_key ...)" == x ]]`:
# a command substitution that fails INSIDE `[[ ]]` is invisible to errexit, so
# a boundary refusal would read as "absent" and the script would carry on. In
# an assignment the failure propagates and the run stops.
shell_json_type="$(stat_key "$ROOT" "$REL_SHELL_JSON" type)"
if [[ $shell_json_type != absent ]]; then
  # One bounded, no-follow read feeds both jq queries and the edit's own
  # snapshot, instead of four separate pathname opens of the same file inside
  # one logical transaction.
  shell_json_text="$(wpm_cfg read --root "$ROOT" --rel "$REL_SHELL_JSON" \
                       --max-bytes "$WPM_MAX_CONFIG_BYTES")" \
    || wpm_die "could not read $SHELL_JSON safely"

  # Ownership of the disable comes from cloneSourceRestores[], not from
  # plugins[]. This is Omarchy's own mechanism (PluginRegistry.qml:
  # cloneShouldRestoreSource / restoreCloneSource), unlocked by declaring
  # `omarchy.clonedFrom` in manifest.json: our id sits in that array exactly
  # when we are the plugin responsible for omarchy.background being disabled.
  #
  # Before this, the test was "is our id in plugins[]", which answers a
  # different question -- whether we are installed, not whether we did the
  # disabling. That is why the old uninstall had to give up and leave the
  # native background disabled.
  #
  # Checked either way, because the two can disagree: a user who ran
  # `omarchy plugin disable` before uninstalling has already had the shell
  # remove our plugins[] entry AND restore the native, leaving our id out of
  # cloneSourceRestores[]. In that case there is correctly nothing to do.
  # shellcheck disable=SC2016  # jq/awk program text -- the single quotes are
  # what keep $plugin / $0 as the filter's own variables, not the shell's.
  owns_disable="$("$JQ" --arg plugin "$PLUGIN_ID" \
    '((.cloneSourceRestores // []) | index($plugin)) != null' <<<"$shell_json_text")"
  # shellcheck disable=SC2016  # jq/awk program text -- the single quotes are
  # what keep $plugin / $0 as the filter's own variables, not the shell's.
  is_registered="$("$JQ" --arg plugin "$PLUGIN_ID" '(.plugins // []) | any(.id == $plugin)' <<<"$shell_json_text")"

  if [[ $owns_disable == "true" || $is_registered == "true" ]]; then
    # Same backup-before-writing discipline as install.sh, and the same
    # sub-second timestamp to avoid same-second collisions.
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

    # Mirrors PluginRegistry.restoreCloneSource(): drop our plugins[] entry,
    # drop our claim from cloneSourceRestores[], and re-enable the source --
    # that last step ONLY if the claim was ours ($owns_disable). Both arrays
    # are deleted when they end up empty, which is what
    # setCloneShouldRestoreSource/removeDisabled do, so the file stays
    # identical to one the shell would have produced.
    #
    # The jq program is byte-identical to the one that used to read
    # $SHELL_JSON by name and redirect into a temp file.
    # shellcheck disable=SC2016  # jq/awk program text -- the single quotes are
    # what keep $plugin / $0 as the filter's own variables, not the shell's.
    wpm_cfg edit --root "$ROOT" --rel "$REL_SHELL_JSON" --mode 0600 \
      --max-bytes "$WPM_MAX_CONFIG_BYTES" -- \
      "$JQ" \
      --arg plugin "$PLUGIN_ID" \
      --arg native "$NATIVE_PLUGIN_ID" \
      --argjson owns "$owns_disable" \
      '
      .plugins = ((.plugins // []) | map(select(.id != $plugin))) |
      .cloneSourceRestores = ((.cloneSourceRestores // []) | map(select(. != $plugin))) |
      (if $owns
       then .disabledPlugins = ((.disabledPlugins // []) | map(select(. != $native)))
       else . end) |
      (if (.disabledPlugins | length) == 0 then del(.disabledPlugins) else . end) |
      (if (.cloneSourceRestores | length) == 0 then del(.cloneSourceRestores) else . end)
      ' \
      || wpm_die "could not update $SHELL_JSON; if it is group- or other-writable, chmod go-w it first"
    if [[ $owns_disable == "true" ]]; then
      printf '==> unregistered %s and restored %s in %s\n' "$PLUGIN_ID" "$NATIVE_PLUGIN_ID" "$SHELL_JSON"
    else
      printf '==> unregistered %s in %s\n' "$PLUGIN_ID" "$SHELL_JSON"
      printf 'Left %s disabled: cloneSourceRestores[] does not name this plugin,\n' "$NATIVE_PLUGIN_ID"
      printf 'so something else is responsible for disabling it.\n'
    fi
  else
    # Neither plugins[] nor cloneSourceRestores[] mentions us. Nothing to
    # unregister, and no claim on omarchy.background to release. The usual
    # cause is that `omarchy plugin disable` already ran: the shell removed
    # our entry and restored the native itself, which is the correct outcome.
    printf '%s is not registered in %s -- nothing to unregister.\n' "$PLUGIN_ID" "$SHELL_JSON"
    printf 'No claim on %s in cloneSourceRestores[] either, so its state is left\n' "$NATIVE_PLUGIN_ID"
    printf 'as found -- whoever disabled it (if anyone) still owns that.\n'
  fi
else
  printf '%s does not exist -- nothing to unregister.\n' "$SHELL_JSON"
fi

# --- 3. Remove the installed plugin directory ------------------------------
#
# `rm -rf "$PLUGIN_DIR"` is replaced by `prune-dir --remove-all`, which walks
# the tree descriptor-relatively: every directory is opened O_NOFOLLOW, a
# symlink is unlinked as an entry rather than descended into, and a component
# swapped underneath the walk fails with ELOOP instead of pointing the delete
# at somebody else's tree. The old guard was a `[[ -d ]]` that followed the
# link it was supposed to catch. --if-exists keeps a second run a no-op.
plugin_dir_type="$(stat_key "$ROOT" "$REL_PLUGIN_DIR" type)"
if [[ $plugin_dir_type == dir ]]; then
  wpm_cfg prune-dir --root "$ROOT" --rel "$REL_PLUGIN_DIR" --remove-all --if-exists \
    >/dev/null || wpm_die "could not remove $PLUGIN_DIR"
  printf '==> removed %s\n' "$PLUGIN_DIR"
else
  printf 'not present, skipping: %s\n' "$PLUGIN_DIR"
fi

# --- Never touch the user's override config ---------------------------------
override_json_type="$(stat_key "$HOME" ".config/omarchy/background-per-monitor.json" type)"
if [[ $override_json_type == reg ]]; then
  printf '\nNote: your per-monitor override config is still at:\n\n    %s\n\n' "$OVERRIDE_JSON"
  printf 'This is your own config, not something this installer created on your\n'
  printf 'behalf -- it is left in place. Remove it by hand if you no longer want it.\n'
fi

if [[ $DRY_RUN == 1 ]]; then
  # Mirrors install.sh's preview. Worth printing here above all: whether
  # omarchy.background comes back out of disabledPlugins[] is the entire
  # point of declaring omarchy.clonedFrom, and this is where you can read it
  # off without touching the live config.
  shell_json_type="$(stat_key "$ROOT" "$REL_SHELL_JSON" type)"
  if [[ $shell_json_type != absent ]]; then
    printf '\nResulting shell.json would contain:\n'
    "$JQ" '{plugins, disabledPlugins, cloneSourceRestores}' \
      <<<"$(wpm_cfg read --root "$ROOT" --rel "$REL_SHELL_JSON" --max-bytes "$WPM_MAX_CONFIG_BYTES")"
  fi
  printf '\nDRY RUN complete. Nothing under ~/.config/omarchy or ~/.local/bin was changed.\n'
else
  printf '\nUninstalled. Restart omarchy-shell (or your session) for the change to take effect.\n'
fi
