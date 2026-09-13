import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Ui

Item {
  id: root

  property var panels: []

  // A fixed override may already be loaded when the theme transition ends.
  // Check all displays, including ones whose Image.status did not change.
  // Ported from upstream PR #10249 (see credit note below) -- without this,
  // with BOTH screens on override (base.source already Ready from the start,
  // status never changes), finishingTransition was never cleared and
  // oldBackground/incomingBackground leaked forever.
  function finishTransition() {
    if (!finishingTransition) return
    // Compact the list BEFORE scanning it. If a monitor is disconnected
    // during the transition, its entry may remain here as an already
    // destroyed object -- reading baseReady on it returns undefined, and
    // `!undefined` is true, which made this function return early FOREVER
    // (no future event re-triggers it, because onBaseReadyChanged only
    // exists on a live panel). Result: incomingBackground/oldBackground were
    // never cleared and the crossfade Images stayed decoded in VRAM until
    // the shell was restarted.
    // This is also the safety net against the lost-update between the
    // concat in Component.onCompleted and the filter in
    // Component.onDestruction.
    var alive = panels.filter(function(p) {
      return p !== null && p !== undefined && p.baseReady !== undefined
    })
    if (alive.length !== panels.length) panels = alive
    for (var i = 0; i < alive.length; i++) {
      if (!alive[i].baseReady) return
    }
    incomingBackground = ""
    oldBackground = ""
    finishingTransition = false
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  // Every file this component touches is named to the helper as a --root/--rel
  // PAIR, never as one pathname. The helper splits --rel itself and opens one
  // component at a time with O_NOFOLLOW, which is why it is given the parts
  // instead of a single path to resolve in one go. (currentBackgroundLink
  // above is the absolute spelling of the second pair, and it exists only to
  // be quoted in a log line -- nothing opens it.)
  readonly property string perMonitorOverrideRel: ".config/omarchy/background-per-monitor.json"
  readonly property string currentBackgroundRel: ".local/state/omarchy/current/background"

  // Per-monitor overrides, with fallback by orientation and path validation.
  // Ported from upstream PR #10249 (DCPRevere, omacom/omarchy,
  // https://github.com/omacom/omarchy/pull/10249) -- origin credit for the
  // selection logic (equivalent to Wallpaper.js/select) and for the
  // rejectedSource (equivalent to WallpaperImage.qml) from that PR. Adapted
  // here to read from background-per-monitor.json instead of shell.json, and
  // to keep compatibility with the old flat format (without "monitors").
  //
  // New format:
  //   { "monitors": { "DP-2": "/a.png" }, "portrait": "/v.png", "landscape": "/h.png" }
  // Old format (still supported): { "DP-2": "/a.png" }
  //
  // Precedence: monitors[name] > portrait/landscape (based on height > width
  // post-rotation) > Omarchy's native symlink.
  property var backgroundConfig: ({})

  // Pure path selection, equivalent to the upstream PR's Wallpaper.js. Only
  // validates: accepts an absolute path or "~/..." (expanded to home);
  // anything else returns "" and falls through to the fallback.
  function selectOverride(config, name, width, height) {
    if (!config || typeof config !== "object" || Array.isArray(config)) return ""
    var monitors = config.monitors
    var isNewFormat = monitors && typeof monitors === "object"
    var map = isNewFormat ? monitors : config
    var value = Object.prototype.hasOwnProperty.call(map, name) ? map[name] : undefined
    // The orientation fallback applies to BOTH formats. In the old flat
    // format ({"DP-2": "...", "portrait": "..."}) the orientation keys live
    // alongside the monitor names in the same object; previously the
    // fallback only ran with "monitors" present, and an old JSON with
    // "portrait" was silently ignored, contradicting the precedence
    // promised above.
    if (value === undefined) {
      value = config[height > width ? "portrait" : "landscape"]
    }
    if (typeof value !== "string") return ""
    if (value.indexOf("~/") === 0) value = root.home + value.slice(1)
    return value.charAt(0) === "/" ? value : ""
  }

  function loadPerMonitorOverrides(raw) {
    raw = String(raw || "").trim()
    if (!raw) {
      root.backgroundConfig = ({})
      return
    }
    try {
      var parsed = JSON.parse(raw)
      root.backgroundConfig = (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : ({})
    } catch (e) {
      console.warn("vitorcanoas.background: failed to parse background-per-monitor.json:", e)
      root.backgroundConfig = ({})
    }
  }

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function refreshBackground() {
    // The `running` guard is still here, but it is no longer the ONLY guard:
    // resolveLinkWatchdog terminates a wedged read, so a child that hangs can
    // no longer disable this path for the rest of the session.
    if (resolveLinkProc.running) return
    root.bpStart(resolveLinkProc, resolveLinkWatchdog,
                 root.helperEnvPrefix.concat(
                   [root.pythonBin, "-I", "-B", root.helperPath,
                    "resolve-link", "--root", root.home,
                    "--rel", root.currentBackgroundRel,
                    "--max-hops", "4", "--require-regular"]),
                 // resolve-link spawns nothing, so the helper has no deadline
                 // of its own for it; this watchdog is the only one.
                 8000)
  }

  function setBackground(path, instant) {
    transitionBackground("", path, path, instant, false)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    currentBackground = finalPath
    backgroundVersion += 1
    revealStartedVersion = -1

    revealAnimation.stop()
    finishingTransition = false

    if (instant || !displayedBackground) {
      oldBackground = ""
      incomingBackground = ""
      displayedBackground = path
      revealProgress = 1
      return
    }

    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    // Background polling can advance backgroundVersion while a theme switch is
    // pending; the latest theme payload should still apply.
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Color.loadColors(pendingColorsRaw)
    // Color.loadShell also refreshes Style so the type scale flips with the
    // background reveal instead of waiting for a separate reload path.
    Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  function startReveal(panel) {
    if (!incomingBackground) return
    panel.maskReady = true
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  function openSelector() {
    root.startSelector(bgSelectorProc, bgSelectorWatchdog,
                       root.omarchyBin + "/omarchy-theme-bg-switcher",
                       root.omarchyBin + "/omarchy-theme-bg-set")
  }

  function openThemeSwitcher() {
    root.startSelector(themeSelectorProc, themeSelectorWatchdog,
                       root.omarchyBin + "/omarchy-theme-switcher",
                       root.omarchyBin + "/omarchy-theme-set")
  }

  // Every command below is invoked by ABSOLUTE path, and nothing is handed to
  // a shell any more. The native omarchy.background plugin names these bare
  // and relies on $PATH; it can, because it ships as root-owned code under
  // /usr/share/omarchy. A community plugin is third-party code, so a
  // PATH-ordering trick or a shadowing binary in the session environment must
  // not be able to decide what this keep-loaded service executes.
  //
  // The two selectors used to run
  //   /usr/bin/bash -c 'x=$("$1"); [[ -n $x ]] && "$2" "$x"'
  // A command substitution buffers its producer's stdout with no limit at
  // all, inside a service that stays loaded for the whole session, and the
  // theme variant ended its script with `&`, which detached a grandchild this
  // process could never signal and nothing could ever reap.
  //
  // The unbounded substitution is gone outright. The QML-authored `&` is gone
  // too -- nothing this file writes detaches anything any more. What is NOT
  // gone, because it is not this file's to remove, is a grandchild that the
  // picker or the setter detaches on its own account. That one is covered by
  // a different mechanism, and only while the helper can run: QML's direct
  // child is now always the helper, and the helper is the supervisor -- own
  // session (--setsid), PR_SET_PDEATHSIG, a hard deadline, byte/line/
  // line-length budgets applied PRODUCER-side before a byte is forwarded,
  // then killpg(TERM) -> 1000 ms -> killpg(KILL) and waitpid to ECHILD. It is
  // the killpg that reaches a self-detached grandchild, and killpg runs in
  // the helper's SIGTERM handler, so the guarantee is exactly: QML signals
  // its own direct child and gives that child the time to tear its group
  // down. QML needs no process-group API of its own, but it does need never
  // to SIGKILL the helper before its handler has run -- see
  // Component.onDestruction.
  readonly property string envBin: "/usr/bin/env"
  readonly property string pythonBin: "/usr/bin/python3"
  readonly property string omarchyBin: "/usr/share/omarchy/bin"
  readonly property string sourceDir: root.localPath(Qt.resolvedUrl("."))
  readonly property string helperPath: root.sourceDir + "/bin/wallpaper-monitor-config.py"

  // file:// URL -> filesystem path. Same helper and same reason as the
  // approved reference (omarchy-nightlight/Panel.qml:48, :52-58): the helper
  // ships inside this plugin's own directory, so it is found without anything
  // being on PATH and without this file hardcoding an install location.
  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    while (value.length > 1 && value.charAt(value.length - 1) === "/")
      value = value.substring(0, value.length - 1)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  // ---- closed environment ------------------------------------------------
  //
  // Quickshell clears the environment before launching even /usr/bin/env,
  // preventing loader variables from affecting that first executable.
  readonly property var helperEnvPrefix: [root.envBin, "-i",
                                          "PATH=/usr/bin:/bin",
                                          "HOME=" + root.home,
                                          "LC_ALL=C", "LANG=C"]

  // The selector stages are different: they run Omarchy's own picker and
  // setter, which are GUI programs that must reach the compositor and the
  // session bus, and which call their own siblings by bare name. So the
  // environment is still closed, and what crosses it is forwarded BY NAME
  // from this fixed list. Nothing a hostile session variable could add gets
  // through unless it is named here, and nothing named here selects code:
  // no LD_*, no BASH_*, no PYTHON*, and PATH is set rather than forwarded.
  // /usr/share/omarchy/bin is appended because the omarchy-* scripts call
  // each other unqualified; it is root-owned distribution code, the same
  // trust as /usr/bin, unlike the session's own PATH which can contain
  // ~/.local/bin.
  readonly property string selectorPath: "PATH=/usr/bin:/bin:/usr/share/omarchy/bin"
  readonly property var sessionEnvNames: [
    "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE", "XDG_SESSION_DESKTOP",
    "XDG_CURRENT_DESKTOP", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS",
    "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_STATE_HOME", "XDG_CACHE_HOME",
    "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE",
    "DBUS_SESSION_BUS_ADDRESS",
    "USER", "LOGNAME", "LANG", "LC_ALL",
    "XCURSOR_THEME", "XCURSOR_SIZE"
  ]

  function selectorEnvPrefix() {
    var argv = [root.envBin, "-i", root.selectorPath, "HOME=" + root.home,
                "OMARCHY_PATH=/usr/share/omarchy"]
    for (var i = 0; i < root.sessionEnvNames.length; i++) {
      var name = root.sessionEnvNames[i]
      var value = Quickshell.env(name)
      if (value === undefined || value === null) continue
      value = String(value)
      if (value === "") continue
      argv.push(name + "=" + value)
    }
    return argv
  }

  // ---- bounded process supervision ---------------------------------------
  //
  // Ported from the approved Panel.qml: the caps and their SplitParser
  // consumption (241-324), the per-invocation watchdog and why it is armed on
  // launch rather than restarted from a poll (976-1063), and the TERM ->
  // 4000 ms -> KILL escalation (1029-1047). The shapes and the reasoning are
  // kept recognisable on purpose so the two files diff cleanly.
  //
  // StdioCollector is never used here. It retains the entire stream and only
  // hands it over at onStreamFinished, so a producer is unobserved for as
  // long as it keeps writing -- which is the consumer-only, full-buffer shape
  // that was rejected. SplitParser consumes line by line, and every line is
  // charged against a total-character, a line-count AND a line-length budget
  // BEFORE it is appended; a breach terminates the producer rather than
  // merely stopping the parse.
  //
  // The per-process state lives on each Process as bp* properties (bp for
  // "bounded process"); the prefix keeps them from ever colliding with a
  // property Quickshell's Process already has.

  function bpReset(proc) {
    proc.bpOutText = ""
    proc.bpOutChars = 0
    proc.bpOutLines = 0
    proc.bpErrText = ""
    proc.bpErrChars = 0
    proc.bpErrLines = 0
    proc.bpTooLarge = false
    proc.bpTimedOut = false
    proc.bpTermPending = false
    proc.bpCompleted = false
    proc.bpExit = -1
  }

  // Arm the watchdog on the launch that needs watching, and leave it alone
  // after that. Panel.qml:1049-1063 documents why restarting a watchdog from
  // a poll is the wrong shape: every poll pushed the deadline out ahead of a
  // hung process, forever, and the widget never recovered. Each timer here
  // belongs to ONE invocation -- started here, stopped when that invocation
  // completes -- so this restart() is the arming, not a renewal.
  function bpStart(proc, watchdog, argv, watchdogMs) {
    root.bpReset(proc)
    proc.command = argv
    watchdog.interval = watchdogMs
    watchdog.restart()
    proc.running = true
  }

  function bpNote(proc, line, isError) {
    var value = String(line || "")
    var lines = isError ? proc.bpErrLines : proc.bpOutLines
    var chars = isError ? proc.bpErrChars : proc.bpOutChars
    var added = value.length + (lines > 0 ? 1 : 0)
    if (value.length > proc.bpMaxLineChars || lines >= proc.bpMaxLines ||
        chars + added > proc.bpMaxChars) {
      proc.bpTooLarge = true
      root.bpTerminate(proc)
      return
    }
    if (isError) {
      if (proc.bpErrText === "") proc.bpErrText = value
      proc.bpErrChars = chars + added
      proc.bpErrLines = lines + 1
      return
    }
    proc.bpOutText += (lines > 0 ? "\n" : "") + value
    proc.bpOutChars = chars + added
    proc.bpOutLines = lines + 1
  }

  // signal(15) now, signal(9) after processKillTimer's 4000 ms. That 4000 is
  // load-bearing and must stay ABOVE the helper's own --kill-grace-ms (1000,
  // its DEFAULT_KILL_GRACE_MS): the helper has to finish escalating TERM ->
  // KILL across its whole process group and waitpid it to ECHILD before this
  // last-resort signal reaches the helper itself. Inverting that ordering is
  // precisely how grandchildren escape.
  //
  // Which is also why every deadline here is the HELPER's deadline plus a
  // margin (120000/125000 and 60000/65000) rather than the other way round:
  // the group teardown belongs to the helper, and this escalation is only the
  // backstop for a helper that is itself wedged. In that backstop case the
  // helper's own child still dies with it through PR_SET_PDEATHSIG, but a
  // grandchild of the picker would not -- one more reason the helper's
  // deadline must always be the one that fires first.
  function bpTerminate(proc) {
    if (!proc.running) return
    proc.bpTermPending = true
    proc.signal(15)
    processKillTimer.restart()
  }

  function bpFinish(proc, watchdog) {
    watchdog.stop()
    proc.bpTermPending = false
  }

  // true  -> a live process was terminated, so its completion will arrive
  //          from onExited and the caller must not complete it now.
  // false -> the process was already gone without delivering one (a failed
  //          spawn, or an exit that never reached us). The caller completes
  //          it immediately, because the old code's only guard was a
  //          `running` boolean and a process that vanished silently left that
  //          path disabled for the rest of the session.
  function bpWatchdogFired(proc, watchdog) {
    if (!proc.running) return false
    proc.bpTimedOut = true
    root.bpTerminate(proc)
    // A process that swallowed SIGTERM leaves `running` true. Re-arm short
    // so the escalation repeats instead of the timer stopping for good --
    // same recovery as Panel.qml:1015-1018.
    watchdog.interval = 5000
    watchdog.restart()
    return true
  }

  Timer {
    id: processKillTimer
    // 4000 > the helper's 1000 ms grace plus 2000 ms reap deadline -- see bpTerminate.
    interval: 4000
    repeat: false
    onTriggered: {
      var procs = [configReadProc, configStatProc, resolveLinkProc,
                   bgSelectorProc, themeSelectorProc]
      for (var i = 0; i < procs.length; i++) {
        if (procs[i].bpTermPending && procs[i].running) procs[i].signal(9)
        procs[i].bpTermPending = false
      }
    }
  }

  // ---- the config read ---------------------------------------------------
  //
  // This is what replaced FileView.text(). The helper's `read` does the whole
  // thing on descriptors: a per-component O_NOFOLLOW walk from $HOME, the
  // final open O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW (O_NONBLOCK is what
  // makes a FIFO fail instead of blocking this process forever), S_ISREG plus
  // owner plus group/other-writable validation on the opened fd, and an
  // incremental read that FAILS past the budget instead of truncating.
  property bool configReadQueued: false

  // The read is a child process now, so a change arriving while one is in
  // flight can neither be dropped (the in-flight read may predate it) nor
  // start a second child. Remember it and run it when the current one lands,
  // the way Panel.qml:236-239 handles the same problem.
  function scheduleConfigRead() {
    if (configReadProc.running) {
      root.configReadQueued = true
      return
    }
    root.configReadQueued = false
    root.bpStart(configReadProc, configReadWatchdog,
                 root.helperEnvPrefix.concat(
                   [root.pythonBin, "-I", "-B", root.helperPath,
                    "read", "--root", root.home, "--rel", root.perMonitorOverrideRel,
                    "--max-bytes", "262144", "--allow-missing"]),
                 // `read` spawns nothing, so the helper has no deadline of
                 // its own for it; this watchdog is the only one, and the
                 // helper's SIGTERM handler unwinds its finally blocks.
                 8000)
  }

  function completeConfigRead() {
    if (configReadProc.bpCompleted) return
    configReadProc.bpCompleted = true
    root.bpFinish(configReadProc, configReadWatchdog)
    var code = configReadProc.bpExit
    var bounded = !configReadProc.bpTimedOut && !configReadProc.bpTooLarge
    if (bounded && code === 0) {
      // Raw JSON, byte for byte what FileView.text() used to hand over, so
      // loadPerMonitorOverrides() and selectOverride() are untouched --
      // including the old flat format and "~/" expansion. A missing file is
      // --allow-missing's empty output, which loadPerMonitorOverrides already
      // turns into {}, exactly as onLoadFailed did.
      root.loadPerMonitorOverrides(configReadProc.bpOutText)
    } else if (bounded && (code === 1 || code === 4)) {
      // Failure modes that ALREADY EXIST today -- the file is missing,
      // unreadable, owned by someone else, group-writable, a symlink, a FIFO,
      // or over budget -- keep today's answer exactly: no overrides, every
      // screen falls back to the native wallpaper. This is what
      // FileView.onLoadFailed did.
      console.warn("vitorcanoas.background: background-per-monitor.json was refused (exit " +
                   code + "): " + (configReadProc.bpErrText || "no detail") +
                   " -- continuing with no overrides")
      root.backgroundConfig = ({})
    } else {
      // Failure modes that DO NOT exist today: a fork that failed, this
      // watchdog, a cap breach, a usage or internal error in the helper. A
      // FileView cannot fail to fork, so resetting every screen to the native
      // wallpaper here would be a regression introduced by the fix rather
      // than by anything the user did. Keep the previous config; the next
      // change signal reads again.
      console.warn("vitorcanoas.background: could not read background-per-monitor.json (exit " +
                   code + (configReadProc.bpTimedOut ? ", timed out" : "") +
                   (configReadProc.bpTooLarge ? ", over budget" : "") + "): " +
                   (configReadProc.bpErrText || "no detail") +
                   " -- keeping the previous overrides")
    }
    if (root.configReadQueued) Qt.callLater(root.scheduleConfigRead)
  }

  Process {
    clearEnvironment: true
    environment: ({})
    id: configReadProc
    property string bpOutText: ""
    property int bpOutChars: 0
    property int bpOutLines: 0
    property string bpErrText: ""
    property int bpErrChars: 0
    property int bpErrLines: 0
    property bool bpTooLarge: false
    property bool bpTimedOut: false
    property bool bpTermPending: false
    property bool bpCompleted: false
    property int bpExit: -1
    // 262144 is the helper's own MAX_FILE_BYTES, and --max-bytes may only
    // lower that ceiling, never raise it -- so the PRODUCER-side refusal is
    // the binding constraint and a larger file is refused, never truncated.
    // These mirror it consumer-side. The line-length and line-count budgets
    // are deliberately set so they cannot bind before the byte budget does: a
    // 256 KiB JSON written compactly is ONE line, so a smaller line cap would
    // reject a perfectly ordinary config. They are not forgotten caps, they
    // are the same cap expressed three ways.
    property int bpMaxChars: 262144
    property int bpMaxLines: 262144
    property int bpMaxLineChars: 262144
    stdout: SplitParser { onRead: function(line) { root.bpNote(configReadProc, line, false) } }
    stderr: SplitParser { onRead: function(line) { root.bpNote(configReadProc, line, true) } }
    onExited: function(exitCode) {
      configReadProc.bpExit = exitCode
      // Quickshell can deliver exited before the parser's last lines, so the
      // completion waits one event-loop turn (Panel.qml:258-261, :326-333).
      Qt.callLater(root.completeConfigRead)
    }
  }

  Timer {
    id: configReadWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (!root.bpWatchdogFired(configReadProc, configReadWatchdog)) root.completeConfigRead()
    }
  }

  // ---- the change watcher ------------------------------------------------
  //
  // This was a FileView pointed at the override JSON, with watchChanges: true
  // and reload() on completion and on every change. Removing the text()
  // CONSUMER did not remove the READ: a loaded FileView opens the path
  // itself, following symlinks, with no size cap and no type check, so a
  // symlink, an oversized file or a FIFO planted at
  // ~/.config/omarchy/background-per-monitor.json was still opened -- or
  // blocked on -- inside this keep-loaded shell process, whether or not
  // anything ever looked at the bytes. Watching the path never made that
  // read safe.
  //
  // So QML does not open this file at all any more. The change signal is a
  // poll of the helper's `stat`, which answers from
  // fstatat(AT_SYMLINK_NOFOLLOW) after the same per-component O_NOFOLLOW
  // walk from $HOME that `read` uses: it never opens the file, so it cannot
  // be redirected by a symlink and cannot block on a FIFO. Its whole answer
  // is compared against the previous one -- type, mode, uid, gid, size, dev,
  // ino, nlink and mtime_ns, a superset of the mtime_ns/size/ino that could
  // change on their own -- and any difference schedules the bounded,
  // no-follow `read` that is already the only thing that reads content.
  //
  // Why a poll rather than a filesystem-watcher type: a QML type or property
  // this Quickshell version does not have fails the WHOLE component at load,
  // which for this file means no wallpaper at all. Timer and Process are both
  // used by the approved reference (Panel.qml:938-940 and :968-972 for a
  // repeating Timer, :972 for triggeredOnStart, :627 for Process.running), so
  // this is built only out of constructs already proven in a shipped plugin.
  //
  // 2000 ms: this file changes only when a human runs the CLI or edits the
  // JSON by hand, so the poll is never on a latency-critical path -- but the
  // CLI promises the wallpaper updates without restarting the shell, and 2 s
  // keeps that promise feeling immediate. Each tick is one short-lived helper
  // that stats a single file and exits, and a tick is skipped outright while
  // the previous stat or a read is still in flight, so polls can never stack
  // up. triggeredOnStart is what replaces the FileView's
  // Component.onCompleted: reload() -- it performs the startup read, so a
  // JSON that already existed before the shell came up is still picked up.
  property string configIdentity: ""
  property bool configIdentitySeen: false

  function pollConfigIdentity() {
    if (configStatProc.running || configReadProc.running) return
    root.bpStart(configStatProc, configStatWatchdog,
                 root.helperEnvPrefix.concat(
                   [root.pythonBin, "-I", "-B", root.helperPath,
                    "stat", "--root", root.home,
                    "--rel", root.perMonitorOverrideRel, "--allow-missing"]),
                 // `stat` spawns nothing, so the helper has no deadline of
                 // its own for it; this watchdog is the only one.
                 8000)
  }

  function completeConfigStat() {
    if (configStatProc.bpCompleted) return
    configStatProc.bpCompleted = true
    root.bpFinish(configStatProc, configStatWatchdog)
    if (configStatProc.bpTimedOut || configStatProc.bpTooLarge) {
      // The stat itself misbehaved. Decide nothing, keep the last identity,
      // let the next tick retry -- a poll is not a verdict.
      return
    }
    var identity = ""
    if (configStatProc.bpExit === 0) {
      identity = String(configStatProc.bpOutText || "")
    } else if (configStatProc.bpExit === 1 || configStatProc.bpExit === 4) {
      // The path is refused at some component, or vanished under a mode the
      // helper will not answer for. That is still a state of the file, and
      // it is the `read` -- not this poll -- that decides what it means for
      // backgroundConfig, exactly as FileView.onLoadFailed used to hand over
      // to it. Giving the failure its own identity is what stops it from
      // scheduling a read on every tick while the state is unchanged. Real
      // output always begins with "type=", so the two can never collide.
      identity = "refused=" + configStatProc.bpExit
    } else {
      // A usage or internal error in the helper is a bug here, not a change
      // in the file. Do not turn it into a read.
      return
    }
    if (root.configIdentitySeen && identity === root.configIdentity) return
    root.configIdentity = identity
    root.configIdentitySeen = true
    root.scheduleConfigRead()
  }

  Process {
    clearEnvironment: true
    environment: ({})
    id: configStatProc
    property string bpOutText: ""
    property int bpOutChars: 0
    property int bpOutLines: 0
    property string bpErrText: ""
    property int bpErrChars: 0
    property int bpErrLines: 0
    property bool bpTooLarge: false
    property bool bpTimedOut: false
    property bool bpTermPending: false
    property bool bpCompleted: false
    property int bpExit: -1
    // `stat` prints nine short key=value lines, and the helper's own error
    // line is bounded by its MAX_MESSAGE_BYTES. These sit above both and far
    // below anything that could buffer.
    property int bpMaxChars: 4096
    property int bpMaxLines: 16
    property int bpMaxLineChars: 4096
    stdout: SplitParser { onRead: function(line) { root.bpNote(configStatProc, line, false) } }
    stderr: SplitParser { onRead: function(line) { root.bpNote(configStatProc, line, true) } }
    onExited: function(exitCode) {
      configStatProc.bpExit = exitCode
      Qt.callLater(root.completeConfigStat)
    }
  }

  Timer {
    id: configStatWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (!root.bpWatchdogFired(configStatProc, configStatWatchdog)) root.completeConfigStat()
    }
  }

  Timer {
    id: configWatchTimer
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.pollConfigIdentity()
  }

  // ---- the current-background link ---------------------------------------
  //
  // Was /usr/bin/readlink -f behind a StdioCollector. `resolve-link` answers
  // the same question without re-resolving the chain by pathname: each hop is
  // re-anchored under $HOME and walked one O_NOFOLLOW component at a time,
  // the hop count is bounded, and the answer is one bounded printable line.
  function completeResolveLink() {
    if (resolveLinkProc.bpCompleted) return
    resolveLinkProc.bpCompleted = true
    root.bpFinish(resolveLinkProc, resolveLinkWatchdog)
    if (resolveLinkProc.bpTimedOut || resolveLinkProc.bpTooLarge ||
        resolveLinkProc.bpExit !== 0) {
      console.warn("vitorcanoas.background: could not resolve " + root.currentBackgroundLink +
                   " (exit " + resolveLinkProc.bpExit +
                   (resolveLinkProc.bpTimedOut ? ", timed out" : "") +
                   (resolveLinkProc.bpTooLarge ? ", over budget" : "") + "): " +
                   (resolveLinkProc.bpErrText || "no detail"))
      return
    }
    root.setBackground(String(resolveLinkProc.bpOutText || "").trim(), false)
  }

  Process {
    clearEnvironment: true
    environment: ({})
    id: resolveLinkProc
    property string bpOutText: ""
    property int bpOutChars: 0
    property int bpOutLines: 0
    property string bpErrText: ""
    property int bpErrChars: 0
    property int bpErrLines: 0
    property bool bpTooLarge: false
    property bool bpTimedOut: false
    property bool bpTermPending: false
    property bool bpCompleted: false
    property int bpExit: -1
    // The helper caps a resolved path at 4096 bytes and prints exactly one
    // line; anything else is a bug or an attack, and either way it is capped.
    property int bpMaxChars: 4096
    property int bpMaxLines: 4
    property int bpMaxLineChars: 4096
    stdout: SplitParser { onRead: function(line) { root.bpNote(resolveLinkProc, line, false) } }
    stderr: SplitParser { onRead: function(line) { root.bpNote(resolveLinkProc, line, true) } }
    onExited: function(exitCode) {
      resolveLinkProc.bpExit = exitCode
      Qt.callLater(root.completeResolveLink)
    }
  }

  Timer {
    id: resolveLinkWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (!root.bpWatchdogFired(resolveLinkProc, resolveLinkWatchdog)) root.completeResolveLink()
    }
  }

  // ---- the two selectors -------------------------------------------------
  //
  // Stage 1 runs the picker, stage 2 applies what it printed. One Process
  // runs both in turn, reassigning `command` between them the way the
  // approved Panel.qml:626 does, so a selector still cannot run twice at once
  // and the background picker and the theme picker stay independent of each
  // other -- both exactly as before.
  function startSelector(proc, watchdog, pickerPath, setterPath) {
    if (proc.running) return
    proc.bpSetter = setterPath
    proc.bpStage = 1
    // 120 s for a human at a picker; the byte budget is the continuously
    // enforced control and the deadline is only the backstop.
    //
    // Stage 1's answer is CONSUMED, and selectorChoice() accepts exactly one
    // printable absolute line, so the budget IS the shape of the answer:
    // 4 lines, 4096 bytes. Anything past that is not a slow picker, it is a
    // picker answering something this will refuse anyway.
    root.bpSetCaps(proc, 4096, 4, 4096)
    root.bpStart(proc, watchdog,
                 root.selectorRunArgv(120000, 4096, 4, 4096, [pickerPath]), 125000)
  }

  // The consumer-side mirror of the helper's producer-side budget. The two
  // stages are budgeted differently and share one Process, so the caps are
  // assigned at each launch rather than fixed on the Process; the values on
  // the Process declarations are the stage-1 ones it starts life with.
  function bpSetCaps(proc, maxChars, maxLines, maxLineChars) {
    proc.bpMaxChars = maxChars
    proc.bpMaxLines = maxLines
    proc.bpMaxLineChars = maxLineChars
  }

  // The helper's `run` is the supervisor. --setsid gives the picker its own
  // session so the helper can killpg the WHOLE tree rather than one pid;
  // --kill-grace-ms is passed explicitly at the value the helper already
  // defaults to, so processKillTimer's 4000 can be read against it here
  // instead of in another file; --stderr-to-null sends the CHILD's stderr to
  // /dev/null (the helper's own single bounded error line still reaches the
  // journal), because an interactive picker's diagnostics are unbounded and
  // would otherwise have to be charged against a budget whose breach kills
  // the picker the user is looking at.
  //
  // The QML watchdog is always the helper's deadline plus a margin, so the
  // helper reaps its own group before QML gives up on the helper.
  function selectorRunArgv(deadlineMs, maxBytes, maxLines, maxLineBytes, childArgv) {
    return root.selectorEnvPrefix()
      .concat([root.pythonBin, "-I", "-B", root.helperPath,
               "run", "--setsid", "--stderr-to-null",
               "--deadline-ms", String(deadlineMs),
               "--kill-grace-ms", "1000",
               "--max-output-bytes", String(maxBytes),
               "--max-lines", String(maxLines),
               "--max-line-bytes", String(maxLineBytes),
               "--"])
      .concat(childArgv)
  }

  // The old script tested only `[[ -n $background ]]`, so whatever the picker
  // printed became the setter's argument. One line, printable, absolute.
  function selectorChoice(raw, theme) {
    var value = String(raw || "").trim()
    if (value === "" || value.length > 4096) return ""
    if (value.indexOf("\n") >= 0) return ""
    if (theme) {
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value) || value.indexOf("..") >= 0) return ""
    } else if (value.charAt(0) !== "/") return ""
    for (var i = 0; i < value.length; i++) {
      var code = value.charCodeAt(i)
      if (code < 0x20 || code === 0x7f) return ""
    }
    return value
  }

  function completeSelector(proc, watchdog) {
    if (proc.bpCompleted) return
    proc.bpCompleted = true
    root.bpFinish(proc, watchdog)
    var stage = proc.bpStage
    proc.bpStage = 0
    var ok = !proc.bpTimedOut && !proc.bpTooLarge && proc.bpExit === 0
    if (!ok) {
      console.warn("vitorcanoas.background: selector stage " + stage + " failed (exit " +
                   proc.bpExit + (proc.bpTimedOut ? ", timed out" : "") +
                   (proc.bpTooLarge ? ", over budget" : "") + "): " +
                   (proc.bpErrText || "no detail"))
    }
    if (stage === 1) {
      var choice = ok ? root.selectorChoice(proc.bpOutText, proc.bpSetter === root.omarchyBin + "/omarchy-theme-set") : ""
      if (choice !== "") {
        proc.bpStage = 2
        // Stage 2 is budgeted DIFFERENTLY from stage 1, on purpose.
        //
        // Nothing consumes stage 2's output -- look below: completeSelector
        // falls straight through to refreshBackground() and never reads
        // bpOutText for stage 2. So a tight budget here buys no validation at
        // all; it is purely a tripwire, and tripping it means EXIT_OUTPUT_CAP
        // and a killpg in the MIDDLE of omarchy-theme-set, which sets
        // symlinks, rewrites configs and restarts several daemons as it goes.
        // A half-applied theme is a worse outcome than a few kilobytes of
        // discarded chatter, and the thing item 4 actually asks for -- a
        // bound, enforced producer-side, on a keep-loaded service -- is just
        // as true at 64 KiB as at 4 KiB.
        //
        // These three numbers are the helper's OWN defaults for `run`
        // (DEFAULT_MAX_OUTPUT_BYTES 65536, DEFAULT_MAX_LINES 4096,
        // DEFAULT_MAX_LINE_BYTES 8192), so this is not a number invented
        // here: it is the bound the supervisor already considers safe,
        // spelled out rather than left implicit.
        //
        // 60 s rather than 30 s for the same reason. The deadline is the
        // backstop, not the control, and the cost of it firing is again a
        // half-applied theme. omarchy-theme-set restarts waybar, mako and
        // friends and can regenerate caches on a first switch; 30 s was a
        // guess made on a machine that cannot run it. 60 s is still a bound,
        // and the QML watchdog stays above it at 65 s so the helper is always
        // the one that reaps its own group.
        root.bpSetCaps(proc, 65536, 4096, 8192)
        root.bpStart(proc, watchdog,
                     root.selectorRunArgv(60000, 65536, 4096, 8192,
                                          [proc.bpSetter, choice]), 65000)
        return
      }
      // Nothing usable was picked -- the user cancelled, or the picker
      // printed something this will not hand on. The old `[[ -n $x ]]` test
      // failing did exactly this: no setter ran.
    }
    // The single refresh the one bash process used to fire from its single
    // onExited, still fired exactly once per selector run.
    root.refreshBackground()
  }

  Process {
    clearEnvironment: true
    environment: ({})
    id: bgSelectorProc
    property string bpOutText: ""
    property int bpOutChars: 0
    property int bpOutLines: 0
    property string bpErrText: ""
    property int bpErrChars: 0
    property int bpErrLines: 0
    property bool bpTooLarge: false
    property bool bpTimedOut: false
    property bool bpTermPending: false
    property bool bpCompleted: false
    property int bpExit: -1
    property int bpStage: 0
    property string bpSetter: ""
    // The stage-1 budget; bpSetCaps reassigns these at every launch, so
    // stage 2 runs under the wider one. Both mirror the helper's
    // producer-side budget for that stage exactly.
    property int bpMaxChars: 4096
    property int bpMaxLines: 4
    property int bpMaxLineChars: 4096
    stdout: SplitParser { onRead: function(line) { root.bpNote(bgSelectorProc, line, false) } }
    stderr: SplitParser { onRead: function(line) { root.bpNote(bgSelectorProc, line, true) } }
    onExited: function(exitCode) {
      bgSelectorProc.bpExit = exitCode
      Qt.callLater(root.completeBgSelector)
    }
  }

  function completeBgSelector() {
    root.completeSelector(bgSelectorProc, bgSelectorWatchdog)
  }

  Timer {
    id: bgSelectorWatchdog
    interval: 125000
    repeat: false
    onTriggered: {
      if (!root.bpWatchdogFired(bgSelectorProc, bgSelectorWatchdog)) root.completeBgSelector()
    }
  }

  Process {
    clearEnvironment: true
    environment: ({})
    id: themeSelectorProc
    property string bpOutText: ""
    property int bpOutChars: 0
    property int bpOutLines: 0
    property string bpErrText: ""
    property int bpErrChars: 0
    property int bpErrLines: 0
    property bool bpTooLarge: false
    property bool bpTimedOut: false
    property bool bpTermPending: false
    property bool bpCompleted: false
    property int bpExit: -1
    property int bpStage: 0
    property string bpSetter: ""
    // Stage-1 budget; bpSetCaps widens these for stage 2. See startSelector.
    property int bpMaxChars: 4096
    property int bpMaxLines: 4
    property int bpMaxLineChars: 4096
    stdout: SplitParser { onRead: function(line) { root.bpNote(themeSelectorProc, line, false) } }
    stderr: SplitParser { onRead: function(line) { root.bpNote(themeSelectorProc, line, true) } }
    onExited: function(exitCode) {
      themeSelectorProc.bpExit = exitCode
      Qt.callLater(root.completeThemeSelector)
    }
  }

  function completeThemeSelector() {
    root.completeSelector(themeSelectorProc, themeSelectorWatchdog)
  }

  Timer {
    id: themeSelectorWatchdog
    interval: 125000
    repeat: false
    onTriggered: {
      if (!root.bpWatchdogFired(themeSelectorProc, themeSelectorWatchdog)) root.completeThemeSelector()
    }
  }

  // Target is intentionally "background", the SAME target the native
  // omarchy.background plugin uses -- even though omarchy.background is
  // listed in shell.json's disabledPlugins (and quickshell logs a benign
  // "Handler was registered but will not be used" warning about it, since
  // the disabled plugin's own IpcHandler never actually runs). This is load
  // bearing, not a leftover: Omarchy's own CLI drives the shell through IPC
  // on this exact target --
  //   /usr/share/omarchy/bin/omarchy-theme-bg-set -> `omarchy-shell -q background set "$BACKGROUND"`
  //   /usr/share/omarchy/bin/omarchy-theme-set    -> `shell_ipc background themeTransition ...`
  // -- so `omarchy theme bg set` and `omarchy theme set` (theme switching,
  // with the cross-fade) both call target "background" with no way to point
  // them at a plugin-specific target instead. Renaming this to e.g.
  // "background-per-monitor" would silently break both commands: they would
  // keep exiting 0 (fire-and-forget IPC) while the on-screen wallpaper never
  // updates. Kept as "background" on purpose; the log line is cosmetic
  // noise from the disabled plugin, not a real conflict.
  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      if (root.incomingBackground) {
        root.displayedBackground = root.currentBackground || root.incomingBackground
        root.finishingTransition = true
        Qt.callLater(root.finishTransition)
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: refreshBackground()

  // SIGTERM, and deliberately NOTHING ELSE.
  //
  // This used to send signal(15) and then signal(9) on the very next
  // statement, and that is not a faster version of the same thing -- it is a
  // different and worse outcome. Measured against this plugin's own helper,
  // `run --setsid -- bash -c 'sleep 300 & sleep 300'`:
  //
  //   TERM then KILL back to back -> helper rc=137, direct child dead,
  //                                  GRANDCHILD ALIVE (state=S)
  //   TERM alone                   -> helper rc=143, direct child dead,
  //                                  GRANDCHILD DEAD
  //
  // The reason is that the whole-group teardown lives in the helper's SIGTERM
  // handler (killpg(TERM) -> 1000 ms -> killpg(KILL) -> waitpid to ECHILD).
  // SIGKILL cannot be handled, so a SIGKILL arriving before that handler has
  // run means killpg never happens at all. PR_SET_PDEATHSIG does not cover
  // the gap: the helper's own docstring says it reaches only the DIRECT
  // child, so the picker's grandchildren -- anything the picker or the setter
  // detached for itself -- survive orphaned.
  //
  // Escalation is not skipped out of optimism, it is skipped because there is
  // nowhere to wait. Everywhere else in this file the escalation is TERM ->
  // processKillTimer's 4000 ms -> KILL, and the 4000 deliberately exceeds the
  // helper's 1000 ms grace (see bpTerminate). A timer cannot fire during
  // destruction, so the only two options here are "TERM and give the helper
  // its grace" or "TERM immediately followed by KILL", and the second is the
  // one demonstrated to leave a process behind. processKillTimer is stopped
  // for the same reason: a KILL already armed by an in-flight bpTerminate
  // would land in exactly that window.
  //
  // What this therefore guarantees, and no more: every direct child is
  // signalled SIGTERM, and each helper that is still able to run its handler
  // tears its own group down. A helper already wedged past signals is not
  // reached by this -- that case belongs to its own --deadline-ms, which is
  // always set below the matching QML watchdog for that reason.
  Component.onDestruction: {
    configReadWatchdog.stop()
    configStatWatchdog.stop()
    configWatchTimer.stop()
    resolveLinkWatchdog.stop()
    bgSelectorWatchdog.stop()
    themeSelectorWatchdog.stop()
    processKillTimer.stop()
    var procs = [configReadProc, configStatProc, resolveLinkProc,
                 bgSelectorProc, themeSelectorProc]
    for (var i = 0; i < procs.length; i++) {
      if (!procs[i].running) continue
      procs[i].signal(15)
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. The wallpaper
      // itself is static, so this favors correctness over a small render-loop
      // optimization.
      updatesEnabled: true

      property bool maskReady: false

      // Ported from upstream PR #10249: mirrors the base layer's status
      // (Ready or Error, i.e. "finished trying to load") so that
      // root.finishTransition() can scan all screens before clearing
      // incomingBackground/oldBackground -- see the comment on
      // root.finishTransition.
      readonly property bool baseReady: base.status === Image.Ready || base.status === Image.Error

      Component.onCompleted: {
        root.panels = root.panels.concat([panel])
        Qt.callLater(panel.maybeStartReveal)
      }
      Component.onDestruction: {
        // This filter and the concat in Component.onCompleted are both
        // read-modify-write operations on root.panels: on a dock/undock with
        // two monitors in the same tick, the concat can overwrite the
        // filter and put a dead panel back into the list. This is
        // TOLERATED on purpose -- root.finishTransition() compacts the list,
        // discarding destroyed entries before scanning it, and that
        // compaction is the safety net. Do not "optimize" the compaction
        // over there thinking this filter alone is enough: it is not.
        root.panels = root.panels.filter(function(candidate) { return candidate !== panel })
        Qt.callLater(root.finishTransition)
      }
      onBaseReadyChanged: Qt.callLater(root.finishTransition)

      // Per-monitor override: this monitor shows its own fixed wallpaper,
      // resolved from background-per-monitor.json (monitor name, then
      // orientation), independent of the other screen and of the shared
      // theme transition below. width/height here are already the effective
      // post-rotation dimensions reported by Quickshell (HDMI-A-1 arrives as
      // 1080x1920 when in portrait). Falls back to the normal symlink if
      // there is no applicable override, or if the override image fails to
      // load.
      readonly property string overridePath: root.selectOverride(root.backgroundConfig, modelData.name, width, height)

      // Tracks WHICH override path failed (instead of a dumb boolean that
      // stayed stuck until a manual reset). If the override changes to a
      // different file, a fresh load attempt happens automatically -- idea
      // ported from rejectedSource in the upstream PR's WallpaperImage.qml.
      property string rejectedOverridePath: ""

      function maybeStartReveal() {
        if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
        if (incomingFrame.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
          if (incomingFrame.status !== Image.Ready) return
          root.startReveal(panel)
        })
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // Effective source for the plain (non-transitioning) base layer: the
      // per-monitor override when present and not the one that just failed,
      // otherwise the normal symlink-driven background.
      readonly property bool useOverride: panel.overridePath !== "" && panel.rejectedOverridePath !== panel.overridePath
      readonly property string baseSource: panel.useOverride ? panel.overridePath : root.displayedBackground

      // The plugin's validation signal, and the only reliable one: the
      // onOverridePathChanged log fires DURING the overridePath change,
      // before useOverride re-evaluates downstream, so there it still reads
      // the previous value (typically false on the first frame) -- which
      // already caused a false regression alarm. Here the value is the
      // final one.
      //   journalctl --user -t omarchy-shell | grep useOverride=
      onUseOverrideChanged: console.debug("vitorcanoas.background: screen=" + modelData.name +
        " useOverride=" + panel.useOverride +
        " source=[" + panel.baseSource + "]")

      // Decode size quantized by the SCREEN, not the window. Window geometry
      // changes on rotation/hotplug, and QQuickPixmapCache treats
      // (url, sourceSize) as a distinct cache key: tying sourceSize to
      // width/height forced a full re-decode of the image (an 8000px PNG,
      // ~144MB transient) on every geometry change. modelData is the
      // ShellScreen and already reports POST-rotation dimensions (HDMI-A-1
      // arrives as 1080x1920 in portrait), so this value stays correct.
      readonly property int decodeWidth: modelData.width > 0 ? modelData.width : width
      readonly property int decodeHeight: modelData.height > 0 ? modelData.height : height

      Image {
        id: base
        anchors.fill: parent
        source: root.imageUrl(panel.baseSource)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // Avoids decoding the whole image at native resolution (the
        // catalogue has PNGs up to 14MB / 8000px wide) -- only decodes at
        // the size it will be displayed at. PreserveAspectCrop still works
        // normally with sourceSize set.
        sourceSize.width: panel.decodeWidth
        sourceSize.height: panel.decodeHeight
        onStatusChanged: {
          if (status === Image.Error && panel.useOverride) {
            // Bad override path -- fall back to the normal symlink
            // background, but only for this specific path; if the JSON
            // points to another file later, it retries automatically.
            panel.rejectedOverridePath = panel.overridePath
          }
          // Cleanup of incomingBackground/oldBackground is centralized in
          // root.finishTransition() (scans panel.baseReady across all
          // screens) -- see onBaseReadyChanged above. This fixes the case
          // where BOTH screens are already on override (status never
          // changes here because the image was already Ready), which used
          // to leave finishingTransition stuck at true forever.
        }
      }

      // Crossfade layers. Two VRAM fixes here:
      //
      // 1. `visible: false` prevents RENDERING, not LOADING -- an Image with
      //    a valid source decodes regardless. With useOverride on (the case
      //    on this machine, both screens on override) this meant four
      //    full-res decodes per theme switch that displayed no pixel at all.
      //    Zeroing the source is the only way to avoid paying for them.
      //    Expected and SAFE side effect: with an empty source the status
      //    becomes Image.Null, maybeStartReveal() never sees Image.Ready and
      //    startReveal() -- hence applyPendingTheme() -- does not run
      //    through this path. The theme still applies because
      //    setPendingTheme() arms pendingThemeFallbackTimer (300ms) and
      //    onTriggered calls applyPendingTheme() unconditionally. With both
      //    screens on override, that timer is ALREADY the only path that
      //    applies the theme in production today, so this does not change
      //    production behavior.
      //
      // 2. sourceSize avoids decoding at native resolution (~192MB per layer
      //    with the catalogue's large PNGs). With sourceSize set there is no
      //    minification to filter, so mipmapping loses its purpose and only
      //    costs ~33% extra texture memory -- removed; smooth stays on.
      Image {
        id: oldFrame
        anchors.fill: parent
        source: panel.useOverride ? "" : root.imageUrl(root.oldBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        sourceSize.width: panel.decodeWidth
        sourceSize.height: panel.decodeHeight
        visible: !panel.useOverride && root.oldBackground !== "" && root.revealProgress < 1
        onStatusChanged: {
          if (status === Image.Error) {
            // The theme's file disappeared mid-transition. Without this the
            // reveal aborts silently: revealProgress gets stuck at 0 and the
            // screen freezes on the OLD wallpaper with the new colors
            // already applied. Unblock the crossfade.
            console.warn("vitorcanoas.background: oldFrame failed to load [" +
              root.oldBackground + "] on screen " + modelData.name + " -- unblocking reveal")
            root.revealProgress = 1
          }
          panel.maybeStartReveal()
        }
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: !panel.useOverride && root.incomingBackground !== "" && incomingFrame.status === Image.Ready && (root.revealProgress >= 1 || panel.maskReady)
        layer.enabled: !panel.useOverride && root.incomingBackground !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          source: panel.useOverride ? "" : root.imageUrl(root.incomingBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          sourceSize.width: panel.decodeWidth
          sourceSize.height: panel.decodeHeight
          onStatusChanged: {
            if (status === Image.Error) {
              console.warn("vitorcanoas.background: incomingFrame failed to load [" +
                root.incomingBackground + "] on screen " + modelData.name + " -- unblocking reveal")
              root.revealProgress = 1
            }
            panel.maybeStartReveal()
          }
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      // A fresh override path (new JSON content, or the file being cleared)
      // always gets a fresh load attempt.
      onOverridePathChanged: {
        // Log the state BEFORE the reset. The log used to be inside a
        // Qt.callLater that only ran after this assignment -- and, being
        // event-coalesced, on a hotplug it always printed
        // rejectedOverridePath=[] even when an override had just failed,
        // hiding exactly the information one wanted to diagnose.
        console.debug("vitorcanoas.background: screen=" + modelData.name +
          " overridePath=[" + panel.overridePath + "]" +
          " rejectedOverridePath(before reset)=[" + panel.rejectedOverridePath + "]" +
          // useOverride is the signal used to validate the plugin in
          // production (`journalctl --user -t omarchy-shell | grep
          // useOverride`). Read here, before the reset below, it is
          // consistent with the rejectedOverridePath on the same line --
          // both describe the same instant.
          " useOverride=" + panel.useOverride +
          // width/height are the WINDOW's and on the first frame still equal
          // 500x500 (pre-layout); screen= is the effective post-rotation
          // geometry, which is what decides orientation and the decode
          // sourceSize.
          " width=" + width + " height=" + height +
          " screen=" + panel.decodeWidth + "x" + panel.decodeHeight)
        // Load-bearing: a new override path (changed JSON, or a cleared
        // file) always deserves a clean load attempt.
        panel.rejectedOverridePath = ""
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
