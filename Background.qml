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
  // Portado do PR upstream #10249 (ver nota de credito abaixo) -- sem isso,
  // com AMBAS as telas em override (base.source ja Ready desde o inicio,
  // status nunca muda), finishingTransition nunca era limpo e
  // oldBackground/incomingBackground vazavam para sempre.
  function finishTransition() {
    if (!finishingTransition) return
    for (var i = 0; i < panels.length; i++) {
      if (!panels[i].baseReady) return
    }
    incomingBackground = ""
    oldBackground = ""
    finishingTransition = false
  }

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string perMonitorOverridePath: home + "/.config/omarchy/background-per-monitor.json"

  // Per-monitor overrides, com fallback por orientacao e validacao de caminho.
  // Portado do PR upstream #10249 (DCPRevere, omacom/omarchy,
  // https://github.com/omacom/omarchy/pull/10249) -- credito de origem para
  // a logica de selecao (equivalente a Wallpaper.js/select) e para o
  // rejectedSource (equivalente a WallpaperImage.qml) daquele PR. Adaptado
  // aqui para ler de background-per-monitor.json em vez de shell.json, e
  // para manter compatibilidade com o formato plano antigo (sem "monitors").
  //
  // Formato novo:
  //   { "monitors": { "DP-2": "/a.png" }, "portrait": "/v.png", "landscape": "/h.png" }
  // Formato antigo (ainda suportado): { "DP-2": "/a.png" }
  //
  // Precedencia: monitors[nome] > portrait/landscape (conforme height > width
  // pos-rotacao) > symlink nativo do Omarchy.
  property var backgroundConfig: ({})

  // Selecao pura de caminho, equivalente ao Wallpaper.js do PR upstream.
  // Valida: so aceita caminho absoluto ou "~/..." (expandido para o home);
  // qualquer outra coisa retorna "" e cai no fallback.
  function selectOverride(config, name, width, height) {
    if (!config || typeof config !== "object") return ""
    var monitors = config.monitors
    var isNewFormat = monitors && typeof monitors === "object"
    var map = isNewFormat ? monitors : config
    var value = Object.prototype.hasOwnProperty.call(map, name) ? map[name] : undefined
    if (value === undefined && isNewFormat) {
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

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: themeSwitchProc
    command: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\" >/dev/null 2>&1 &"]
    onExited: root.refreshBackground()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
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

      // Portado do PR upstream #10249: espelha o status do layer base (Ready
      // ou Error, ou seja "terminou de tentar carregar") para que
      // root.finishTransition() possa varrer todas as telas antes de limpar
      // incomingBackground/oldBackground -- ver comentario em root.finishTransition.
      readonly property bool baseReady: base.status === Image.Ready || base.status === Image.Error

      Component.onCompleted: {
        root.panels = root.panels.concat([panel])
        Qt.callLater(panel.maybeStartReveal)
      }
      Component.onDestruction: {
        root.panels = root.panels.filter(function(candidate) { return candidate !== panel })
        Qt.callLater(root.finishTransition)
      }
      onBaseReadyChanged: Qt.callLater(root.finishTransition)

      // Per-monitor override: este monitor mostra seu proprio wallpaper fixo,
      // resolvido a partir de background-per-monitor.json (nome do monitor,
      // depois orientacao), independente da outra tela e da transicao de tema
      // compartilhada abaixo. width/height aqui ja sao as dimensoes efetivas
      // pos-rotacao reportadas pelo Quickshell (HDMI-A-1 chega como 1080x1920
      // quando em retrato). Cai no symlink normal se nao houver override
      // aplicavel, ou se a imagem do override falhar ao carregar.
      readonly property string overridePath: root.selectOverride(root.backgroundConfig, modelData.name, width, height)

      // Guarda QUAL caminho de override falhou (em vez de um booleano burro
      // que travava ate reset manual). Se o override mudar para outro
      // arquivo, uma nova tentativa de carga acontece automaticamente --
      // ideia portada do rejectedSource em WallpaperImage.qml do PR upstream.
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

      Image {
        id: base
        anchors.fill: parent
        source: root.imageUrl(panel.baseSource)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        // Evita decodificar a imagem inteira em resolucao nativa (catalogo
        // tem PNG de ate 14MB / 8000px de largura) -- decodifica so no
        // tamanho que sera exibido. PreserveAspectCrop continua funcionando
        // normalmente com sourceSize definido.
        sourceSize.width: width
        sourceSize.height: height
        onStatusChanged: {
          if (status === Image.Error && panel.useOverride) {
            // Bad override path -- fall back to the normal symlink background,
            // mas so para este caminho especifico; se o JSON apontar para
            // outro arquivo depois, tenta de novo automaticamente.
            panel.rejectedOverridePath = panel.overridePath
          }
          // A limpeza de incomingBackground/oldBackground e centralizada em
          // root.finishTransition() (varre panel.baseReady em todas as
          // telas) -- ver onBaseReadyChanged acima. Isso corrige o caso em
          // que AMBAS as telas ja estao em override (status nunca muda aqui
          // porque a imagem ja estava Ready), o que antes deixava
          // finishingTransition travado em true para sempre.
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        source: root.imageUrl(root.oldBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: !panel.useOverride && root.oldBackground !== "" && root.revealProgress < 1
        onStatusChanged: panel.maybeStartReveal()
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
          source: root.imageUrl(root.incomingBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.maybeStartReveal()
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
        panel.rejectedOverridePath = ""
        Qt.callLater(function() {
          console.debug("vitorcanoas.background: screen=" + modelData.name +
            " overridePath=[" + panel.overridePath + "]" +
            " rejectedOverridePath=[" + panel.rejectedOverridePath + "]" +
            " useOverride=" + panel.useOverride +
            " width=" + width + " height=" + height)
        })
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
