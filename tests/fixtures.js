"use strict";

// Workspaces to read, as a compositor would report them: a 2560x1440 screen
// with a 38px bar along the top, 10px of outer gap and 5px between windows, so
// the tiling area is x 10..2550, y 48..1430.
//
// Coordinates are real rather than tidy on purpose. The reader's whole job is
// to find the gaps between rectangles, and rectangles that line up perfectly
// would let a broken reader pass.

function win(address, x, y, w, h) {
  return { address: address, x: x, y: y, w: w, h: h };
}

module.exports = {
  win: win,

  // Nothing at all.
  empty: [],

  // A workspace holding one window, which fills the tiling area.
  single: [win("a", 10, 48, 2540, 1382)],

  // Two windows side by side: scrolling, dwindle and master all agree here.
  twoColumns: [
    win("a", 10, 48, 1262, 1382),
    win("b", 1287, 48, 1263, 1382)
  ],

  // Four windows under dwindle: three columns, the middle one carrying two
  // windows stacked. This is the arrangement in the README's screenshot.
  dwindle: [
    win("a", 10, 48, 840, 1382),
    win("b1", 865, 48, 840, 686),
    win("b2", 865, 744, 840, 686),
    win("c", 1720, 48, 830, 1382)
  ],

  // A rows layout: one window across the top, two side by side beneath it.
  // There is no vertical cut to find, so this can only read as rows -- the
  // case the old left-edge bucketing could not represent at all.
  rows: [
    win("top", 10, 48, 2540, 686),
    win("bl", 10, 744, 1262, 686),
    win("br", 1287, 744, 1263, 686)
  ],

  // A 2x2 grid, which reads either way. Columns win.
  grid: [
    win("tl", 10, 48, 1262, 686),
    win("bl", 10, 744, 1262, 686),
    win("tr", 1287, 48, 1263, 686),
    win("br", 1287, 744, 1263, 686)
  ],

  // A Lua layout: 25/50/25 with the overflow stacked into the right-hand
  // column. Seven windows, and a stack deep enough to trip maxStackedWindows.
  luaThirds: [
    win("left", 10, 48, 625, 1382),
    win("middle", 650, 48, 1265, 1382),
    win("r1", 1930, 48, 620, 272),
    win("r2", 1930, 325, 620, 272),
    win("r3", 1930, 602, 620, 272),
    win("r4", 1930, 879, 620, 272),
    win("r5", 1930, 1156, 620, 274)
  ],

  // Mid-animation: the right-hand column has been caught 12px inside the left
  // one's edge as it slides into place. Under the default tolerance this is
  // still two columns.
  sliding: [
    win("a", 10, 48, 1262, 1382),
    win("b", 1260, 48, 1290, 1382)
  ],

  // Genuinely overlapping: b sits 200px inside a, which is well past anything
  // an animation would explain.
  overlapping: [
    win("a", 10, 48, 1262, 1382),
    win("b", 1072, 48, 1478, 1382)
  ],

  // A fullscreen window over a workspace that is still tiling two others
  // underneath it. No line crosses the workspace without meeting the
  // fullscreen window, so there is no cut to find.
  fullscreen: [
    win("fs", 0, 0, 2560, 1440),
    win("a", 10, 48, 1262, 1382),
    win("b", 1287, 48, 1263, 1382)
  ],

  // Two windows reported at the same place, as happens for a moment when one
  // is swapped into another's slot.
  stacked: [
    win("a", 10, 48, 1262, 1382),
    win("b", 10, 48, 1262, 1382)
  ]
};
