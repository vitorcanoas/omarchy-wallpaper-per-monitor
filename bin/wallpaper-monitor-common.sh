# shellcheck shell=bash
# wallpaper-monitor-common.sh -- closed-environment preamble, shared by
# install.sh, uninstall.sh, bin/wallpaper-monitor, bin/wp and
# bin/wallpaper-monitor-menu.
#
# THIS FILE IS SOURCED, NEVER EXECUTED.
# ------------------------------------
# It ships mode 0644 with NO executable bit and carries NO shebang, exactly
# like bin/wallpaper-monitor-config.py (also 0644, always invoked as
# "$PYTHON3" -I -B /abs/path/to/helper.py, so its shebang is never consulted).
# The missing executable bit is the control; there is no sentinel variable and
# no runtime self-check for it. The three directly-executed CLIs keep an
# ABSOLUTE shebang -- `#!/usr/bin/bash`, not `#!/usr/bin/env bash` and not
# `#!/bin/bash`: see the merged-/usr note in section 3 below. Background.qml
# already pins /usr/bin/bash (line 230), so /usr/bin/bash is the spelling the
# whole plugin agrees on.
#
# WHY IT EXISTS
# -------------
# Marketplace finding F1: the scripts used `#!/usr/bin/env bash` plus a long
# tail of ambient-PATH tools (rsync, jq, python3, mktemp, cp, mv, rm, ln, grep,
# awk, realpath, file, hyprctl, sed, tr, head, date, dirname, basename, cat,
# ...), and the installer probed PATH with `command -v` and then trusted that
# same PATH for configuration-changing execution. A `command -v` answers a
# question about the PATH at probe time; the bare-name invocation forty lines
# later re-answers it, and nothing guarantees the two agree.
#
# This preamble closes that: the environment is sanitized, PATH is SET rather
# than trusted, and every tool that survives is resolved ONCE from a fixed
# absolute candidate list, validated through the helper's `check-tool`, and
# frozen into a readonly exported variable. Every later call site uses "$JQ",
# "$AWK", "$HYPRCTL" and friends. There is no PATH fallback anywhere: an
# unresolvable required tool is a loud, bounded, one-line abort.
#
# HOW THE FIVE SCRIPTS BOOTSTRAP INTO IT (builtins only -- copy verbatim)
# ----------------------------------------------------------------------
# The bootstrap cannot call an external tool, because finding the tools is the
# very thing it is bootstrapping: `readlink -f`, which bin/wp:19 and
# bin/wallpaper-monitor-menu:30 use today, is itself PATH-resolved and runs
# before any hardening exists. So the bootstrap is pure bash -- `[[ -f ]]`,
# `[[ -L ]]`, `[[ -r ]]`, `[[ -O ]]`, `cd -P`, `pwd -P` and parameter
# expansion -- and nothing else:
#
#     #!/usr/bin/bash
#     set -uo pipefail                  # each script adds its own -e; see (2)
#     wpm_bootstrap() {
#       local self=${BASH_SOURCE[1]} dir candidate
#       dir=${self%/*}; [[ $dir == "$self" ]] && dir=.
#       dir=$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P) || dir=""
#       local -a candidates=(
#         "$dir/wallpaper-monitor-common.sh"        # a bin/ script, run directly
#         "$dir/bin/wallpaper-monitor-common.sh"    # install.sh / uninstall.sh
#         "$HOME/.config/omarchy/plugins/vitorcanoas.background-per-monitor/bin/wallpaper-monitor-common.sh"
#       )                                           # via the ~/.local/bin symlink
#       for candidate in "${candidates[@]}"; do
#         [[ -f $candidate && ! -L $candidate && -r $candidate && -O $candidate ]] || continue
#         WPM_COMMON=$candidate; return 0
#       done
#       printf 'wallpaper-monitor: shared preamble not found or not trustworthy\n' >&2
#       exit 1
#     }
#     wpm_bootstrap
#     # shellcheck source=bin/wallpaper-monitor-common.sh
#     . "$WPM_COMMON"
#
# Candidate 3 needs no `readlink`: install.sh already hardcodes
# PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID" and points the
# ~/.local/bin symlinks into it, so the symlinked case has a known answer.
#
# WPM_BIN_DIR is NOT taken from the caller -- this file re-derives it from its
# own ${BASH_SOURCE[0]} with the same builtins (section 1), so all five
# scripts agree on it by construction rather than by five copies of the same
# expansion.
#
# WHAT THE BUILTIN ANCHOR CAN AND CANNOT DO (stated plainly)
# ----------------------------------------------------------
# `[[ -f && ! -L && -r && -O ]]` proves: regular file, not a symlink, readable,
# owned by the effective uid. It CANNOT test group/other-writability -- bash
# has no builtin for mode bits -- and it cannot check the parent chain. The
# helper's `check-tool` does all of that, and it is applied to every tool this
# file resolves.
#
# It is deliberately NOT applied to this file or to the helper, and the reason
# is that doing so would be circular rather than rigorous: `check-tool` runs by
# executing the helper with "$PYTHON3". Asking the helper whether the helper is
# trustworthy answers nothing -- a tampered helper simply says yes. Likewise,
# by the time this file can run a check on itself it has already been read and
# executed. So the builtin anchor in the bootstrap above is the honest boundary
# for these two files, and the residual gap (a same-uid in-place rewrite of
# bin/*, i.e. an attacker who can already write as the user) is named here
# rather than papered over. `check-tool` is spent where it is not circular: on
# jq, awk, grep, hyprctl, file and the omarchy-* binaries, which is where
# attacker-influenced arguments are actually handed to a foreign program.

# --- Guard: refuse to run as a program -----------------------------------
# Shipping 0644 already prevents `./wallpaper-monitor-common.sh`. This catches
# the other spelling, `bash wallpaper-monitor-common.sh`, which would sanitize
# a shell that is about to exit and silently do nothing.
if ! (return 0 2>/dev/null); then
  printf 'wallpaper-monitor-common.sh: this file must be sourced, not executed\n' >&2
  exit 1
fi

# --- 0. Exported shell functions are executable code ---------------------
# A BASH_FUNC_x%% entry in the environment defines a function in THIS shell and
# in every subshell it forks. It outranks anything we do later: an exported
# `printf` or `wpm_die` would be live code injection into the middle of a
# configuration-changing script. Nothing in this plugin is ever invoked with an
# inherited function, so all of them go, before a single other statement runs.
while read -r _wpm_decl _wpm_flags _wpm_fname _wpm_rest; do
  [[ $_wpm_decl == declare && $_wpm_flags == *x* && -n ${_wpm_fname:-} ]] || continue
  unset -f -- "$_wpm_fname" 2>/dev/null || true
done < <(declare -Fx 2>/dev/null || true)
unset -v _wpm_decl _wpm_flags _wpm_fname _wpm_rest

# --- 1. Shell state -------------------------------------------------------
# IFS: a hostile IFS (say `/`) turns every unquoted expansion into a splitter.
# Reset to the default before any expansion that could matter.
IFS=$' \t\n'

# `-u` (unset variables are errors) and `pipefail` (a pipeline reports the
# first failing stage, not the last) are wanted everywhere.
#
# `errexit` is deliberately NOT set here, and must not be added: bin/wp runs
# without `-e` on purpose so it can collect `rc=$?` from the CLI it invokes,
# while bin/wallpaper-monitor sets `-euo pipefail` itself at line 26. Setting
# it here would silently change bin/wp's control flow. Each script keeps its
# own `set -e` line.
set -uo pipefail

# SHELLOPTS and BASHOPTS are read-only in a running bash, so `unset` cannot
# remove them; they were consumed at startup, before this file existed. What
# is still reachable is the options they switched on, so switch the dangerous
# ones back off explicitly. (`allexport` would export every later assignment
# into every child; `xtrace`/`verbose` would spray the user's config contents
# into whatever log the caller is teeing; `noglob` and `noclobber` change the
# meaning of code written without them.)
unset -v SHELLOPTS BASHOPTS 2>/dev/null || true
set +o allexport +o xtrace +o verbose +o noclobber +f
shopt -u expand_aliases
PS4='+ '

# --- 2. Environment sanitization -----------------------------------------
# INVENTORY section A.4 found NO sanitization anywhere in the five scripts:
# not PATH, not IFS, not BASH_ENV, not ENV, not LD_PRELOAD, not
# LD_LIBRARY_PATH, not CDPATH, not SHELLOPTS, not GLOBIGNORE. Every name below
# changes what a later command does without appearing at that command's call
# site -- which is the whole reason they are worth clearing.
#
#   CDPATH           makes `cd foo` land somewhere else entirely; the `cd -P`
#                    in the bootstrap above sets CDPATH='' for exactly this.
#   GLOBIGNORE       silently removes entries from a glob -- an allowlist that
#                    quietly loses a member.
#   BASH_ENV / ENV   a file bash sources at the start of every non-interactive
#                    shell: arbitrary code, no call site.
#   LD_PRELOAD, LD_LIBRARY_PATH, LD_AUDIT, LD_DEBUG
#                    inject or redirect code inside every child we exec,
#                    including jq, awk and python3.
#   PYTHONPATH, PYTHONHOME, PYTHONSTARTUP, PYTHONWARNINGS
#                    belt and braces: every helper invocation already passes
#                    `-I`, which neutralises them, but nothing guarantees a
#                    future call site remembers the flag.
#   POSIXLY_CORRECT  changes the behaviour of coreutils and of bash itself.
#   BASH_XTRACEFD    redirects trace output to a descriptor of someone else's
#                    choosing.
#   LANGUAGE         outranks LC_ALL for message translation, so clearing it
#                    is what makes the C-locale pin below actually hold.
unset -v CDPATH GLOBIGNORE BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT \
         LD_DEBUG PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONWARNINGS \
         POSIXLY_CORRECT BASH_XTRACEFD LANGUAGE

# PATH is SET, not trusted. Nothing in the migrated scripts resolves a program
# through it -- that is the point of the table in section 3 -- but a stray
# `command -v`, a subprocess of a subprocess, or a future edit must not be able
# to reach ~/.local/bin or a writable directory the user happens to have in
# their login PATH. /bin is kept purely as a compatibility entry for a
# hypothetical non-merged-/usr system; on Arch it is a symlink to usr/bin and
# resolves to the same directory.
#
# LC_ALL=C / LANG=C subsume the hand-rolled `export LC_ALL=C` at bin/wp:17 and
# bin/wallpaper-monitor-menu:28 -- same value, so catalogue glob ordering is
# unchanged -- and extend the same pin to bin/wallpaper-monitor, which only
# ever scoped it to one `sleep` (line 139).
export PATH=/usr/bin:/bin
export LC_ALL=C
export LANG=C

# NO umask is set here, deliberately. bin/wallpaper-monitor already picks one
# per operation -- `umask 022` around the config write (line 168), `umask 077`
# around the lock directories (lines 98, 110) -- and a global umask in this
# file would change the mode of files those subshells create.

# Drop any cached command lookups made before PATH was pinned.
hash -r 2>/dev/null || true

# --- 3. Identity of this file and of the helper --------------------------
# Derived from this file's own BASH_SOURCE with builtins only: no readlink, no
# realpath, no dirname. `CDPATH=''` is required even though CDPATH was just
# unset, because `cd` is also influenced by a CDPATH exported into a subshell
# -- the approved reference (omarchy-nightlight:73) spells it the same way.
# `pwd -P` gives the physical directory, so a symlinked plugin directory yields
# the real path once, here, instead of at five separate call sites.
_wpm_self=${BASH_SOURCE[0]}
_wpm_dir=${_wpm_self%/*}
[[ $_wpm_dir == "$_wpm_self" ]] && _wpm_dir=.
_wpm_dir=$(CDPATH='' cd -P -- "$_wpm_dir" 2>/dev/null && pwd -P) || _wpm_dir=""
if [[ -z $_wpm_dir || $_wpm_dir != /* ]]; then
  printf 'wallpaper-monitor: could not resolve the plugin bin directory\n' >&2
  exit 1
fi

WPM_BIN_DIR=$_wpm_dir
WPM_COMMON="$WPM_BIN_DIR/${_wpm_self##*/}"
WPM_HELPER="$WPM_BIN_DIR/wallpaper-monitor-config.py"
unset -v _wpm_self _wpm_dir

# The same builtin anchor the bootstrap applied to this file, now applied to
# the helper -- BEFORE it is ever handed to "$PYTHON3". See the header for why
# this is where the non-circular checks stop.
if [[ ! -f $WPM_HELPER || -L $WPM_HELPER || ! -r $WPM_HELPER || ! -O $WPM_HELPER ]]; then
  printf 'wallpaper-monitor: helper missing or not trustworthy: %s\n' "$WPM_HELPER" >&2
  exit 1
fi

readonly WPM_BIN_DIR WPM_COMMON WPM_HELPER
export WPM_BIN_DIR WPM_COMMON WPM_HELPER

# Program name for wpm_die / wpm_warn. BASH_SOURCE[1] is the script that
# sourced us. Honour a value the caller set before sourcing.
if [[ -z ${WPM_PROGNAME:-} ]]; then
  if [[ -n ${BASH_SOURCE[1]:-} ]]; then
    WPM_PROGNAME=${BASH_SOURCE[1]##*/}
  else
    WPM_PROGNAME=wallpaper-monitor
  fi
fi
export WPM_PROGNAME

# --- 4. Constants ---------------------------------------------------------
WPM_PLUGIN_ID="vitorcanoas.background-per-monitor"   # install.sh:50, uninstall.sh:45
WPM_NATIVE_PLUGIN_ID="omarchy.background"            # install.sh:51, uninstall.sh:46

# The self-referencing CLI. INVENTORY A.2 flags bin/wp:21 and
# bin/wallpaper-monitor-menu:37, where CLI falls back to the BARE STRING
# "wallpaper-monitor" when the sibling is not executable -- a PATH-resolved
# child process, used at bin/wp:280 and `exec`'d at bin/wallpaper-monitor-menu:391.
# The sibling's absolute path is known here, so the bare-name fallback can go.
WPM_CLI="$WPM_BIN_DIR/wallpaper-monitor"

# Read budget for every config read. 262144 = the helper's own MAX_FILE_BYTES,
# which --max-bytes may only lower, never raise. It replaces four inconsistent
# copies of a 1 MiB literal (bin/wallpaper-monitor:185, bin/wp:57,
# bin/wallpaper-monitor-menu:75 and :237), three of which were declared next to
# an unbounded read that never enforced them.
WPM_MAX_CONFIG_BYTES=262144

# Caps for the two bounded command substitutions F5 names (section 6.4 of the
# design). Both are about two orders of magnitude above observed output, and
# going over is a loud failure, never a silent truncation.
WPM_MAX_HYPRCTL_BYTES=65536   # bin/wallpaper-monitor:611 `hyprctl monitors -j`
WPM_MAX_FILE_BYTES=256        # bin/wallpaper-monitor:379 `file -b --mime-type`

# Monitor-name shape, unified from the two existing copies (bin/wp:112 and
# bin/wallpaper-monitor-menu:44, plus the inline literal at
# bin/wallpaper-monitor:360). Byte-identical to what those three use today.
WPM_MONITOR_RE='^[A-Za-z0-9._:-]+$'
WPM_MAX_MONITORS=64
WPM_MAX_MONITOR_NAME_BYTES=64

readonly WPM_PLUGIN_ID WPM_NATIVE_PLUGIN_ID WPM_CLI WPM_MAX_CONFIG_BYTES \
         WPM_MAX_HYPRCTL_BYTES WPM_MAX_FILE_BYTES WPM_MONITOR_RE \
         WPM_MAX_MONITORS WPM_MAX_MONITOR_NAME_BYTES
export WPM_PLUGIN_ID WPM_NATIVE_PLUGIN_ID WPM_CLI WPM_MAX_CONFIG_BYTES \
       WPM_MAX_HYPRCTL_BYTES WPM_MAX_FILE_BYTES WPM_MONITOR_RE \
       WPM_MAX_MONITORS WPM_MAX_MONITOR_NAME_BYTES

# The payload allowlist: `path:mode`, one entry per installed file. It replaces
# the `rsync --include` list at install.sh:234-246 AND the `chmod +x` at :247,
# so the executable bit travels with the entry instead of being a second list
# that can drift out of sync. It is also the `--keep` list for `prune-dir`, so
# the copy and the delete cannot disagree about what belongs in the plugin
# directory. Fail-closed semantics are preserved exactly: a file not named here
# is not installed.
#
# A bash array cannot be exported (the environment holds strings only), so this
# is readonly but not exported. Every consumer sources this file, so every
# consumer has it.
WPM_PAYLOAD=(
  "manifest.json:0644"
  "Background.qml:0644"
  "BoundedProcess.qml:0644"
  "install.sh:0755"
  "uninstall.sh:0755"
  "README.md:0644"
  "LICENSE:0644"
  "bin/wallpaper-monitor:0755"
  "bin/wp:0755"
  "bin/wallpaper-monitor-menu:0755"
  "bin/wallpaper-monitor-common.sh:0644"
  "bin/wallpaper-monitor-config.py:0644"
)
readonly WPM_PAYLOAD

# --- 5. The tool table ----------------------------------------------------
# Fixed absolute candidates, in preference order. Resolved lazily by
# wpm_require / wpm_optional, once per name, then frozen readonly+exported.
#
# ORDERING DECISION -- /bin/... ENTRIES ARE DELIBERATELY ABSENT
# -------------------------------------------------------------
# The design's candidate lists carried a /bin/... entry beside each
# /usr/bin/... one. Every such entry is DEAD on the target platform and was
# removed on purpose; this paragraph exists so a reviewer does not read the
# absence as an oversight.
#
# Omarchy is Arch-based, and Arch is a merged-/usr distribution: /bin is a
# SYMLINK to usr/bin. `check-tool` walks a tool's path one component at a time
# from / with O_NOFOLLOW, exactly so that a directory swapped for a symlink
# cannot redirect the resolution -- so it opens "bin" relative to "/", meets
# the symlink, and refuses:
#
#     $ ... check-tool --path /bin/jq
#     wallpaper-monitor-config: check-tool: could not open directory safely: Not a directory
#     $ ... check-tool --path /usr/bin/jq
#     ok /usr/bin/jq
#
# That is the walk behaving CORRECTLY, and it must not be weakened to make
# /bin work. A /bin candidate could only ever be reached after the /usr/bin one
# had already failed, at which point it would fail too -- so it buys nothing,
# and it would put two paths in the failure message that provably cannot
# validate on the only platform this plugin supports. /usr/local/bin is kept
# wherever a locally built or vendor-dropped binary is plausible (python3, jq,
# hyprctl, the omarchy-* tools).
#
# For the same reason the three executable CLIs use `#!/usr/bin/bash`, not
# `#!/bin/bash`: an absolute shebang through /bin would resolve fine for the
# kernel but is the same dead spelling, and Background.qml:230 already pins
# /usr/bin/bash.
#
# A final-component symlink is fine and expected: /usr/bin/python3 is
# /etc/alternatives/python3 on Debian-family systems and python3.13 on Arch.
# `check-tool` follows up to 8 hops and re-anchors and re-validates the full
# parent chain at each one, which is strictly stronger than a
# same-directory-only rule.
#
# NOT IN THIS TABLE, AND WHY
# --------------------------
# Replaced by helper subcommands (they cannot be fixed by pinning, because they
# re-resolve paths by name inside a process we do not control):
#   rsync -> install-file + prune-dir;  readlink -f -> resolve-link;
#   stat -> stat;  cp -> install-file;  mv -> rename/edit;  rm -> unlink;
#   mkdir -> mkdir-chain;  rmdir -> rmdir;  chmod -> the mode argument;
#   ln -s -> symlink.
# Replaced by bash builtins:
#   date  -> printf '%(%Y%m%d-%H%M%S)T' -1 plus ${EPOCHREALTIME#*.} for the
#            sub-second uniqueness the backup-name comment requires
#   dirname / basename -> ${x%/*} / ${x##*/}
#   cat (heredoc emitters only) -> printf
#   kill -0 -> the kill builtin
#   command -v -> wpm_require / wpm_optional
# Replaced by the helper's supervised `run`:
#   timeout, head -c -> wpm_bounded (see its definition for why).
declare -A WPM_TOOL_CANDIDATES=(
  # name                  candidates, in preference order
  [PYTHON3]='/usr/bin/python3 /usr/local/bin/python3'
  [JQ]='/usr/bin/jq /usr/local/bin/jq'
  [AWK]='/usr/bin/awk /usr/bin/gawk /usr/bin/mawk'
  [GREP]='/usr/bin/grep'
  [SED]='/usr/bin/sed'
  [TR]='/usr/bin/tr'
  [HEAD]='/usr/bin/head'
  [MKTEMP]='/usr/bin/mktemp'
  [SLEEP]='/usr/bin/sleep'
  [REALPATH]='/usr/bin/realpath'
  [FILE]='/usr/bin/file'
  [HYPRCTL]='/usr/bin/hyprctl /usr/local/bin/hyprctl'
  [OMARCHY]='/usr/bin/omarchy /usr/local/bin/omarchy'
  [OMARCHY_SHELL]='/usr/bin/omarchy-shell /usr/local/bin/omarchy-shell'
  [OMARCHY_MENU_SELECT]='/usr/bin/omarchy-menu-select /usr/share/omarchy/bin/omarchy-menu-select'
  [OMARCHY_MENU_IMAGES]='/usr/bin/omarchy-menu-images /usr/share/omarchy/bin/omarchy-menu-images'
)
readonly WPM_TOOL_CANDIDATES
# Call sites each name serves (INVENTORY section A.2), so the table can be
# checked against the inventory line by line:
#   PYTHON3              everything -- install.sh:338,352; uninstall.sh:189,203;
#                        bin/wp:54,117,172; bin/wallpaper-monitor:314,336,433,
#                        473,509,540,562,616; bin/wallpaper-monitor-menu:70,181,232
#   JQ                   install.sh:452,664; uninstall.sh:333,335,353,410
#   AWK                  install.sh:579,628; uninstall.sh:258
#   GREP                 install.sh:569; uninstall.sh:222,230; bin/wp:158
#   SED                  install.sh:667 (DRY_RUN preview only, 3 uses on one line)
#   TR                   bin/wp:160
#   HEAD                 bin/wp:163 (`head -n1`)
#   MKTEMP               install.sh:128,385,613; uninstall.sh:78,254,346 --
#                        after migration only the DRY_RUN staging directory
#                        still needs it; the transaction temporaries are the
#                        helper's own O_EXCL|O_NOFOLLOW files
#   SLEEP                bin/wallpaper-monitor:139 (lock retry)
#   REALPATH             bin/wallpaper-monitor:371 (`realpath -m --`, unchanged)
#   FILE                 bin/wallpaper-monitor:379 -- OPTIONAL, falls back to
#                        the extension allowlist at 391-398
#   HYPRCTL              bin/wp:117,172; bin/wallpaper-monitor:611 -- OPTIONAL
#   OMARCHY              install.sh:176 (required)
#   OMARCHY_SHELL        install.sh:187 (optional, warn only)
#   OMARCHY_MENU_SELECT  bin/wallpaper-monitor-menu:338
#   OMARCHY_MENU_IMAGES  bin/wallpaper-monitor-menu:381

# Names already resolved, so wpm_require is idempotent and a second call does
# not try to reassign a readonly variable.
declare -A WPM_TOOL_RESOLVED=()

# --- 6. Functions ---------------------------------------------------------

# One bounded line on stderr, newlines flattened so a message built from a
# filename or a tool's output cannot forge an extra log line.
wpm_warn() {
  local message=${*//$'\n'/ }
  printf '%s: %s\n' "$WPM_PROGNAME" "${message//$'\r'/ }" >&2
}

wpm_die() {
  wpm_warn "$@"
  exit 1
}

# The single invocation point for the helper. Every filesystem transaction,
# every bounded read and every supervised child in all five scripts goes
# through here, so the interpreter flags are declared once:
#   -I  isolated mode -- ignores PYTHONPATH/PYTHONHOME, drops the script's own
#       directory and the user site-packages directory from sys.path, so a
#       file named json.py next to the helper cannot be imported instead of
#       the stdlib.
#   -B  no __pycache__ written beside the helper in the plugin directory.
wpm_cfg() {
  "$PYTHON3" -I -B "$WPM_HELPER" "$@"
}

# Map the helper's exit code onto this plugin's existing, unchanged codes
# (bin/wallpaper-monitor:34-35: EXIT_UNREADABLE=2, EXIT_LOCK=3; usage is 1).
# No user-visible exit code changes as a result of the migration.
#
#   0        success                                     -> return 0
#   1        boundary violation (symlink, not a regular
#            file, wrong owner, group/other-writable,
#            over budget, malformed, ELOOP, ENOTDIR)     -> EXIT_UNREADABLE
#   4        absent where presence was required          -> EXIT_UNREADABLE
#   5        --expect-dev-ino mismatch                   -> EXIT_UNREADABLE
#   6        output cap exceeded, group torn down        -> EXIT_UNREADABLE
#   3        transaction failed (revalidation mismatch,
#            filter non-zero, publish failed)            -> EXIT_LOCK
#   7        deadline exceeded, group torn down          -> EXIT_LOCK
#   2        usage -- OUR bug, not the user's            -> 1
#   128+N    killed by signal N                          -> EXIT_UNREADABLE
#
# 1/4/5/6 all mean NOTHING WAS CHANGED, which is precisely what
# EXIT_UNREADABLE promises. 3/7 mean the operation could not be completed or
# serialized, which is EXIT_LOCK's meaning.
#
# The `:-` defaults let bin/wp and bin/wallpaper-monitor-menu -- which do not
# define EXIT_UNREADABLE or EXIT_LOCK and run under `set -u` -- call this
# without inheriting bin/wallpaper-monitor's variables. The literals are the
# same two numbers.
#
# NOTE for callers: exit 4 must be intercepted BEFORE calling this wherever
# "does not exist yet" is legitimate (ensure_json_exists, and cmd_list's
# `existed` flag), so `list` on a missing config still prints
# "(no override configured yet ...)" and exits 0.
wpm_map_exit() {
  case "${1:-}" in
    0)       return 0 ;;
    1|4|5|6) exit "${EXIT_UNREADABLE:-2}" ;;
    3|7)     exit "${EXIT_LOCK:-3}" ;;
    2)       exit 1 ;;
    *)       exit "${EXIT_UNREADABLE:-2}" ;;
  esac
}

# Internal: resolve and freeze one or more tool names.
#   $1 = 1 for required (unresolvable is fatal), 0 for optional (unresolvable
#        leaves the variable empty and returns 0).
# Not exported and not part of the surface the five scripts code against; they
# call wpm_require / wpm_optional.
_wpm_resolve() {
  local required=$1; shift
  local name candidate picked rc
  local -a staged=() staged_names=()

  for name in "$@"; do
    # Idempotent: a name resolved by an earlier call is already readonly, so
    # reassigning it would be a hard error rather than a no-op.
    if [[ -n ${WPM_TOOL_RESOLVED[$name]:-} ]]; then
      if (( required )) && [[ -z ${!name:-} ]]; then
        wpm_die "$name: required, but it was already resolved as unavailable"
      fi
      continue
    fi
    if [[ -z ${WPM_TOOL_CANDIDATES[$name]:-} ]]; then
      # A typo in a call site, not a user-facing condition.
      wpm_die "$name: no candidate list is declared for this tool"
    fi

    # Pre-check with builtins only. `-f` follows symlinks deliberately:
    # /usr/bin/python3 IS a symlink on every supported distribution, and it is
    # check-tool -- not bash -- that decides whether following it is safe.
    # This pass only picks WHICH candidate to submit for validation.
    picked=""
    for candidate in ${WPM_TOOL_CANDIDATES[$name]}; do
      [[ -f $candidate && -x $candidate && -r $candidate ]] || continue
      picked=$candidate
      break
    done

    if [[ -z $picked ]]; then
      if (( required )); then
        wpm_die "$name: no usable executable found; tried:${WPM_TOOL_CANDIDATES[$name]// / }"
      fi
      export "$name="
      readonly "$name"
      WPM_TOOL_RESOLVED[$name]=1
      continue
    fi
    staged+=("$picked")
    staged_names+=("$name")
  done

  (( ${#staged[@]} )) || return 0

  # Authoritative validation, batched into ONE helper invocation: regular
  # file, executable, owner in {root, us}, no group/other write bit, and every
  # parent from / walked O_NOFOLLOW under the same ownership and mode rule --
  # none of which bash can test. A symlinked final component is followed for
  # at most 8 hops, re-validating the whole chain at each one.
  local -a args=()
  for candidate in "${staged[@]}"; do
    args+=(--path "$candidate")
  done
  if ! wpm_cfg check-tool "${args[@]}" >/dev/null; then
    # The batch says only THAT something failed. Re-check one at a time to
    # name the culprit -- the failure path is allowed to be slow, the success
    # path is the one that stays at a single helper spawn.
    local index=0
    for candidate in "${staged[@]}"; do
      if ! wpm_cfg check-tool --path "$candidate" >/dev/null 2>&1; then
        name=${staged_names[index]}
        wpm_die "$name: $candidate failed validation; tried:${WPM_TOOL_CANDIDATES[$name]// / }"
      fi
      index=$(( index + 1 ))
    done
    wpm_die "tool validation failed"
  fi

  local index=0
  for candidate in "${staged[@]}"; do
    name=${staged_names[index]}
    export "$name=$candidate"
    readonly "$name"
    WPM_TOOL_RESOLVED[$name]=1
    index=$(( index + 1 ))
  done
  return 0
}

# wpm_require TOOL...
#   Resolve each name from its fixed candidate list; the first candidate
#   passing the builtin pre-check wins; all winners are batch-validated by the
#   helper's check-tool. On failure: ONE bounded stderr line naming the tool
#   and every candidate path tried, then exit 1. There is NO PATH fallback.
#   Idempotent. Each resolved name becomes a readonly, exported variable.
wpm_require() {
  _wpm_resolve 1 "$@"
}

# wpm_optional TOOL...
#   Same resolution, but an unresolvable tool leaves the variable EMPTY and
#   returns 0. This is what preserves today's graceful degradation: `file`
#   falls back to the extension allowlist (bin/wallpaper-monitor:391-398),
#   `hyprctl` makes `list` print "(hyprctl not found)" (:659), and a missing
#   omarchy-shell is a warning rather than an aborted install
#   (install.sh:187-194). Callers test `[[ -n $FILE ]]` exactly where they test
#   `command -v file` today.
#
#   A candidate that EXISTS but fails validation is still fatal here, and that
#   is intended: "absent" is a supported configuration, "present but owned by
#   someone else or world-writable" is a finding.
wpm_optional() {
  _wpm_resolve 0 "$@"
}

# wpm_bounded MAX SECS -- cmd [args...]
#   A bounded, deadlined replacement for an unbounded `$(cmd ...)`. Prints the
#   child's stdout; returns non-zero if the child failed, exceeded MAX bytes,
#   or exceeded the deadline. Nothing is printed on failure.
#
#   F5's two call sites:
#     wpm_bounded "$WPM_MAX_HYPRCTL_BYTES" 5 -- "$HYPRCTL" monitors -j
#     wpm_bounded "$WPM_MAX_FILE_BYTES"    5 -- "$FILE" -b --mime-type -- "$img"
#
#   IMPLEMENTATION NOTE -- this is NOT `timeout ... | head -c`.
#   The design sketched it as a port of the reference's bounded_busctl(), i.e.
#   `timeout --foreground` piped into `head -c $((MAX+1))`. That shape is
#   consumer-side bounding, which the moderator rejected on the QML side for a
#   reason that applies identically here: by the time `head` truncates, the
#   producer has already produced, and a producer that never stops is never
#   stopped -- `head` closing the pipe only helps a program that checks its
#   write errors. It also leaves the killed pipeline's own children unreaped.
#
#   The helper's `run` subcommand does the job properly and already exists:
#   caps are checked as bytes arrive and a breach tears down the whole process
#   group (setsid + killpg TERM -> grace -> KILL -> waitpid to ECHILD), the
#   deadline reaps the same way, and argv[0] goes through check-tool before the
#   exec. As a bonus it removes `timeout` and `head -c` from the ambient-tool
#   surface entirely, which is the finding this file answers.
#
#   Over-cap is a hard failure (helper exit 6), never a silent truncation, so
#   callers can no longer mistake a prefix of hyprctl's JSON for all of it.
#   --max-line-bytes is raised to MAX because `hyprctl monitors -j` may emit
#   its whole payload on one line; the byte cap is the binding constraint.
wpm_bounded() {
  local max=${1:-} secs=${2:-}
  shift 2 2>/dev/null || { wpm_warn "wpm_bounded: MAX and SECS are required"; return 2; }
  if [[ ${1:-} != "--" ]]; then
    wpm_warn "wpm_bounded: expected '--' before the command"
    return 2
  fi
  shift
  if [[ $max != [1-9]*([0-9]) || $secs != [1-9]*([0-9]) ]]; then
    wpm_warn "wpm_bounded: MAX and SECS must be positive integers"
    return 2
  fi
  wpm_cfg run --setsid --stderr-to-null \
    --deadline-ms "$(( secs * 1000 ))" \
    --max-output-bytes "$max" \
    --max-line-bytes "$max" \
    -- "$@"
}

# `[[ $max != [1-9]*([0-9]) ]]` above needs extglob. Enabled here rather than
# left to the caller so the guard cannot silently degrade into a literal match.
shopt -s extglob

export -f wpm_warn wpm_die wpm_cfg wpm_map_exit wpm_require wpm_optional \
          wpm_bounded _wpm_resolve

# --- 7. Bootstrap the interpreter ----------------------------------------
# PYTHON3 must exist before anything else can be validated, since check-tool
# runs inside it. Resolving it here rather than in each script means a machine
# without python3 fails at the FIRST line of the install instead of halfway
# through, after shell.json has already been touched (install.sh:338 shells out
# to python3 today with no presence check at all, even though README.md:52
# already lists it as a dependency).
#
# The check-tool call below validates /usr/bin/python3 itself -- regular file,
# root-owned, not group/other-writable, every parent clean, symlink chain
# re-validated at each hop. It is partly self-referential (we run python3 to
# check python3) and is not claimed to be more than that; its real work is
# proving the PATH-independent absolute path we are about to freeze resolves to
# a safe binary, and the same one-line failure then covers jq, awk, hyprctl and
# the rest, where the check is not self-referential at all.
wpm_require PYTHON3
