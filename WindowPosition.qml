import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "LayoutReader.js" as LayoutReader

// Carousel indicator for a tiled workspace: one pip per band of windows on
// the focused workspace, elongated on the band that owns focus. A band that
// stacks several windows splits its pip into one segment per window, so the
// widget maps the workspace instead of only counting it.
//
// The bands are read out of the window geometry rather than out of the layout's
// name, so a workspace running a Lua layout somebody drew this morning is
// mapped as readily as one running scrolling, dwindle or master. That reading
// lives in LayoutReader.js, which knows nothing about Hyprland or QML; what is
// left here is fetching the windows, drawing them, and talking to Hyprland.
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
  readonly property var floatingWindows: layout.floating
  readonly property int floatingCount: layout.floating.length
  readonly property string floatingAddress: layout.floatingAddress
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
  // Floating marks are drawn in the same strip, so they count against the same
  // budget: what maxPips is really protecting is the width of the widget.
  readonly property bool showPips: bandCount + floatingCount <= maxPips
    && !crowded && style !== "counter"
  readonly property bool showCounter: style !== "pips"
    || bandCount + floatingCount > maxPips || crowded

  // ---------------------------------------------------------------- monitor

  // A bar surface exists per monitor, so this widget is live once per screen.
  // Reading the globally focused workspace would leave every strip but one
  // mapping an output its own bar is not sitting on -- so each instance asks
  // its window which screen it landed on, and maps what that screen shows.
  readonly property var screenInfo: root.QsWindow.window
    ? root.QsWindow.window.screen : null
  readonly property var monitor: screenInfo ? Hyprland.monitorFor(screenInfo) : null

  // Falls back to the focused workspace while there is no window to ask --
  // during construction, and for a widget the host mounts outside a bar
  // surface. On a single-monitor machine the two are the same answer.
  readonly property var scopedWorkspace: monitor ? monitor.activeWorkspace
    : Hyprland.focusedWorkspace

  // ------------------------------------------------------------------ model

  // How much overlap to forgive before a cut between two windows is called
  // off. Hyprland reports fractional positions mid-animation, so a strict
  // reading would see bands appear and vanish as windows slide.
  readonly property int bandTolerance: LayoutReader.DEFAULT_TOLERANCE

  // What the reader hands back, with the things only this widget knows --
  // which window has focus, what the workspace is called, what Hyprland
  // claims it is tiling with -- folded in beside it.
  function describe(reading, focusedAddress, floating, floatingAddress,
      tiledLayout, workspaceName) {
    return {
      bands: reading.bands,
      order: reading.order,
      grain: reading.grain,
      activeBand: reading.activeBand,
      activeIndex: reading.activeIndex,
      windowCount: reading.windowCount,
      deepestStack: reading.deepestStack,
      focusedAddress: focusedAddress,
      floating: floating,
      floatingAddress: floatingAddress,
      floatingFocus: floatingAddress !== "",
      tiledLayout: tiledLayout,
      workspaceName: workspaceName
    }
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

    // The workspace this monitor is showing, not the one owning the focused
    // window. The two part company the moment you switch to an empty
    // workspace: nothing there can take focus, so the window you left behind
    // keeps focusHistoryID 0 -- and reading focus first would leave the strip
    // mapping the old workspace. They part company on every unfocused monitor
    // too, which is the whole reason the workspace is scoped to the output.
    var workspace = root.scopedWorkspace
    if (!workspace && focused) workspace = focused.workspace
    var workspaceId = workspace ? workspace.id : null

    // Focus that sits on another workspace is not this workspace's focus --
    // including focus that sits on another monitor, which is how an unfocused
    // screen's strip comes to map its arrangement with nothing lit.
    if (focused && focused.workspace.id !== workspaceId) focused = null

    // Layout is a per-workspace property in Hyprland, so it is read off the
    // workspace rather than once from general:layout. It is reported, not
    // trusted -- see layoutLabel.
    var tiledLayout = ""
    var workspaceName = workspaceId === null ? "" : String(workspaceId)
    var meta = workspace && workspace.lastIpcObject ? workspace.lastIpcObject : null
    if (meta && meta.tiledLayout) tiledLayout = String(meta.tiledLayout)
    if (workspace && workspace.name) workspaceName = String(workspace.name)

    var isFloating = focused ? focused.floating === true : false
    var focusedAddress = focused && !isFloating ? String(focused.address || "") : ""
    var floatingAddress = focused && isFloating ? String(focused.address || "") : ""
    if (workspaceId === null)
      return describe(LayoutReader.read([], ""), focusedAddress, [], floatingAddress,
        tiledLayout, workspaceName)

    var tiled = []
    var floating = []
    for (var c = 0; c < clients.length; c++) {
      var client = clients[c]
      if (client.workspace.id !== workspaceId) continue
      if (client.mapped === false || client.hidden) continue

      // Size as well as position: the cut looks for a line no window straddles,
      // which is a question about right and bottom edges as much as left and
      // top ones. Scroll direction is read off these rectangles too.
      var at = client.at
      var size = client.size
      var window = {
        address: String(client.address || ""),
        x: at ? Number(at[0]) : 0,
        y: at ? Number(at[1]) : 0,
        w: size ? Number(size[0]) : 0,
        h: size ? Number(size[1]) : 0,
        focusOrder: Number(client.focusHistoryID)
      }

      // A floating window sits over the tiling rather than in it, so it is no
      // part of the shape being read -- but it is still on the workspace, and
      // a widget that leaves it out entirely has nothing to say for the moment
      // one of them takes focus except to dim, which reads as a fault.
      if (client.floating) floating.push(window)
      else tiled.push(window)
    }

    // Most recently used first, so the marks only reorder when focus moves
    // between them. Floating windows have no arrangement to be read off their
    // geometry -- they overlap wherever they were dropped -- and sorting them
    // by position would have them swap places as one is dragged.
    floating.sort(function(left, right) { return left.focusOrder - right.focusOrder })

    // One pip per band of the first cut; the windows inside it are the pip's
    // segments, in the order the cuts below it leave them.
    return describe(LayoutReader.read(tiled, focusedAddress, root.bandTolerance),
      focusedAddress, floating, floatingAddress, tiledLayout, workspaceName)
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

    // Floating first: a floating window has focus whatever the tiling behind
    // it is doing, and answering "No tiled windows" to a workspace you are
    // looking at a window on is no answer at all.
    var floating = snapshot.floating
    var floatingIndex = -1
    for (var f = 0; f < floating.length; f++) {
      if (floating[f].address === snapshot.floatingAddress) floatingIndex = f
    }

    if (snapshot.floatingFocus)
      lines.push(floatingIndex >= 0 && floating.length > 1
        ? "Floating window " + (floatingIndex + 1) + " of " + floating.length
        : "Floating window")
    else if (count === 0)
      lines.push("No tiled windows")
    else if (index < 0)
      lines.push(count + (count === 1 ? " tiled window" : " tiled windows"))
    else
      lines.push("Window " + (index + 1) + " of " + count)

    // The count the headline drops when focus is floating: the strip is still
    // mapping those windows, it just has nothing lit.
    if (snapshot.floatingFocus && count > 0)
      lines.push("Tiled\t" + count + (count === 1 ? " window" : " windows"))

    // And the other way about. Floating windows are on the workspace whether
    // or not one of them holds focus, which is what the hollow marks are
    // saying; this says how many in words.
    if (!snapshot.floatingFocus && floating.length > 0)
      lines.push("Floating\t" + floating.length
        + (floating.length === 1 ? " window" : " windows"))

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

  // Every instance of this widget reads the same process-wide Hyprland
  // snapshot, so one of them fetches it and hands the result to the rest. The
  // alternative on a three-monitor machine is three round trips several times
  // a second for one set of numbers.
  function peers() {
    return bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
  }

  // Bumped on every instance when the set of instances changes, so the two
  // bindings below are re-elected rather than settled once: a monitor arriving
  // or leaving has to be able to hand the poller on.
  property int census: 0

  function noteCensus() { census++ }

  readonly property bool pollMaster: {
    census
    var items = root.peers()
    return items.length === 0 || items[0] === root
  }

  // Polls while *any* strip has an arrangement to watch. A workspace on an
  // unfocused monitor can be rearranged too, and the instance drawing it is
  // not the one holding the timer.
  readonly property bool pollWanted: {
    census
    var items = root.peers()
    if (items.length === 0) return root.windowCount >= 2
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i].windowCount >= 2) return true
    }
    return false
  }

  function pull() {
    Hyprland.refreshToplevels()
    // Workspaces carry tiledLayout. Toggling a workspace's layout emits no
    // event this widget listens for, so it rides the same refresh as geometry.
    Hyprland.refreshWorkspaces()
    broadcast("bump")
  }

  // What the refreshes above hand back is global, so one pull answers every
  // strip; each instance only has to be told to re-read it.
  function bump() { revision++ }

  // Hyprland has no event for a window being repositioned inside a workspace:
  // swapping two columns rewrites every position and emits nothing but title
  // noise. Events do cover everything that changes *which* windows sit on the
  // workspace, so the arrangement is the only thing that has to be polled --
  // and only while there are at least two windows to arrange, on some screen.
  Timer {
    id: poller
    interval: root.pollInterval
    repeat: true
    running: root.pollMaster && root.pollWanted
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

  // Routed to whichever instance is polling, so a burst of events costs one
  // round trip across the whole bar rather than one per monitor. Every
  // instance sees every event, and they all restart the same timer.
  function requestRefresh() {
    var items = root.peers()
    var master = items.length > 0 ? items[0] : root
    if (master && typeof master.startRefresh === "function") master.startRefresh()
    else root.startRefresh()
  }

  function startRefresh() { refresh.restart() }

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (root.ignoredEvents.indexOf(event.name) !== -1) return
      root.requestRefresh()
    }
  }

  // The workspace this monitor shows changing swaps out the whole strip. The
  // raw event behind it reaches every instance anyway, so this is here for the
  // case that is not an event at all: the screen resolving late, and with it
  // the monitor this instance is scoped to.
  onScopedWorkspaceChanged: requestRefresh()

  Component.onCompleted: {
    // Deferred, because the host publishes this instance to the widget
    // registry as the loader finishes -- which can be after this runs, so a
    // census taken here could miss the instance taking it.
    Qt.callLater(function() { root.broadcast("noteCensus") })
    requestRefresh()
  }

  // The poller may have been this one. Whoever is left re-elects on the next
  // evaluation of pollMaster, which is what the census is for.
  Component.onDestruction: broadcast("noteCensus")

  // --------------------------------------------------------------- geometry

  readonly property int pipThickness: 5
  readonly property int pipLength: 6
  readonly property int activePipLength: 14
  readonly property int pipGap: Style.space(4)

  // Floating marks stand off the strip by more than the pips stand off each
  // other, because they are not part of what the strip is measuring.
  readonly property int floatingGap: Style.space(9)

  // A pixel between segments while there is room for one. Past that the gaps
  // are the first thing to go: a stack of five has all five pixels of the pip
  // to itself rather than four thinned below a pixel each, so the strip stays
  // readable as far down as the counter fallback lets it go.
  function segmentGapFor(count) {
    return count > 1 && (pipThickness - (count - 1)) / count >= 2 ? 1 : 0
  }

  readonly property real tiledLength: {
    if (bandCount <= 0) return pipLength
    var total = pipGap * (bandCount - 1)
    for (var i = 0; i < bandCount; i++) total += pipLengthAt(i)
    return total
  }

  readonly property real floatingLength: floatingCount <= 0 ? 0
    : floatingGap + pipLength * floatingCount + pipGap * (floatingCount - 1)

  readonly property real stripLength: tiledLength + floatingLength

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
      // Sized rather than filled: a workspace can be empty of tiled windows
      // and still be carrying floating ones, whose marks share this strip.
      Rectangle {
        visible: root.bandCount === 0
        width: root.vertical ? root.pipThickness : root.pipLength
        height: root.vertical ? root.pipLength : root.pipThickness
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

      // One hollow mark per floating window, set off from the strip. Hollow
      // because a floating window is not one of the pieces the workspace was
      // cut into: it is over the tiling, not in it, and an outline says so
      // without needing a legend. The one holding focus fills in.
      Repeater {
        model: root.showPips ? root.floatingCount : 0

        Rectangle {
          id: mark
          required property int index

          readonly property var window: root.floatingWindows[index] || null
          readonly property bool focused: root.floatingAddress !== "" && window
            && window.address === root.floatingAddress

          property real offset: root.tiledLength + root.floatingGap
            + index * (root.pipLength + root.pipGap)

          x: root.vertical ? 0 : offset
          y: root.vertical ? offset : 0
          width: root.vertical ? root.pipThickness : root.pipLength
          height: root.vertical ? root.pipLength : root.pipThickness
          radius: Math.min(width, height) / 2

          color: focused
            ? (root.bar ? root.bar.barForeground : Color.bar.text) : "transparent"
          border.width: 1
          border.color: root.bar ? root.bar.barForeground : Color.bar.text
          opacity: focused ? 1 : 0.4

          Behavior on offset { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
          Behavior on opacity { NumberAnimation { duration: 140 } }
        }
      }
    }

    Text {
      visible: root.showCounter
      // The floating count rides along as a suffix rather than joining the
      // total: they are windows on the workspace, but they are not places in
      // the order the first number is counting through.
      text: {
        var tiled = root.windowCount === 0
          ? "0"
          : (root.activeIndex >= 0
            ? (root.activeIndex + 1) + "/" + root.windowCount
            : "-/" + root.windowCount)
        return root.floatingCount > 0 ? tiled + "+" + root.floatingCount : tiled
      }
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
  // focus method either. Focus can only be pushed in a direction -- which the
  // reader works out from the two windows themselves, so it walks down a
  // stacked pip as readily as it crosses the strip.
  function focusStep(step) {
    if (!bar) return

    var direction = LayoutReader.stepDirection(layout, step)
    if (direction === "") return

    bar.run("hyprctl dispatch "
      + Util.shellQuote("hl.dsp.focus({ direction = \"" + direction + "\" })"))
  }
}
