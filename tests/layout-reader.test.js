#!/usr/bin/env node
"use strict";

// Tests for LayoutReader.js. No dependencies: `node tests/layout-reader.test.js`.
//
// The reader is the part of this widget that can be wrong without looking
// wrong -- a mis-cut workspace still draws a perfectly plausible row of pips --
// so it is also the part worth pinning down. Every fixture here is a workspace
// some layout really produces.

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const F = require("./fixtures.js");

// LayoutReader.js is a QML JavaScript library, which is why it is loaded like
// this rather than required. The only thing in it that is not plain JavaScript
// is the `.pragma library` header the QML engine wants, so strip that one line
// and the rest evaluates anywhere; the QML engine takes the top-level
// declarations as the module's surface, and so does the tail below.
//
// Loading the shipped file rather than a copy of it is the point: these tests
// fail when the widget changes.
const SURFACE = [
  "read", "cutAlong", "splitOnce", "flattenBand",
  "directionBetween", "stepDirection", "toleranceOr", "DEFAULT_TOLERANCE"
];

function loadReader() {
  const file = path.join(__dirname, "..", "LayoutReader.js");
  const source = fs.readFileSync(file, "utf8").replace(/^\.pragma\s+library\s*$/m, "");
  const tail = "\nreturn { " + SURFACE.join(", ") + " };";
  return new Function(source + tail)();
}

const R = loadReader();

// The reading, written the way the README describes one: the grain, then the
// bands in order with the windows inside them. Comparing this rather than the
// object makes a failure legible -- you get the shape that came back, not a
// diff of seven rectangles.
function shape(reading) {
  const bands = reading.bands
    .map((band) => "[" + band.map((w) => w.address).join(" ") + "]")
    .join(" ");
  return reading.grain + ": " + bands;
}

// Walk focus from `address` in `step` increments until it stops moving, and
// report where each step aimed. Every layout should be traversable end to end.
function walk(windows, address, step) {
  const aimed = [];
  let at = address;
  for (let guard = 0; guard < windows.length + 1; guard++) {
    const reading = R.read(windows, at, R.DEFAULT_TOLERANCE);
    const direction = R.stepDirection(reading, step);
    if (direction === "") break;
    aimed.push(direction);
    at = reading.order[reading.activeIndex + step].address;
  }
  return aimed.join(" ");
}

let failures = 0;
let count = 0;

function test(name, body) {
  count++;
  try {
    body();
    console.log("  ok    " + name);
  } catch (error) {
    failures++;
    console.log("  FAIL  " + name);
    console.log(String(error.message).split("\n").map((l) => "        " + l).join("\n"));
  }
}

console.log("\nreading the arrangement\n");

test("an empty workspace reads as nothing, not as one empty band", () => {
  const reading = R.read(F.empty, "");
  assert.deepStrictEqual(reading.bands, []);
  assert.strictEqual(reading.windowCount, 0);
  assert.strictEqual(reading.deepestStack, 0);
  assert.strictEqual(reading.activeBand, -1);
  assert.strictEqual(reading.activeIndex, -1);
  assert.strictEqual(reading.grain, "columns");
});

test("one window is one band of one", () => {
  const reading = R.read(F.single, "a");
  assert.strictEqual(shape(reading), "columns: [a]");
  assert.strictEqual(reading.activeBand, 0);
  assert.strictEqual(reading.activeIndex, 0);
  assert.strictEqual(reading.deepestStack, 1);
});

test("two side by side are two columns", () => {
  assert.strictEqual(shape(R.read(F.twoColumns, "b")), "columns: [a] [b]");
});

test("dwindle: three columns, the middle one stacked", () => {
  const reading = R.read(F.dwindle, "b2");
  assert.strictEqual(shape(reading), "columns: [a] [b1 b2] [c]");
  assert.strictEqual(reading.activeBand, 1);
  assert.strictEqual(reading.activeIndex, 2);
  assert.strictEqual(reading.windowCount, 4);
  assert.strictEqual(reading.deepestStack, 2);
});

test("a rows layout reads as rows, not as one fat column", () => {
  const reading = R.read(F.rows, "bl");
  assert.strictEqual(shape(reading), "rows: [top] [bl br]");
  assert.strictEqual(reading.activeBand, 1);
  assert.strictEqual(reading.activeIndex, 1);
});

test("a grid reads either way, and comes back as columns", () => {
  const reading = R.read(F.grid, "br");
  assert.strictEqual(shape(reading), "columns: [tl bl] [tr br]");
  assert.strictEqual(reading.activeBand, 1);
  assert.strictEqual(reading.activeIndex, 3);
});

test("a Lua 25/50/25 with the overflow stacked into one column", () => {
  const reading = R.read(F.luaThirds, "r3");
  assert.strictEqual(shape(reading), "columns: [left] [middle] [r1 r2 r3 r4 r5]");
  assert.strictEqual(reading.activeBand, 2);
  assert.strictEqual(reading.activeIndex, 4);
  assert.strictEqual(reading.deepestStack, 5);
});

console.log("\nwindows that do not sit still\n");

test("a column caught 12px inside its neighbour mid-animation still cuts", () => {
  assert.strictEqual(shape(R.read(F.sliding, "b")), "columns: [a] [b]");
});

test("a 200px overlap is not an animation, and does not cut", () => {
  const reading = R.read(F.overlapping, "b");
  assert.strictEqual(shape(reading), "columns: [a b]");
  assert.strictEqual(reading.deepestStack, 2);
});

test("tolerance is a parameter: at zero, the sliding pair stops cutting", () => {
  assert.strictEqual(shape(R.read(F.sliding, "b", 0)), "columns: [a b]");
});

test("two windows reported at the same place are read top-left first", () => {
  const reading = R.read(F.stacked, "b");
  assert.strictEqual(shape(reading), "columns: [a b]");
  assert.strictEqual(reading.windowCount, 2);
  assert.strictEqual(reading.activeIndex, 1);
});

test("a fullscreen window swallows the cut, and the count stays right", () => {
  // A known limitation rather than a desired reading: nothing crosses the
  // workspace without meeting the fullscreen window, so there is no cut to
  // find and all three pile into one band. The strip is wrong about the shape
  // and right about the number, which is the failure worth having.
  const reading = R.read(F.fullscreen, "fs");
  assert.strictEqual(shape(reading), "columns: [fs a b]");
  assert.strictEqual(reading.windowCount, 3);
  assert.strictEqual(reading.activeIndex, 0);
});

console.log("\nfocus\n");

test("no focused address leaves the highlight off", () => {
  const reading = R.read(F.dwindle, "");
  assert.strictEqual(reading.activeBand, -1);
  assert.strictEqual(reading.activeIndex, -1);
  assert.strictEqual(reading.windowCount, 4);
});

test("an address that is not on the workspace leaves the highlight off", () => {
  const reading = R.read(F.dwindle, "somewhere-else");
  assert.strictEqual(reading.activeIndex, -1);
});

test("reading order runs across the bands and down inside one", () => {
  const order = R.read(F.dwindle, "").order.map((w) => w.address);
  assert.deepStrictEqual(order, ["a", "b1", "b2", "c"]);
});

console.log("\nwalking focus\n");

test("a step aims wherever the next window actually lies", () => {
  const reading = R.read(F.dwindle, "a");
  assert.strictEqual(R.stepDirection(reading, 1), "r");
  assert.strictEqual(R.stepDirection(R.read(F.dwindle, "b1"), 1), "d");
  assert.strictEqual(R.stepDirection(R.read(F.dwindle, "b2"), 1), "r");
});

test("the order does not wrap at either end", () => {
  assert.strictEqual(R.stepDirection(R.read(F.dwindle, "a"), -1), "");
  assert.strictEqual(R.stepDirection(R.read(F.dwindle, "c"), 1), "");
});

test("dwindle is traversable end to end, and back", () => {
  assert.strictEqual(walk(F.dwindle, "a", 1), "r d r");
  assert.strictEqual(walk(F.dwindle, "c", -1), "l u l");
});

test("a rows layout steps down into its rows", () => {
  assert.strictEqual(walk(F.rows, "top", 1), "d r");
});

test("stepping into a deep stack walks down it one window at a time", () => {
  assert.strictEqual(walk(F.luaThirds, "middle", 1), "r d d d d");
});

test("with nothing focused, a step pushes along the grain", () => {
  assert.strictEqual(R.stepDirection(R.read(F.dwindle, ""), 1), "r");
  assert.strictEqual(R.stepDirection(R.read(F.dwindle, ""), -1), "l");
  assert.strictEqual(R.stepDirection(R.read(F.rows, ""), 1), "d");
  assert.strictEqual(R.stepDirection(R.read(F.rows, ""), -1), "u");
});

test("direction is measured between centres, not edges", () => {
  // The bottom-right window of a rows layout, against the full-width row above
  // it. Their left edges are 1277px apart and their top edges 696px, so an
  // edge reading calls this sideways; between the centres it is what it looks
  // like, which is the row below.
  const top = F.rows[0];
  const br = F.rows[2];
  assert.strictEqual(R.directionBetween(top, br), "d");
  assert.strictEqual(R.directionBetween(br, top), "u");

  // A short window beside a tall one: far apart at the top, close at the
  // centre, and sideways either way.
  const tall = F.win("tall", 10, 48, 1262, 1382);
  const short = F.win("short", 1287, 600, 1263, 280);
  assert.strictEqual(R.directionBetween(tall, short), "r");
  assert.strictEqual(R.directionBetween(short, tall), "l");
});

console.log("\nthe pieces underneath\n");

test("cutAlong returns the pieces in order along the axis", () => {
  const bands = R.cutAlong(F.dwindle, "x", R.DEFAULT_TOLERANCE);
  assert.deepStrictEqual(bands.map((b) => b.map((w) => w.address)),
    [["a"], ["b1", "b2"], ["c"]]);
});

test("splitOnce reports the axis it cut on, and '' when it could not", () => {
  assert.strictEqual(R.splitOnce(F.dwindle).axis, "x");
  assert.strictEqual(R.splitOnce(F.rows).axis, "y");
  assert.strictEqual(R.splitOnce(F.stacked).axis, "");
});

test("the windows handed in are the objects handed back", () => {
  const reading = R.read(F.twoColumns, "a");
  assert.strictEqual(reading.bands[0][0], F.twoColumns[0]);
  assert.strictEqual(reading.order[1], F.twoColumns[1]);
});

test("reading does not disturb the array it was given", () => {
  const before = F.dwindle.map((w) => w.address);
  R.read(F.dwindle, "b1", R.DEFAULT_TOLERANCE);
  assert.deepStrictEqual(F.dwindle.map((w) => w.address), before);
});

test("the tolerance defaults when it is left out or nonsense", () => {
  assert.strictEqual(R.toleranceOr(undefined), R.DEFAULT_TOLERANCE);
  assert.strictEqual(R.toleranceOr(null), R.DEFAULT_TOLERANCE);
  assert.strictEqual(R.toleranceOr(NaN), R.DEFAULT_TOLERANCE);
  assert.strictEqual(R.toleranceOr(0), 0);
});

console.log("\n" + (failures === 0
  ? count + " passed"
  : failures + " of " + count + " failed") + "\n");

process.exit(failures === 0 ? 0 : 1);
