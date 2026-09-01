import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Carousel indicator for the scrolling layout: one pip per column on the
// focused workspace, elongated on the column that owns focus. Columns that
// stack several windows split their pip into one segment per window, so the
// widget maps the workspace instead of only counting it.
BarWidget {
  id: root
  moduleName: "dbrownell.window-position"

  // Mirrors `name` in manifest.json. The hover popup titles itself with this,
  // so a bubble that opens under a row of anonymous pips says what drew it.
  readonly property string pluginName: "Window position"

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string style: String(setting("style", "pips"))
  readonly property int maxPips: Math.max(1, Number(setting("maxPips", 12)))
  readonly property int maxDwindleWindows: Math.max(1, Number(setting("maxDwindleWindows", 6)))
  readonly property int pollInterval: Math.max(100, Number(setting("pollInterval", 250)))

  // Bumped on every refresh so one counter drives the whole recompute, even
  // when Hyprland hands back a client list that QML sees as unchanged.
  property int revision: 0

  readonly property var layout: computeLayout(revision)
  readonly property int columnCount: layout.columns.length
  readonly property int activeColumn: layout.activeColumn
  readonly property int activeIndex: layout.activeIndex
  readonly property int windowCount: layout.windowCount
  readonly property string focusedAddress: layout.focusedAddress
  readonly property bool floatingFocus: layout.floatingFocus
  readonly property string tiledLayout: layout.tiledLayout
  readonly property string workspaceName: layout.workspaceName

  // Dwindle nests windows rather than lining them up, so a busy workspace
  // folds into a few columns holding many windows each -- and a pip only has
  // pipThickness to divide between them, so the segments shrink below a pixel
  // long before the column count reaches maxPips. Past this many windows the
  // count is the only part still legible, so show it on its own.
  readonly property bool crowdedDwindle: tiledLayout === "dwindle"
    && windowCount > maxDwindleWindows

  // An empty workspace still gets a strip -- one dim placeholder pip -- so the
  // widget holds its place in the bar instead of blinking out and shoving its
  // neighbours around every time the last window closes.
  readonly property bool showPips: columnCount <= maxPips
    && !crowdedDwindle && style !== "counter"
  readonly property bool showCounter: style !== "pips"
    || columnCount > maxPips || crowdedDwindle

  // ------------------------------------------------------------------ model

  // Windows share a column when their left edges line up. Hyprland reports
  // fractional positions mid-animation, so bucket on a tolerance rather than
  // an exact match.
  readonly property int columnTolerance: 24

  // Everything is read out of one hyprctl client list, which carries geometry
  // and focusHistoryID together. Taking focus from the same snapshot as the
  // positions keeps the two from disagreeing, and unlike Hyprland.activeToplevel
  // it is populated on the first refresh -- that property stays null until an
  // activewindow event arrives, so a freshly started shell has no focus at all.
  function computeLayout(serial) {
    var focused = null
    var clients = []

    var values = Hyprland.toplevels.values
    for (var i = 0; i < values.length; i++) {
      var ipc = values[i].lastIpcObject
      if (!ipc || !ipc.workspace) continue
      if (ipc.focusHistoryID === 0) focused = ipc
      clients.push(ipc)
    }

    // The workspace on screen, not the one owning the focused window. The two
    // part company the moment you switch to an empty workspace: nothing there
    // can take focus, so the window you left behind keeps focusHistoryID 0 --
    // and reading focus first would leave the strip mapping the old workspace.
    var workspaceId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id
      : (focused ? focused.workspace.id : null)

    // Focus that sits on another workspace is not this workspace's focus.
    if (focused && focused.workspace.id !== workspaceId) focused = null

    // Layout is a per-workspace property in Hyprland -- omarchy's
    // workspace-layout toggle writes a workspace rule, so the answer differs
    // between workspaces and cannot be read once from general:layout.
    var tiledLayout = ""
    var workspaceName = workspaceId === null ? "" : String(workspaceId)
    var workspaces = Hyprland.workspaces.values
    for (var ws = 0; ws < workspaces.length; ws++) {
      if (workspaces[ws].id !== workspaceId) continue
      var meta = workspaces[ws].lastIpcObject
      if (meta && meta.tiledLayout) tiledLayout = String(meta.tiledLayout)
      if (meta && meta.name) workspaceName = String(meta.name)
      break
    }

    var focusedAddress = focused && !focused.floating ? String(focused.address || "") : ""
    var empty = {
      columns: [], activeColumn: -1, activeIndex: -1, windowCount: 0,
      focusedAddress: focusedAddress,
      floatingFocus: focused ? focused.floating === true : false,
      tiledLayout: tiledLayout,
      workspaceName: workspaceName
    }
    if (workspaceId === null) return empty

    var tiled = []
    for (var c = 0; c < clients.length; c++) {
      var client = clients[c]
      if (client.workspace.id !== workspaceId) continue
      if (client.floating || client.mapped === false || client.hidden) continue

      var at = client.at
      tiled.push({
        address: String(client.address || ""),
        title: String(client.title || client["class"] || ""),
        x: at ? Number(at[0]) : 0,
        y: at ? Number(at[1]) : 0
      })
    }
    if (tiled.length === 0) return empty

    tiled.sort(function(left, right) {
      return left.x !== right.x ? left.x - right.x : left.y - right.y
    })

    var columns = []
    for (var t = 0; t < tiled.length; t++) {
      var window = tiled[t]
      var last = columns.length > 0 ? columns[columns.length - 1] : null
      if (last && Math.abs(window.x - last.x) <= root.columnTolerance) last.windows.push(window)
      else columns.push({ x: window.x, windows: [window] })
    }

    var activeColumn = -1
    var activeIndex = -1
    var seen = 0
    for (var col = 0; col < columns.length; col++) {
      var windows = columns[col].windows
      for (var w = 0; w < windows.length; w++) {
        if (focusedAddress !== "" && windows[w].address === focusedAddress) {
          activeColumn = col
          activeIndex = seen
        }
        seen++
      }
    }

    return {
      columns: columns,
      activeColumn: activeColumn,
      activeIndex: activeIndex,
      windowCount: tiled.length,
      focusedAddress: focusedAddress,
      floatingFocus: empty.floatingFocus,
      tiledLayout: tiledLayout,
      workspaceName: workspaceName
    }
  }

  function pipLengthAt(index) {
    return index === activeColumn ? activePipLength : pipLength
  }

  // Nothing about a row of pips says what it is measuring, so the popup reads
  // out the position and names the workspace and layout it was measured on.
  //
  // Read entirely off one layout object rather than the properties unpacked
  // from it: those are separate bindings, and a binding that mixed them could
  // be evaluated with a new column list beside a stale index -- which indexes
  // past the end of the list the moment the workspace loses a column.
  //
  // Returned as one string -- a headline, then a tab-separated label and value
  // per line -- rather than as an object, so the popup can build its rows off
  // a property that signals only on a real change. The poller hands back a
  // fresh layout object several times a second, and an object property would
  // report every one of those as a change, rebuilding the rows under the
  // pointer even when the readout is word for word the same.
  function readout() {
    var snapshot = layout
    var count = snapshot.windowCount
    var columns = snapshot.columns
    var index = snapshot.activeIndex
    var column = snapshot.activeColumn
    var lines = []

    if (count === 0)
      lines.push("No tiled windows")
    else if (snapshot.floatingFocus)
      lines.push("Floating window")
    else if (index < 0)
      lines.push(count + (count === 1 ? " tiled window" : " tiled windows"))
    else
      lines.push("Window " + (index + 1) + " of " + count)

    // The count the headline drops when focus is floating: the strip is still
    // mapping those windows, it just has nothing lit.
    if (snapshot.floatingFocus && count > 0)
      lines.push("Tiled\t" + count + (count === 1 ? " window" : " windows"))

    // Only worth a row when a column holds more than its own window --
    // otherwise it repeats the headline back with the same two numbers.
    if (index >= 0 && columns.length !== count) {
      var stacked = columns[column] ? columns[column].windows.length : 1
      lines.push("Column\t" + (column + 1) + " of " + columns.length
        + (stacked > 1 ? " (" + stacked + " stacked)" : ""))
    }

    if (snapshot.workspaceName !== "")
      lines.push("Workspace\t" + snapshot.workspaceName)
    if (snapshot.tiledLayout !== "")
      lines.push("Layout\t" + snapshot.tiledLayout)

    return lines.join("\n")
  }

  readonly property string readoutText: readout()
  readonly property string readoutHeadline: readoutText.split("\n")[0]
  readonly property var readoutRows: {
    var lines = readoutText.split("\n")
    var rows = []
    for (var i = 1; i < lines.length; i++) {
      var cells = lines[i].split("\t")
      rows.push({ label: cells[0], value: cells[1] })
    }
    return rows
  }

  // ---------------------------------------------------------------- refresh

  function pull() {
    Hyprland.refreshToplevels()
    // Workspaces carry tiledLayout. Toggling a workspace's layout emits no
    // event this widget listens for, so it rides the same refresh as geometry.
    Hyprland.refreshWorkspaces()
    revision++
  }

  // Hyprland has no event for a window being repositioned inside a workspace:
  // swapping two columns rewrites every position and emits nothing but title
  // noise. Events do cover everything that changes *which* windows sit on the
  // workspace, so the arrangement is the only thing that has to be polled --
  // and only while there are at least two windows to arrange.
  Timer {
    id: poller
    interval: root.pollInterval
    repeat: true
    running: root.windowCount >= 2
    triggeredOnStart: true
    onTriggered: root.pull()
  }

  // Debounced, so a burst of events during an animation costs one round trip.
  // Overlaps the poller while it runs, but it keeps opening, closing and
  // focusing a window instant instead of waiting out a poll interval -- and it
  // is the only refresh once the workspace is down to a single window.
  Timer {
    id: refresh
    interval: 60
    onTriggered: root.pull()
  }

  readonly property var ignoredEvents: [
    "windowtitle", "windowtitlev2", "activelayout", "urgent", "screencast",
    "submap", "configreloaded"
  ]

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (root.ignoredEvents.indexOf(event.name) !== -1) return
      refresh.restart()
    }

    // Switching workspaces swaps out the whole strip. Quickshell tracks the
    // focused workspace itself, so watch that property directly rather than
    // hoping the matching raw event names it -- a workspace reached by moving
    // focus across monitors arrives as focusedmon, not workspace.
    function onFocusedWorkspaceChanged() {
      refresh.restart()
    }
  }

  Component.onCompleted: refresh.restart()

  // --------------------------------------------------------------- geometry

  readonly property int pipThickness: 5
  readonly property int pipLength: 6
  readonly property int activePipLength: 14
  readonly property int pipGap: Style.space(4)
  readonly property int segmentGap: 1

  readonly property real stripLength: {
    if (columnCount <= 0) return pipLength
    var total = pipGap * (columnCount - 1)
    for (var i = 0; i < columnCount; i++) total += pipLengthAt(i)
    return total
  }

  // Always on. Whatever the workspace holds -- many windows, one, none -- the
  // widget keeps its slot, so the bar around it stays put.
  visible: true

  implicitWidth: vertical ? barSize : content.width + Style.spacing.controlPaddingX
  implicitHeight: vertical ? content.height + Style.spacing.controlPaddingY : barSize

  Behavior on implicitWidth {
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }

  Grid {
    id: content
    anchors.centerIn: parent
    columns: root.vertical ? 1 : 2
    columnSpacing: Style.space(6)
    rowSpacing: Style.space(4)
    horizontalItemAlignment: Grid.AlignHCenter
    verticalItemAlignment: Grid.AlignVCenter

    // The pip strip is positioned by hand rather than with a Row so each pip
    // can animate its own length as focus moves between columns.
    Item {
      visible: root.showPips
      width: root.vertical ? root.pipThickness : root.stripLength
      height: root.vertical ? root.stripLength : root.pipThickness

      // An empty workspace has no column to draw, so stand a dim pip in its
      // place -- the strip reads as "nothing here" rather than disappearing.
      Rectangle {
        visible: root.columnCount === 0
        anchors.fill: parent
        radius: Math.min(width, height) / 2
        color: root.bar ? root.bar.barForeground : Color.bar.text
        opacity: 0.25
      }

      Repeater {
        model: root.showPips ? root.columnCount : 0

        Item {
          id: pip
          required property int index

          readonly property var windows: root.layout.columns[index].windows
          readonly property bool current: index === root.activeColumn

          property real length: root.pipLengthAt(index)

          // Offset sums every preceding pip, so the strip holds its place
          // while only the focused pip grows.
          property real offset: {
            var total = 0
            for (var i = 0; i < index; i++) total += root.pipLengthAt(i) + root.pipGap
            return total
          }

          x: root.vertical ? 0 : offset
          y: root.vertical ? offset : 0
          width: root.vertical ? root.pipThickness : length
          height: root.vertical ? length : root.pipThickness

          Behavior on length { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
          Behavior on offset { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

          // One segment per window in the column, split across the short axis
          // so a stacked column reads as a stacked pip.
          Repeater {
            model: pip.windows.length

            Rectangle {
              required property int index

              readonly property bool focused: root.focusedAddress !== ""
                && pip.windows[index].address === root.focusedAddress

              readonly property real span: (root.pipThickness
                - root.segmentGap * (pip.windows.length - 1)) / pip.windows.length

              x: root.vertical ? index * (span + root.segmentGap) : 0
              y: root.vertical ? 0 : index * (span + root.segmentGap)
              width: root.vertical ? span : pip.width
              height: root.vertical ? pip.height : span
              radius: Math.min(width, height) / 2

              color: root.bar ? root.bar.barForeground : Color.bar.text
              opacity: focused ? 1 : (pip.current ? 0.6 : 0.3)

              Behavior on opacity { NumberAnimation { duration: 140 } }
            }
          }
        }
      }
    }

    Text {
      visible: root.showCounter
      text: root.windowCount === 0
        ? "0"
        : (root.activeIndex >= 0
          ? (root.activeIndex + 1) + "/" + root.windowCount
          : "-/" + root.windowCount)
      color: root.bar ? root.bar.barForeground : Color.bar.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      opacity: root.floatingFocus ? 0.55 : 0.85
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    // Opened on a delay, so sweeping the pointer across the bar on the way to
    // another widget does not flash the bubble on the way past.
    onEntered: popupDelay.restart()
    onExited: {
      popupDelay.stop()
      root.popupOpen = false
    }

    // Scrolling the pips walks focus along the layout, in the direction the
    // strip runs.
    onWheel: function(wheel) {
      var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
      if (delta === 0) return
      var direction = root.vertical ? (delta < 0 ? "d" : "u") : (delta < 0 ? "r" : "l")
      root.focusDirection(direction)
    }
  }

  // ------------------------------------------------------------------ popup

  // The bar's shared tooltip is a single line of centred text with nowhere to
  // put a title, so the widget draws its own bubble instead: its name over a
  // rule, the position under it, and the rest as label/value rows. The tooltip
  // colours and the bar's 400ms open delay are kept, so it still reads as part
  // of the bar -- and because the bubble binds straight to the readout, it
  // stays current while the pointer sits on it rather than having to be
  // re-announced.
  property bool popupOpen: false

  Timer {
    id: popupDelay
    interval: 400
    onTriggered: root.popupOpen = hover.containsMouse
  }

  PopupWindow {
    id: popup

    readonly property int margin: Style.space(6)

    // Stays mapped through the fade so the bubble can animate away instead of
    // blinking out from under the pointer.
    visible: root.popupOpen || bubble.opacity > 0
    color: "transparent"
    implicitWidth: Math.ceil(bubble.implicitWidth)
    implicitHeight: Math.ceil(bubble.implicitHeight)

    // Focus moving between columns resizes both the strip and the bubble, and
    // scrolling here moves focus with the pointer still on the widget, so
    // re-anchor while the bubble is up rather than leave it hanging off the
    // widget's old centre.
    onImplicitWidthChanged: if (visible) popupAnchor.updateAnchor()

    Connections {
      target: root
      enabled: popup.visible
      function onWidthChanged() { popupAnchor.updateAnchor() }
    }

    anchor {
      id: popupAnchor
      window: root.QsWindow.window
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1

      // Opens on the face of the bar that looks onto the workspace, and is
      // held off the screen edge for a widget sitting at the end of the bar.
      onAnchoring: {
        var window = root.QsWindow.window
        if (!window) return

        var popupWidth = popup.implicitWidth
        var popupHeight = popup.implicitHeight
        var position = root.bar ? root.bar.position : "top"
        var localX = root.width / 2 - popupWidth / 2
        var localY = root.height + popup.margin

        if (position === "bottom") {
          localY = -popupHeight - popup.margin
        } else if (position === "left") {
          localX = root.width + popup.margin
          localY = root.height / 2 - popupHeight / 2
        } else if (position === "right") {
          localX = -popupWidth - popup.margin
          localY = root.height / 2 - popupHeight / 2
        }

        var point = window.contentItem.mapFromItem(root, localX, localY)
        if (position === "top" || position === "bottom")
          point.x = Math.max(popup.margin,
            Math.min(point.x, window.width - popupWidth - popup.margin))
        else
          point.y = Math.max(popup.margin,
            Math.min(point.y, window.height - popupHeight - popup.margin))

        popupAnchor.rect.x = Math.round(point.x)
        popupAnchor.rect.y = Math.round(point.y)
      }
    }

    BorderSurface {
      id: bubble
      anchors.fill: parent
      color: Color.tooltip.background
      borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, Style.normalBorderWidth)
      radius: Style.cornerRadius
      leftPadding: Style.spacing.rowPaddingX
      rightPadding: Style.spacing.rowPaddingX
      topPadding: Style.spacing.lg
      bottomPadding: Style.spacing.lg

      implicitWidth: body.width + contentLeftInset + contentRightInset
      implicitHeight: body.implicitHeight + contentTopInset + contentBottomInset

      opacity: root.popupOpen ? 1 : 0

      Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

      Column {
        id: body
        x: bubble.contentLeftInset
        y: bubble.contentTopInset
        spacing: Style.spacing.sm

        // Sized to its widest line rather than filling the bubble: the bubble
        // takes its own width from this, so measuring against the parent would
        // tie the two together.
        width: Math.max(title.implicitWidth, headline.implicitWidth, rows.implicitWidth)

        Text {
          id: title
          textFormat: Text.PlainText
          text: root.pluginName
          color: Color.tooltip.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          opacity: 0.65
        }

        Rectangle {
          width: body.width
          height: 1
          color: Color.tooltip.text
          opacity: 0.15
        }

        Text {
          id: headline
          textFormat: Text.PlainText
          text: root.readoutHeadline
          color: Color.tooltip.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // A column of labels beside a column of values, rather than one grid
        // of cells: the values then start on a common left edge whatever the
        // labels happen to measure, and both columns step in the same rhythm
        // because every row is one line of the same size.
        Row {
          id: rows
          visible: root.readoutRows.length > 0
          spacing: Style.spacing.controlGap

          Column {
            spacing: Style.spacing.xxs

            Repeater {
              model: root.readoutRows

              Text {
                required property var modelData

                textFormat: Text.PlainText
                text: modelData.label
                color: Color.tooltip.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                opacity: 0.55
              }
            }
          }

          Column {
            spacing: Style.spacing.xxs

            Repeater {
              model: root.readoutRows

              Text {
                required property var modelData

                textFormat: Text.PlainText
                text: modelData.value
                color: Color.tooltip.text
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }

  function focusDirection(direction) {
    if (!bar) return
    bar.run("hyprctl dispatch "
      + Util.shellQuote("hl.dsp.focus({ direction = \"" + direction + "\" })"))
  }
}
