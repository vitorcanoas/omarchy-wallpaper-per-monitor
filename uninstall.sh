#!/bin/bash
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

set -euo pipefail

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
  BIN_DIR="$STAGE/local-bin"
  mkdir -p "$STAGE/plugins" "$BIN_DIR"
  # Mirror the real state into the staging dir so the dry run reflects what
  # a real uninstall would actually find and do.
  if [[ -f "$OMARCHY_CONFIG_DIR/shell.json" ]]; then
    cp "$OMARCHY_CONFIG_DIR/shell.json" "$SHELL_JSON"
  else
    printf '{}\n' >"$SHELL_JSON"
  fi
  if [[ -d "$OMARCHY_CONFIG_DIR/plugins/$PLUGIN_ID" ]]; then
    cp -a "$OMARCHY_CONFIG_DIR/plugins/$PLUGIN_ID" "$PLUGIN_DIR"
  fi
  # Mirror the menu extension file too, so the dry run reports whether our
  # block is really there and what removing it would leave behind.
  real_menu_jsonc="$MENU_JSONC"
  MENU_JSONC="$STAGE/extensions/omarchy-menu.jsonc"
  mkdir -p "$STAGE/extensions"
  if [[ -f "$real_menu_jsonc" ]]; then
    cp "$real_menu_jsonc" "$MENU_JSONC"
  fi
  real_plugin_dir="$OMARCHY_CONFIG_DIR/plugins/$PLUGIN_ID"
  for name in wallpaper-monitor wp wallpaper-monitor-menu; do
    real_link="$HOME/.local/bin/$name"
    if [[ -L $real_link ]]; then
      real_target="$(readlink -f "$real_link")"
      # Rewrite a target that points at the real plugin dir to point at the
      # STAGED plugin dir instead, so the dry run's "is this our symlink"
      # comparison (against the staged PLUGIN_DIR) matches the same way the
      # real uninstall's comparison (against the real PLUGIN_DIR) would.
      # A symlink pointing anywhere else is copied as-is, so it still shows
      # up as a foreign link the dry run correctly leaves alone.
      case "$real_target" in
        "$real_plugin_dir"/*)
          ln -s "$PLUGIN_DIR/bin/$name" "$BIN_DIR/$name"
          ;;
        *)
          ln -s "$real_target" "$BIN_DIR/$name"
          ;;
      esac
    fi
  done
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

  # Existing file keeps its own mode instead of silently inheriting
  # mktemp's 0600; 0600 is only the default for a file that does not exist
  # yet (matches write_atomic()'s fallback). In practice uninstall.sh only
  # reaches here when $SHELL_JSON already exists, but the same helper is
  # kept identical to install.sh's for a single reviewed behaviour.
  local mode=600
  if [[ -f $dest ]]; then
    mode="$(stat -c %a -- "$dest")"
  fi
  chmod "$mode" "$tmp"

  # fsync the temp file's contents, THEN rename, THEN fsync the directory.
  # rename(2) is atomic for visibility but says nothing about durability --
  # without this, a power cut right after uninstall can leave the rename
  # durable while the data behind it is not. A failure here must abort
  # before the rename, not be swallowed: under `set -e` a non-zero exit from
  # python3 does exactly that.
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

remove_menu_entry() {
  if [[ ! -f $MENU_JSONC ]]; then
    printf 'not present, skipping: %s\n' "$MENU_JSONC"
    return 0
  fi

  if ! grep -qF "$MENU_MARK_BEGIN" "$MENU_JSONC"; then
    printf 'no menu entry of ours in %s -- nothing to remove.\n' "$MENU_JSONC"
    return 0
  fi

  # If the closing marker is missing, the block has been hand-edited and we
  # cannot tell where it ends. Deleting from the opening marker to EOF would
  # eat the user's own rows below it, so refuse and let them look.
  if ! grep -qF "$MENU_MARK_END" "$MENU_JSONC"; then
    cat >&2 <<MSG
$MENU_JSONC contains our opening marker but not the closing one:

    $MENU_MARK_END

The block has been edited by hand and its end cannot be determined safely.
Leaving the file alone -- remove the row for
"style.wallpaper-per-monitor" yourself.

MSG
    return 0
  fi

  # Declared and assigned separately (SC2155): `local x="$(cmd)"` takes the
  # exit status of `local`, which is always 0, so a failing date would be
  # swallowed and the backup would land on a truncated name.
  local backup
  backup="$MENU_JSONC.bak.$(date +%Y%m%d-%H%M%S-%N)"
  cp "$MENU_JSONC" "$backup"
  printf '==> backed up %s -> %s\n' "$MENU_JSONC" "$backup"

  # Temp file in the destination directory: the mv becomes an atomic
  # rename(2). See install.sh.
  TMP_MENU="$(mktemp -p "$(dirname "$MENU_JSONC")" .omarchy-menu.jsonc.XXXXXX)"
  # awk with fixed-string comparison (index/==), never a regex: the markers
  # contain "/" and "." and ">", which in a regex would match more than the
  # literal marker line.
  awk -v b="$MENU_MARK_BEGIN" -v e="$MENU_MARK_END" '
    index($0, b) { skip = 1; next }
    skip && index($0, e) { skip = 0; next }
    !skip { print }
  ' "$MENU_JSONC" >"$TMP_MENU"
  # Same finalizer the shell.json write uses: preserve the destination's mode
  # instead of inheriting mktemp's 0600, fsync the file, rename, fsync the
  # directory. A plain `mv` here used to narrow a user's 0644
  # omarchy-menu.jsonc to 0600 -- and unlike shell.json this file is what the
  # user is left with AFTER the plugin is gone, so the wrong mode would
  # outlive the uninstall.
  finalize_shell_json "$TMP_MENU" "$MENU_JSONC"
  TMP_MENU=""
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
  local link="$BIN_DIR/$name"
  local expected_target="$PLUGIN_DIR/bin/$name"

  if [[ ! -e $link && ! -L $link ]]; then
    printf 'not present, skipping: %s\n' "$link"
    return 0
  fi

  if [[ -L $link ]]; then
    # readlink -f on a dangling symlink still resolves the (non-existent)
    # target path textually, which is exactly what we want to compare here.
    if [[ "$(readlink -f "$link")" == "$(readlink -f "$expected_target")" ]]; then
      rm -f "$link"
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
# Preserves the target's existing permission mode (mktemp always creates the
# temp file 0600, and a plain `mv` would carry that into shell.json) and
# fsyncs the temp file + its directory before and after the rename, so the
# write is durable and not just atomic-for-visibility. Same approach as
# bin/wallpaper-monitor's write_atomic(): chmod before rename, fsync(file)
# before rename, fsync(dir) after. Mirrored from install.sh.
if [[ -f $SHELL_JSON ]]; then
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
  owns_disable="$(jq --arg plugin "$PLUGIN_ID" \
    '((.cloneSourceRestores // []) | index($plugin)) != null' "$SHELL_JSON")"
  is_registered="$(jq --arg plugin "$PLUGIN_ID" '(.plugins // []) | any(.id == $plugin)' "$SHELL_JSON")"

  if [[ $owns_disable == "true" || $is_registered == "true" ]]; then
    # Same backup-before-writing discipline as install.sh, and the same
    # nanosecond-resolution timestamp to avoid same-second collisions.
    BACKUP="$SHELL_JSON.bak.$(date +%Y%m%d-%H%M%S-%N)"
    cp "$SHELL_JSON" "$BACKUP"
    printf '==> backed up %s -> %s\n' "$SHELL_JSON" "$BACKUP"

    # Temp file in the destination directory: the mv becomes an atomic
    # rename(2). See install.sh.
    TMP_JSON="$(mktemp -p "$(dirname "$SHELL_JSON")" .shell.json.XXXXXX)"
    # Mirrors PluginRegistry.restoreCloneSource(): drop our plugins[] entry,
    # drop our claim from cloneSourceRestores[], and re-enable the source --
    # that last step ONLY if the claim was ours ($owns_disable). Both arrays
    # are deleted when they end up empty, which is what
    # setCloneShouldRestoreSource/removeDisabled do, so the file stays
    # identical to one the shell would have produced.
    jq \
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
      "$SHELL_JSON" >"$TMP_JSON"
    finalize_shell_json "$TMP_JSON" "$SHELL_JSON"
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
if [[ -d $PLUGIN_DIR ]]; then
  rm -rf "$PLUGIN_DIR"
  printf '==> removed %s\n' "$PLUGIN_DIR"
else
  printf 'not present, skipping: %s\n' "$PLUGIN_DIR"
fi

# --- Never touch the user's override config ---------------------------------
if [[ -f $OVERRIDE_JSON ]]; then
  printf '\nNote: your per-monitor override config is still at:\n\n    %s\n\n' "$OVERRIDE_JSON"
  printf 'This is your own config, not something this installer created on your\n'
  printf 'behalf -- it is left in place. Remove it by hand if you no longer want it.\n'
fi

if [[ $DRY_RUN == 1 ]]; then
  # Mirrors install.sh's preview. Worth printing here above all: whether
  # omarchy.background comes back out of disabledPlugins[] is the entire
  # point of declaring omarchy.clonedFrom, and this is where you can read it
  # off without touching the live config.
  if [[ -f $SHELL_JSON ]]; then
    printf '\nResulting shell.json would contain:\n'
    jq '{plugins, disabledPlugins, cloneSourceRestores}' "$SHELL_JSON"
  fi
  printf '\nDRY RUN complete. Nothing under ~/.config/omarchy or ~/.local/bin was changed.\n'
else
  printf '\nUninstalled. Restart omarchy-shell (or your session) for the change to take effect.\n'
fi
