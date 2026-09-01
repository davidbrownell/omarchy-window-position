import QtQuick
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

  // Nothing about a row of pips says what it is measuring, so the tooltip
  // reads out the position and names the workspace and layout it was read from.
  //
  // Read entirely off one layout object rather than the properties unpacked
  // from it: those are separate bindings, and a binding that mixed them could
  // be evaluated with a new column list beside a stale index -- which indexes
  // past the end of the list the moment the workspace loses a column.
  function tooltipText() {
    var snapshot = layout
    var count = snapshot.windowCount
    var columns = snapshot.columns
    var index = snapshot.activeIndex
    var column = snapshot.activeColumn
    var lines = []

    if (count === 0)
      lines.push("No tiled windows")
    else if (snapshot.floatingFocus)
      lines.push("Floating window · " + count + " tiled")
    else if (index < 0)
      lines.push(count + (count === 1 ? " tiled window" : " tiled windows"))
    else {
      var text = "Window " + (index + 1) + " of " + count
      if (columns.length !== count)
        text += " · column " + (column + 1) + " of " + columns.length
      var stacked = columns[column] ? columns[column].windows.length : 1
      if (stacked > 1) text += " (" + stacked + " stacked)"
      lines.push(text)
    }

    if (snapshot.workspaceName !== "")
      lines.push("Workspace " + snapshot.workspaceName
        + (snapshot.tiledLayout !== "" ? " · " + snapshot.tiledLayout + " layout" : ""))

    return lines.join("\n")
  }

  // Held as a property rather than called at each use: the poller hands back a
  // fresh layout object every interval, so a binding on layout alone would
  // re-announce identical text several times a second -- and every re-announce
  // restarts the bar's open delay, which keeps the tooltip from ever appearing.
  // A string property only signals on a real change, so the delay can elapse.
  readonly property string tooltipLabel: tooltipText()

  // The bar only opens a tooltip for a widget that reports itself hovered --
  // it reads this property off the target rather than trusting the request.
  readonly property bool tooltipHovered: hover.containsMouse

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
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      opacity: root.floatingFocus ? 0.55 : 0.85
    }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipLabel)
    onExited: if (root.bar) root.bar.hideTooltip(root)

    // Scrolling the pips walks focus along the layout, in the direction the
    // strip runs.
    onWheel: function(wheel) {
      var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
      if (delta === 0) return
      var direction = root.vertical ? (delta < 0 ? "d" : "u") : (delta < 0 ? "r" : "l")
      root.focusDirection(direction)
    }
  }

  // The tooltip is a shared popup that only takes text when it is opened, so
  // re-show it while the pointer sits on a strip that is still moving.
  onTooltipLabelChanged: if (hover.containsMouse && bar) bar.showTooltip(root, tooltipLabel)

  function focusDirection(direction) {
    if (!bar) return
    bar.run("hyprctl dispatch "
      + Util.shellQuote("hl.dsp.focus({ direction = \"" + direction + "\" })"))
  }
}
