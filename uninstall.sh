#!/bin/bash
# OPTIONAL AND MANUAL. Nothing runs this for you: Omarchy has no uninstall
# hook, and `omarchy plugin remove` runs nothing either.
#
# Reverses exactly what install.sh does, in reverse order:
#
#   1. Removes wallpaper-monitor, wp and omarchy-wallpaper-render from
#      ~/.local/bin -- but ONLY if each is a symlink pointing at THIS
#      plugin's installed bin/ directory. A file or a symlink to something
#      else is left alone (it is not ours to remove).
#   2. Removes "vitorcanoas.background-per-monitor" from plugins[] in
#      ~/.config/omarchy/shell.json, and removes "omarchy.background" from
#      disabledPlugins[] -- but ONLY if our own plugin id is still present in
#      plugins[] at the time this runs. shell.json does not record WHO
#      disabled a plugin, so this is a heuristic, not a certainty: if our
#      plugin id is missing (already removed by hand, or never registered),
#      we have no evidence this installer is the one that disabled the
#      native background, so disabledPlugins[] is left untouched and the
#      script says so.
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

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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

cleanup() {
  [[ -n "${STAGE:-}" ]] && rm -rf "$STAGE"
  [[ -n "${TMP_JSON:-}" ]] && rm -f "$TMP_JSON"
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
  real_plugin_dir="$OMARCHY_CONFIG_DIR/plugins/$PLUGIN_ID"
  for name in wallpaper-monitor wp omarchy-wallpaper-render; do
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

# --- 1. Remove the 3 symlinks from ~/.local/bin, but only our own ---------
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
unlink_one omarchy-wallpaper-render

# --- 2. Unregister the plugin and (conditionally) restore the native one --
if [[ -f $SHELL_JSON ]]; then
  is_registered="$(jq --arg plugin "$PLUGIN_ID" '(.plugins // []) | any(.id == $plugin)' "$SHELL_JSON")"

  if [[ $is_registered == "true" ]]; then
    # Same backup-before-writing discipline as install.sh, and the same
    # nanosecond-resolution timestamp to avoid same-second collisions.
    BACKUP="$SHELL_JSON.bak.$(date +%Y%m%d-%H%M%S-%N)"
    cp "$SHELL_JSON" "$BACKUP"
    printf '==> backed up %s -> %s\n' "$SHELL_JSON" "$BACKUP"

    TMP_JSON="$(mktemp)"
    jq \
      --arg plugin "$PLUGIN_ID" \
      --arg native "$NATIVE_PLUGIN_ID" \
      '
      .plugins = ((.plugins // []) | map(select(.id != $plugin))) |
      .disabledPlugins = ((.disabledPlugins // []) | map(select(. != $native)))
      ' \
      "$SHELL_JSON" >"$TMP_JSON"
    mv "$TMP_JSON" "$SHELL_JSON"
    printf '==> unregistered %s and restored %s in %s\n' "$PLUGIN_ID" "$NATIVE_PLUGIN_ID" "$SHELL_JSON"
  else
    # Our plugin id is absent -- either already uninstalled, or never
    # registered. Either way we have no evidence THIS installer is what put
    # omarchy.background in disabledPlugins[], so leave disabledPlugins[]
    # untouched rather than guess: the user (or another plugin) may have
    # disabled the native background independently.
    printf '%s is not registered in %s -- nothing to unregister.\n' "$PLUGIN_ID" "$SHELL_JSON"
    printf 'Leaving disabledPlugins[] untouched: no evidence this installer is what\n'
    printf 'disabled %s. If you want the native background back, remove it from\n' "$NATIVE_PLUGIN_ID"
    printf 'disabledPlugins[] in %s by hand.\n' "$SHELL_JSON"
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
  printf '\nDRY RUN complete. Nothing under ~/.config/omarchy or ~/.local/bin was changed.\n'
else
  printf '\nUninstalled. Restart omarchy-shell (or your session) for the change to take effect.\n'
fi
