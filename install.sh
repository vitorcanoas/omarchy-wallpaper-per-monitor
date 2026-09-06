#!/bin/bash
# OPTIONAL AND MANUAL. Nothing runs this for you: Omarchy has no install hook,
# and `omarchy plugin remove` runs nothing either.
#
# Unlike a bar-widget plugin, this one is a "service" that REPLACES the native
# background (it disables omarchy.background in shell.json), so installing it
# does three things, in order:
#
#   1. Copies this repo into ~/.config/omarchy/plugins/vitorcanoas.background-per-monitor/
#      (manifest.json, Background.qml, bin/ -- the parts Omarchy actually
#      loads; .git, tests/, .github/ and docs/ are left out, they carry
#      nothing the running shell needs).
#   2. Registers the plugin and disables the native one in
#      ~/.config/omarchy/shell.json (backed up first).
#   3. Symlinks wallpaper-monitor, wp and omarchy-wallpaper-render into
#      ~/.local/bin, so they work as bare commands from anywhere.
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

# Single cleanup trap for the whole script (DRY_RUN staging dir and/or the
# real-path TMP_JSON below) -- a second `trap ... EXIT` would silently
# replace this one rather than stack, so anything that needs cleanup on exit
# must be added to this same function instead of calling `trap` again.
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
  mkdir -p "$STAGE/plugins" "$(dirname "$BIN_DIR")"
  BIN_DIR="$STAGE/local-bin"
  # Seed a shell.json so the dry run has something realistic to show a diff
  # against, if a real one already exists; otherwise start from empty.
  if [[ -f "$OMARCHY_CONFIG_DIR/shell.json" ]]; then
    cp "$OMARCHY_CONFIG_DIR/shell.json" "$SHELL_JSON"
  else
    printf '{}\n' >"$SHELL_JSON"
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
mkdir -p "$PLUGIN_DIR"
rsync -a --delete \
  --exclude '.git/' \
  --exclude '.github/' \
  --exclude 'tests/' \
  --exclude 'docs/' \
  --exclude '*.bak.*' \
  "$HERE"/ "$PLUGIN_DIR"/
chmod +x "$PLUGIN_DIR/bin/wallpaper-monitor" "$PLUGIN_DIR/bin/wp" "$PLUGIN_DIR/bin/omarchy-wallpaper-render"

# --- 1b. Pre-flight check that all 3 symlinks CAN be created ---------------
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
check_link_one omarchy-wallpaper-render

# --- 2 & 3. Register the plugin and disable the native one ----------------
#
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

TMP_JSON="$(mktemp)"
# plugins[] entries are objects ({"id": "..."}, sometimes with extra
# per-plugin settings alongside), not bare strings -- confirmed against a
# real shell.json. disabledPlugins[] is a flat string array. Dedupe plugins[]
# by .id so re-running this script never produces two entries for the same
# plugin.
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
  .disabledPlugins = ((.disabledPlugins // []) + [$native] | unique)
  ' \
  "$SHELL_JSON" >"$TMP_JSON"
mv "$TMP_JSON" "$SHELL_JSON"
printf '==> registered %s and disabled %s in %s\n' "$PLUGIN_ID" "$NATIVE_PLUGIN_ID" "$SHELL_JSON"

# --- 4. Symlink the CLIs into ~/.local/bin ---------------------------------
# BIN_DIR was already created during the pre-flight check above; the check
# already ruled out any foreign (non-symlink) file at each of these 3 paths,
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
link_one omarchy-wallpaper-render

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'note: %s is not on your PATH\n' "$BIN_DIR" >&2 ;;
esac

if [[ $DRY_RUN == 1 ]]; then
  printf '\nDRY RUN complete. Nothing under ~/.config/omarchy or ~/.local/bin was changed.\n'
  printf 'Resulting shell.json would contain:\n'
  jq '{plugins, disabledPlugins}' "$SHELL_JSON"
else
  printf '\nInstalled. Restart omarchy-shell (or your session) to load the plugin.\n'
fi
