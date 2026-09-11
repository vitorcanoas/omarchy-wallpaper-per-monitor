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
  readonly property string perMonitorOverridePath: home + "/.config/omarchy/background-per-monitor.json"

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

  FileView {
    id: perMonitorOverrideFile
    path: root.perMonitorOverridePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      console.debug("vitorcanoas.background: perMonitorOverrideFile onLoaded, text length=" + text().length)
      root.loadPerMonitorOverrides(text())
    }
    // Re-read on change (including first creation) before loading -- text()
    // is stale in the change signal itself, so route both paths through
    // reload() -> onLoaded to always parse fresh content.
    onFileChanged: reload()
    onLoadFailed: function(error) {
      console.debug("vitorcanoas.background: perMonitorOverrideFile onLoadFailed, error=" + error)
      root.loadPerMonitorOverrides("")
    }
    // FileView does not load on its own at startup -- without an explicit
    // reload() here, onLoaded only fires on a subsequent external change,
    // leaving backgroundConfig stuck at {} for the whole session if the
    // JSON already existed before the shell came up.
    Component.onCompleted: reload()
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
    if (!readlinkProc.running) readlinkProc.running = true
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
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  // Every command below is invoked by ABSOLUTE path, and the two that need a
  // shell pass the helper paths in as argv rather than naming them inside the
  // script. The native omarchy.background plugin names these bare and relies
  // on $PATH; it can, because it ships as root-owned code under
  // /usr/share/omarchy. A community plugin is third-party code, so a
  // PATH-ordering trick or a shadowing binary in the session environment must
  // not be able to decide what this keep-loaded service executes.
  readonly property string shBin: "/usr/bin/bash"
  readonly property string readlinkBin: "/usr/bin/readlink"
  readonly property string omarchyBin: "/usr/share/omarchy/bin"

  Process {
    id: bgSwitchProc
    // "$1"/"$2" are the switcher and setter, passed as arguments after the
    // inline script, so the script text contains no command name to resolve.
    command: [root.shBin, "-c",
              "background=$(\"$1\"); [[ -n $background ]] && \"$2\" \"$background\"",
              "bgswitch",
              root.omarchyBin + "/omarchy-theme-bg-switcher",
              root.omarchyBin + "/omarchy-theme-bg-set"]
    onExited: root.refreshBackground()
  }

  Process {
    id: themeSwitchProc
    command: [root.shBin, "-c",
              "theme=$(\"$1\"); [[ -n $theme ]] && \"$2\" \"$theme\" >/dev/null 2>&1 &",
              "themeswitch",
              root.omarchyBin + "/omarchy-theme-switcher",
              root.omarchyBin + "/omarchy-theme-set"]
    onExited: root.refreshBackground()
  }

  Process {
    id: readlinkProc
    command: [root.readlinkBin, "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
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
