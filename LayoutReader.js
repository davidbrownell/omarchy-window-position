.pragma library

// Reading a tiled workspace back out of the geometry of its windows.
//
// Nothing here is keyed to a layout, and nothing here knows about Hyprland,
// Quickshell or QML. A tiling layout is a rectangle cut, and the pieces cut
// again, whoever wrote it: scrolling cuts columns, dwindle alternates, a Lua
// layout cuts wherever it was drawn to. So the arrangement can be recovered
// from the windows themselves -- find a straight line across the workspace
// that no window straddles, split there, and recurse into each piece.
//
// That is what lets a widget map a layout that did not exist when it was
// written, and it is the reason this is a file of its own: the caller supplies
// rectangles from wherever it likes, and gets the shape back.
//
// A window is any object carrying:
//
//   { address: string, x: number, y: number, w: number, h: number }
//
// `address` is only ever compared for equality, so any stable identity will
// do. Extra properties are carried through untouched -- the windows handed in
// are the same objects handed back in `bands` and `order`.

// Two windows are in the same band when they overlap along the axis being cut.
// Compositors report fractional positions mid-animation, so allow a little
// overlap before a cut between them is called off.
var DEFAULT_TOLERANCE = 24

function toleranceOr(tolerance) {
  return typeof tolerance === "number" && isFinite(tolerance)
    ? tolerance : DEFAULT_TOLERANCE
}

// Split `windows` wherever a line perpendicular to `axis` ("x" or "y") passes
// between them without crossing any window. Returns one array per piece, in
// order along the axis; a single piece means there is no cut to make.
function cutAlong(windows, axis, tolerance) {
  var slack = toleranceOr(tolerance)
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
    if (band === null || window[start] >= edge - slack) {
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

// The first cut, looked for vertically before horizontally: a shape that reads
// either way -- a grid, an even split -- comes back as columns, which keeps the
// left-to-right sense a strip of pips has always had under scrolling.
//
// `axis` is "" when nothing separates the windows, which is the caller's cue
// that the single band it got back is a guess rather than a reading.
function splitOnce(windows, tolerance) {
  var bands = cutAlong(windows, "x", tolerance)
  if (bands.length > 1) return { axis: "x", bands: bands }
  bands = cutAlong(windows, "y", tolerance)
  if (bands.length > 1) return { axis: "y", bands: bands }
  return { axis: "", bands: [windows] }
}

// Reading order inside one band: keep cutting, and emit the windows in the
// order the cuts leave them.
function flattenBand(windows, out, tolerance) {
  if (windows.length === 1) {
    out.push(windows[0])
    return out
  }

  var split = splitOnce(windows, tolerance)
  if (split.axis === "") {
    // Nothing separates them: windows sharing a rectangle, one window covering
    // the rest, or a set caught overlapping mid-animation. Fall back to reading
    // order, so the count and the highlight are right even though the shape is
    // a guess.
    var piled = windows.slice().sort(function(left, right) {
      return left.y !== right.y ? left.y - right.y : left.x - right.x
    })
    for (var i = 0; i < piled.length; i++) out.push(piled[i])
    return out
  }

  for (var b = 0; b < split.bands.length; b++) {
    flattenBand(split.bands[b], out, tolerance)
  }
  return out
}

// Read the arrangement of `windows`, which should already be filtered down to
// the tiled windows of one workspace. `focusedAddress` may be empty, which
// leaves activeBand and activeIndex at -1.
//
// Returns:
//
//   bands         one array of windows per piece of the first cut
//   order         every window, in reading order across and down the bands
//   grain         "columns" or "rows", after the axis of the first cut
//   activeBand    index into bands of the band holding focus, or -1
//   activeIndex   index into order of the focused window, or -1
//   windowCount   order.length, for callers that only want the number
//   deepestStack  windows in the most crowded band
function read(windows, focusedAddress, tolerance) {
  var address = focusedAddress === undefined || focusedAddress === null
    ? "" : String(focusedAddress)

  var empty = {
    bands: [],
    order: [],
    grain: "columns",
    activeBand: -1,
    activeIndex: -1,
    windowCount: 0,
    deepestStack: 0
  }
  if (!windows || windows.length === 0) return empty

  // One band per piece of the first cut; the windows inside it are read in the
  // order the cuts below it leave them.
  var split = splitOnce(windows, tolerance)
  var bands = []
  var order = []
  var activeBand = -1
  var activeIndex = -1
  var deepestStack = 0

  for (var s = 0; s < split.bands.length; s++) {
    var band = flattenBand(split.bands[s], [], tolerance)
    bands.push(band)
    if (band.length > deepestStack) deepestStack = band.length

    for (var m = 0; m < band.length; m++) {
      if (address !== "" && band[m].address === address) {
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
    windowCount: order.length,
    deepestStack: deepestStack
  }
}

// Which way `to` lies from `from`, as one of "l", "r", "u", "d". Measured
// between the centres, so a tall window beside a short one answers the same
// way whichever of them is asking.
function directionBetween(from, to) {
  var dx = (to.x + to.w / 2) - (from.x + from.w / 2)
  var dy = (to.y + to.h / 2) - (from.y + from.h / 2)
  return Math.abs(dx) >= Math.abs(dy)
    ? (dx > 0 ? "r" : "l")
    : (dy > 0 ? "d" : "u")
}

// The direction that walks focus one place along the reading order of
// `reading`, given `step` of +1 or -1. Empty string means there is nowhere to
// go: the order does not wrap.
//
// A direction rather than a window, because a compositor may only be able to
// push focus one way or another. Taking it from the two windows themselves
// walks down a stacked band as readily as it crosses the workspace, and needs
// to know nothing about the layout doing the stacking.
function stepDirection(reading, step) {
  var order = reading.order
  var from = reading.activeIndex >= 0 ? order[reading.activeIndex] : null
  var to = from ? order[reading.activeIndex + step] : null

  if (from && to) return directionBetween(from, to)

  // Focus is already on the first or last window in the order.
  if (from) return ""

  // Nothing in this reading has focus -- a floating window holds it, or it is
  // on another screen. Push along the grain and let the next read report
  // wherever it landed.
  return reading.grain === "rows"
    ? (step > 0 ? "d" : "u")
    : (step > 0 ? "r" : "l")
}
