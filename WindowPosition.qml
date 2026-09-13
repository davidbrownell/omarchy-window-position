import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Carousel indicator for a tiled workspace: one pip per band of windows on
// the focused workspace, elongated on the band that owns focus. A band that
// stacks several windows splits its pip into one segment per window, so the
// widget maps the workspace instead of only counting it.
//
// The bands are read out of the window geometry rather than out of the layout's
// name, so a workspace running a Lua layout somebody drew this morning is
// mapped as readily as one running scrolling, dwindle or master.
BarWidget {
  id: root
  moduleName: "dbrownell.window-position"

  // Mirrors `name` in manifest.json. The hover popup titles itself with this,
  // so a bubble that opens under a row of anonymous pips says what drew it.
  readonly property string pluginName: "Window position"

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string style: String(setting("style", "pips"))
  readonly property int maxPips: Math.max(1, Number(setting("maxPips", 12)))
  readonly property int maxStackedWindows: Math.max(1, Number(setting("maxStackedWindows", 5)))
  readonly property int pollInterval: Math.max(100, Number(setting("pollInterval", 250)))

  // Bumped on every refresh so one counter drives the whole recompute, even
  // when Hyprland hands back a client list that QML sees as unchanged.
  property int revision: 0

  readonly property var layout: computeLayout(revision)
  readonly property int bandCount: layout.bands.length
  readonly property int activeBand: layout.activeBand
  readonly property int activeIndex: layout.activeIndex
  readonly property int windowCount: layout.windowCount
  readonly property int deepestStack: layout.deepestStack
  readonly property string grain: layout.grain
  readonly property string focusedAddress: layout.focusedAddress
  readonly property bool floatingFocus: layout.floatingFocus
  readonly property string tiledLayout: layout.tiledLayout
  readonly property string workspaceName: layout.workspaceName

  // A pip has only pipThickness to divide between the windows stacked inside
  // it, so a deep stack draws segments too thin to see. Which layouts stack
  // deeply is not a question a name can answer -- a workspace can be running
  // something drawn this morning -- so measure the stack instead. Past this
  // many windows in one pip the count is the only part still legible, so show
  // it on its own.
  readonly property bool crowded: deepestStack > maxStackedWindows

  // An empty workspace still gets a strip -- one dim placeholder pip -- so the
  // widget holds its place in the bar instead of blinking out and shoving its
  // neighbours around every time the last window closes.
  readonly property bool showPips: bandCount <= maxPips
    && !crowded && style !== "counter"
  readonly property bool showCounter: style !== "pips"
    || bandCount > maxPips || crowded

  // ------------------------------------------------------------------ model

  // Two windows are in the same band when they overlap along the axis being
  // cut. Hyprland reports fractional positions mid-animation, so allow a
  // little overlap before a cut between them is called off.
  readonly property int bandTolerance: 24

  // A tiling layout is a rectangle cut, and the pieces cut again -- scrolling
  // cuts columns, dwindle alternates, a Lua layout cuts wherever it was drawn
  // to -- so the arrangement can be recovered from the windows themselves:
  // find a line across the workspace that no window straddles, split there,
  // and recurse into each piece.
  //
  // Reading geometry rather than the layout's name is what lets the strip map
  // a layout that did not exist when this was written. The earlier model,
  // bucketing windows by their left edge, could only ever produce columns: a
  // rows layout came back as one fat column holding everything, and a grid as
  // however many of its windows happened to share an x.
  function cutAlong(windows, axis) {
    var start = axis === "x" ? "x" : "y"
    var extent = axis === "x" ? "w" : "h"
    var other = axis === "x" ? "y" : "x"

    var sorted = windows.slice().sort(function(left, right) {
      return left[start] !== right[start]
        ? left[start] - right[start]
        : left[other] - right[other]
    })

    var bands = []
    var band = null
    var edge = 0
    for (var i = 0; i < sorted.length; i++) {
      var window = sorted[i]
      // Starting past every edge seen so far means no window spans the gap
      // behind this one, so the layout can be cut there.
      if (band === null || window[start] >= edge - root.bandTolerance) {
        band = [window]
        bands.push(band)
        edge = window[start] + window[extent]
      } else {
        band.push(window)
        edge = Math.max(edge, window[start] + window[extent])
      }
    }
    return bands
  }

  // Columns first, so a layout that reads either way -- a grid, an even split
  // -- comes back as columns, and the strip keeps the left-to-right sense it
  // has always had under scrolling.
  function splitOnce(windows) {
    var bands = cutAlong(windows, "x")
    if (bands.length > 1) return { axis: "x", bands: bands }
    bands = cutAlong(windows, "y")
    if (bands.length > 1) return { axis: "y", bands: bands }
    return { axis: "", bands: [windows] }
  }

  // Reading order inside one pip: keep cutting, and emit the windows in the
  // order the cuts leave them.
  function flattenBand(windows, out) {
    if (windows.length === 1) {
      out.push(windows[0])
      return
    }

    var split = splitOnce(windows)
    if (split.axis === "") {
      // Nothing separates them: windows sharing a rectangle, or caught
      // overlapping mid-animation. Fall back to reading order, so the count
      // and the highlight are right even though the shape is a guess.
      var piled = windows.slice().sort(function(left, right) {
        return left.y !== right.y ? left.y - right.y : left.x - right.x
      })
      for (var i = 0; i < piled.length; i++) out.push(piled[i])
      return
    }

    for (var b = 0; b < split.bands.length; b++) flattenBand(split.bands[b], out)
  }

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

    // Layout is a per-workspace property in Hyprland, so it is read off the
    // workspace rather than once from general:layout. It is reported, not
    // trusted -- see layoutLabel.
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
      bands: [], order: [], grain: "columns",
      activeBand: -1, activeIndex: -1, windowCount: 0, deepestStack: 0,
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

      // Size as well as position: the cut looks for a line no window straddles,
      // which is a question about right and bottom edges as much as left and
      // top ones. Scroll direction is read off these rectangles too.
      var at = client.at
      var size = client.size
      tiled.push({
        address: String(client.address || ""),
        x: at ? Number(at[0]) : 0,
        y: at ? Number(at[1]) : 0,
        w: size ? Number(size[0]) : 0,
        h: size ? Number(size[1]) : 0
      })
    }
    if (tiled.length === 0) return empty

    // One pip per top-level band; the windows inside it are the pip's segments,
    // in the order the cuts below it leave them.
    var split = splitOnce(tiled)
    var bands = []
    var order = []
    var activeBand = -1
    var activeIndex = -1
    var deepestStack = 0

    for (var s = 0; s < split.bands.length; s++) {
      var band = []
      flattenBand(split.bands[s], band)
      bands.push(band)
      if (band.length > deepestStack) deepestStack = band.length

      for (var m = 0; m < band.length; m++) {
        if (focusedAddress !== "" && band[m].address === focusedAddress) {
          activeBand = s
          activeIndex = order.length
        }
        order.push(band[m])
      }
    }

    return {
      bands: bands,
      order: order,
      grain: split.axis === "y" ? "rows" : "columns",
      activeBand: activeBand,
      activeIndex: activeIndex,
      windowCount: tiled.length,
      deepestStack: deepestStack,
      focusedAddress: focusedAddress,
      floatingFocus: empty.floatingFocus,
      tiledLayout: tiledLayout,
      workspaceName: workspaceName
    }
  }

  // Hyprland answers tiledLayout for a Lua layout with the name of the *first*
  // Lua layout registered, whatever the workspace is actually tiling with: a
  // workspace running lua:omarchy-wsl-focus reports lua:omarchy-wsl-even, and
  // goes on reporting it after the layout is changed again. The lua: prefix is
  // reliable and the name after it is not, so name the layouts Hyprland gets
  // right and let the band row describe the rest -- it is measured from the
  // windows, so it cannot be stale.
  readonly property string layoutLabel: tiledLayout.indexOf("lua:") === 0
    ? "Lua layout" : tiledLayout

  function pipLengthAt(index) {
    return index === activeBand ? activePipLength : pipLength
  }

  // Nothing about a row of pips says what it is measuring, so the popup reads
  // out the position and names the workspace and layout it was measured on.
  //
  // Read entirely off one layout object rather than the properties unpacked
  // from it: those are separate bindings, and a binding that mixed them could
  // be evaluated with a new band list beside a stale index -- which indexes
  // past the end of the list the moment the workspace loses a band.
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
    var bands = snapshot.bands
    var index = snapshot.activeIndex
    var band = snapshot.activeBand
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

    // Only worth a row when a band holds more than its own window -- otherwise
    // it repeats the headline back with the same two numbers. Named for the way
    // the workspace is actually cut, which is the one description of the layout
    // here that is measured rather than reported.
    if (index >= 0 && bands.length !== count) {
      var stacked = bands[band] ? bands[band].length : 1
      lines.push((snapshot.grain === "rows" ? "Row" : "Column") + "\t"
        + (band + 1) + " of " + bands.length
        + (stacked > 1 ? " (" + stacked + " stacked)" : ""))
    }

    if (snapshot.workspaceName !== "")
      lines.push("Workspace\t" + snapshot.workspaceName)
    if (layoutLabel !== "")
      lines.push("Layout\t" + layoutLabel)

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

  // A pixel between segments while there is room for one. Past that the gaps
  // are the first thing to go: a stack of five has all five pixels of the pip
  // to itself rather than four thinned below a pixel each, so the strip stays
  // readable as far down as the counter fallback lets it go.
  function segmentGapFor(count) {
    return count > 1 && (pipThickness - (count - 1)) / count >= 2 ? 1 : 0
  }

  readonly property real stripLength: {
    if (bandCount <= 0) return pipLength
    var total = pipGap * (bandCount - 1)
    for (var i = 0; i < bandCount; i++) total += pipLengthAt(i)
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
    // can animate its own length as focus moves between bands.
    Item {
      visible: root.showPips
      width: root.vertical ? root.pipThickness : root.stripLength
      height: root.vertical ? root.stripLength : root.pipThickness

      // An empty workspace has no band to draw, so stand a dim pip in its
      // place -- the strip reads as "nothing here" rather than disappearing.
      Rectangle {
        visible: root.bandCount === 0
        anchors.fill: parent
        radius: Math.min(width, height) / 2
        color: root.bar ? root.bar.barForeground : Color.bar.text
        opacity: 0.25
      }

      Repeater {
        model: root.showPips ? root.bandCount : 0

        Item {
          id: pip
          required property int index

          readonly property var windows: root.layout.bands[index] || []
          readonly property bool current: index === root.activeBand

          readonly property int segmentGap: root.segmentGapFor(windows.length)
          readonly property real segmentSpan: (root.pipThickness
            - segmentGap * (windows.length - 1)) / windows.length

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

          // One segment per window in the band, split across the short axis so
          // a stacked band reads as a stacked pip.
          Repeater {
            model: pip.windows.length

            Rectangle {
              required property int index

              readonly property bool focused: root.focusedAddress !== ""
                && pip.windows[index].address === root.focusedAddress

              readonly property real segmentOffset: index * (pip.segmentSpan + pip.segmentGap)

              x: root.vertical ? segmentOffset : 0
              y: root.vertical ? 0 : segmentOffset
              width: root.vertical ? pip.segmentSpan : pip.width
              height: root.vertical ? pip.height : pip.segmentSpan
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

    // Scrolling the strip walks focus along the layout in reading order --
    // across the bands, and down into a band that stacks several windows.
    onWheel: function(wheel) {
      var delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
      if (delta === 0) return
      root.focusStep(delta < 0 ? 1 : -1)
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

    // Focus moving between bands resizes both the strip and the bubble, and
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

  // Hyprland has no dispatcher for focusing a particular window: there is no
  // focuswindow, and the window objects hl.get_windows() hands back carry no
  // focus method either. Focus can only be pushed in a direction.
  //
  // So take the direction from the two windows themselves -- whichever way the
  // next one in reading order actually lies. That walks down a stacked pip as
  // readily as it crosses the strip, and it needs to know nothing about the
  // layout doing the stacking, which is the only way it could keep working
  // under a layout written after this.
  function focusStep(step) {
    if (!bar) return

    var snapshot = layout
    var order = snapshot.order
    var from = snapshot.activeIndex >= 0 ? order[snapshot.activeIndex] : null
    var to = from ? order[snapshot.activeIndex + step] : null
    var direction = ""

    if (from && to) {
      var dx = (to.x + to.w / 2) - (from.x + from.w / 2)
      var dy = (to.y + to.h / 2) - (from.y + from.h / 2)
      direction = Math.abs(dx) >= Math.abs(dy)
        ? (dx > 0 ? "r" : "l")
        : (dy > 0 ? "d" : "u")
    } else if (from) {
      // Focus is already on the first or last window in the order. Nothing to
      // step to, and the strip does not wrap.
      return
    } else {
      // Nothing tiled has focus -- a floating window holds it, or it is on
      // another monitor. Push along the grain and let the next refresh report
      // wherever it landed.
      direction = snapshot.grain === "rows"
        ? (step > 0 ? "d" : "u")
        : (step > 0 ? "r" : "l")
    }

    bar.run("hyprctl dispatch "
      + Util.shellQuote("hl.dsp.focus({ direction = \"" + direction + "\" })"))
  }
}
