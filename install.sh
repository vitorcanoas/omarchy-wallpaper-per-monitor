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
# To undo a real install:
#
#     rm -rf ~/.config/omarchy/plugins/vitorcanoas.background-per-monitor
#     rm -f ~/.local/bin/wallpaper-monitor ~/.local/bin/wp ~/.local/bin/omarchy-wallpaper-render
#     # then edit shell.json by hand: drop "vitorcanoas.background-per-monitor"
#     # from plugins[], and drop "omarchy.background" from disabledPlugins[]
#     # if you want the native background plugin back.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PLUGIN_ID="vitorcanoas.background-per-monitor"
NATIVE_PLUGIN_ID="omarchy.background"

DRY_RUN="${DRY_RUN:-0}"

OMARCHY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"

if [[ $DRY_RUN == 1 ]]; then
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
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

# --- 2 & 3. Register the plugin and disable the native one ----------------
#
# Back up shell.json before touching it -- it is hand-edited, human-owned
# config, not something regenerated on demand.
if [[ -f $SHELL_JSON ]]; then
  BACKUP="$SHELL_JSON.bak.$(date +%Y%m%d-%H%M%S)"
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
mkdir -p "$BIN_DIR"

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
