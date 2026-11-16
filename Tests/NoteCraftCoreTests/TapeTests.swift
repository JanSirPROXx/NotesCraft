import Foundation
import Testing

@testable import NoteCraftCore

private func ink(_ points: [Point], width: Double = 2, tool: InkTool = .pen) -> Stroke {
  Stroke(samples: points.map { Sample(point: $0) }, width: width, tool: tool)
}

// A word on a line: a few short strokes from `x` to `x + 60` at height `y`.
private func word(at x: Double, _ y: Double) -> [Stroke] {
  (0..<4).map { i in
    let left = x + Double(i) * 16
    return ink((0...8).map { Point(left + Double($0), y + ($0.isMultiple(of: 2) ? -4 : 4)) })
  }
}

private func strip(
  from a: Point, to b: Point, width: Double = 24, revealed: Bool = false
) -> Stroke {
  var tape = Stroke.tape(along: [a, b], color: .yellow, width: width, pattern: .stripes, straight: true)!
  tape.tape?.revealed = revealed
  return tape
}

private func swipe(from a: Point, to b: Point, steps: Int = 40) -> [Point] {
  (0...steps).map { i in
    let t = Double(i) / Double(steps)
    return Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
  }
}

// MARK: the strip a drag lays down

@Test func aStraightStripRunsFromWhereThePenCameDownToWhereItLifted() throws {
  let wobble = [Point(100, 200), Point(180, 230), Point(260, 190), Point(340, 260)]
  let tape = try #require(
    Stroke.tape(along: wobble, color: .yellow, width: 22, pattern: .dots, straight: true))
  #expect(tape.samples.map(\.point) == [Point(100, 200), Point(340, 260)])
  #expect(tape.tape == Tape(pattern: .dots, revealed: false))
  #expect(tape.width == 22)
  #expect(tape.isCover)
}

@Test func aStripThatIsNearlyLevelOrUprightIsMadeExactlySo() throws {
  let level = try #require(
    Stroke.tape(
      along: [Point(100, 200), Point(400, 208)], color: .yellow, width: 22, pattern: .plain,
      straight: true))
  #expect(level.samples.last?.point == Point(400, 200))
  let upright = try #require(
    Stroke.tape(
      along: [Point(100, 200), Point(94, 500)], color: .yellow, width: 22, pattern: .plain,
      straight: true))
  #expect(upright.samples.last?.point == Point(100, 500))
  // A line of handwriting that climbs is followed, not flattened.
  let climbing = try #require(
    Stroke.tape(
      along: [Point(100, 200), Point(400, 170)], color: .yellow, width: 22, pattern: .plain,
      straight: true))
  #expect(climbing.samples.last?.point == Point(400, 170))
}

@Test func aTapIsNotAStrip() {
  #expect(
    Stroke.tape(
      along: [Point(100, 200), Point(101, 201)], color: .yellow, width: 22, pattern: .plain,
      straight: true) == nil)
  #expect(
    Stroke.tape(along: [Point(100, 200)], color: .yellow, width: 22, pattern: .plain, straight: false)
      == nil)
  #expect(Stroke.tape(along: [], color: .yellow, width: 22, pattern: .plain, straight: true) == nil)
}

@Test func aStripDrawnByHandKeepsItsEndsAndLosesTheJitter() throws {
  // An arc sampled as a pen would, with a tremble of a point on every other sample.
  let path = (0...200).map { i -> Point in
    let t = Double(i) / 200
    let tremble = i.isMultiple(of: 2) ? 1.0 : -1.0
    return Point(100 + 300 * t, 300 - 120 * sin(t * .pi) + tremble)
  }
  let tape = try #require(
    Stroke.tape(along: path, color: .blue, width: 24, pattern: .checks, straight: false))
  let points = tape.samples.map(\.point)
  #expect(points.first == path.first)
  #expect(points.last == path.last)
  #expect(points.count < path.count / 3, "evenly spaced, not every pen sample")
  // The strip follows the arc: its top is near the top of the arc.
  #expect(abs((points.map(\.y).min() ?? 0) - 180) < 4)
  // No point steps back along the strip, which is what jitter looks like on a wide band.
  for (a, b) in zip(points, points.dropFirst()) { #expect(b.x > a.x) }
}

// MARK: stored the way older builds can read

@Test func aStripIsStoredAsAPenStrokeWithATapeMarker() throws {
  var tape = strip(from: Point(100, 100), to: Point(300, 100))
  tape.tape?.pattern = .checks
  let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tape)) as? [String: Any]
  #expect(json?["tool"] as? String == "pen", "an older build must be able to decode the stroke")
  let stored = try #require(json?["tape"] as? [String: Any])
  #expect(stored["pattern"] as? String == "checks")
  #expect(stored["revealed"] == nil, "only written once a strip is peeled back")
  let decoded = try JSONDecoder().decode(Stroke.self, from: JSONEncoder().encode(tape))
  #expect(decoded == tape)

  tape.tape?.revealed = true
  let peeled = try JSONDecoder().decode(Stroke.self, from: JSONEncoder().encode(tape))
  #expect(peeled.tape?.revealed == true)
  #expect(!peeled.isCover)
}

@Test func inkWithoutAMarkerIsNotTapeAndAnUnknownPatternIsPlain() throws {
  let plain = try JSONDecoder().decode(
    Stroke.self, from: JSONEncoder().encode(ink([Point(1, 1), Point(9, 9)])))
  #expect(plain.tape == nil)
  #expect(!plain.isTape)
  // A pattern a later version adds must not make the page unreadable.
  let later = try JSONDecoder().decode(Tape.self, from: Data(#"{"pattern":"glitter"}"#.utf8))
  #expect(later == Tape(pattern: .plain, revealed: false))
}

@Test func aNotebookWithTapeSurvivesAPackageRoundTrip() throws {
  var page = Page()
  page.strokes = word(at: 100, 200) + [strip(from: Point(90, 200), to: Point(180, 200))]
  page.strokes[4].tape?.revealed = true
  let package = NotebookPackage(notebook: Notebook(pages: [page]))
  let restored = try NotebookPackage(fileWrapper: package.fileWrapper())
  #expect(restored.notebook.pages[0].strokes == page.strokes)
  #expect(restored.notebook.pages[0].tapes.count == 1)
}

// MARK: tapping

@Test func aTapPeelsTheStripUnderItAndAnotherCoversItAgain() {
  var page = Page()
  page.strokes = word(at: 100, 200) + [strip(from: Point(90, 200), to: Point(180, 200))]
  // `#expect` cannot call a mutating method on what it checks, so each answer gets a name.
  let peeled = page.toggleTape(at: Point(130, 205))
  #expect(peeled)
  #expect(page.tapes.first?.tape?.revealed == true)
  let covered = page.toggleTape(at: Point(130, 205))
  #expect(covered)
  #expect(page.tapes.first?.tape?.revealed == false)
  // Beside the strip nothing happens, also right on the ink it does not cover.
  let before = page
  let below = page.toggleTape(at: Point(130, 230))
  let beside = page.toggleTape(at: Point(260, 200))
  #expect(!below)
  #expect(!beside)
  #expect(page == before)
  // A fingertip gets some slack.
  let nearby = page.toggleTape(at: Point(130, 216), tolerance: 6)
  #expect(nearby)
}

@Test func whereStripsOverlapTheTapReachesTheOneOnTop() {
  var page = Page()
  let lower = strip(from: Point(100, 200), to: Point(300, 200))
  let upper = strip(from: Point(200, 150), to: Point(200, 250))
  page.strokes = [lower, upper]
  #expect(page.tape(at: Point(200, 200))?.id == upper.id)
  #expect(page.tape(at: Point(120, 200))?.id == lower.id)
  page.toggleTape(at: Point(200, 200))
  #expect(page.strokes[1].tape?.revealed == true)
  #expect(page.strokes[0].tape?.revealed == false)
}

@Test func aStripFollowsItsPathNotItsBoundingBox() {
  // A slanted strip: the corners of its box are far from the band.
  let slanted = strip(from: Point(100, 100), to: Point(300, 300), width: 20)
  #expect(slanted.tapeCovers(Point(200, 200)))
  #expect(slanted.tapeCovers(Point(206, 194)))
  #expect(!slanted.tapeCovers(Point(280, 120)))
  // Its ends are cut off square: just past an end is open paper.
  let level = strip(from: Point(100, 200), to: Point(300, 200), width: 20)
  #expect(level.tapeCovers(Point(299, 208)))
  #expect(!level.tapeCovers(Point(304, 200)))
  #expect(level.tapeCovers(Point(304, 200), slack: 6))
  #expect(!ink([Point(100, 100), Point(300, 300)], width: 20).tapeCovers(Point(200, 200)))
}

@Test func allStripsOfAPageAreCoveredRevealedOrRemovedTogether() {
  var page = Page()
  let writing = word(at: 100, 200)
  page.strokes =
    writing + [
      strip(from: Point(90, 200), to: Point(180, 200)),
      strip(from: Point(90, 300), to: Point(180, 300), revealed: true),
    ]
  page.setTapes(revealed: true)
  #expect(page.tapes.allSatisfy { $0.tape?.revealed == true })
  page.setTapes(revealed: false)
  #expect(page.tapes.allSatisfy { $0.isCover })
  #expect(page.strokes.prefix(4).elementsEqual(writing), "the writing is not touched")
  page.removeTapes()
  #expect(page.strokes == writing)
}

@Test func aTapWithTheLassoPicksTheStripNotWhatItHides() {
  var page = Page()
  let tape = strip(from: Point(90, 200), to: Point(180, 200))
  // The strip was laid first and the word written afterwards: tape is on top all the same.
  page.strokes = [tape] + word(at: 100, 200)
  #expect(InkGestures.objectID(at: Point(104, 200), page: page, tolerance: 4) == tape.id)
}

// MARK: the eraser takes what can be seen

@Test(arguments: EraserMode.allCases)
func theEraserTakesACoveredStripAndLeavesWhatItHides(mode: EraserMode) {
  let writing = word(at: 100, 200)
  let tape = strip(from: Point(90, 200), to: Point(180, 200))
  // One swipe along the whole strip: first it meets the tape, then it runs over the hidden word.
  let once = Editing.erase(
    strokes: writing + [tape], along: swipe(from: Point(80, 200), to: Point(190, 200)), radius: 10,
    mode: mode, highlighterOnly: false)
  #expect(once == writing, "the strip is gone as a whole, the word under it is untouched")
  // The word can be seen now: the next swipe erases it.
  let twice = Editing.erase(
    strokes: once, along: swipe(from: Point(80, 200), to: Point(190, 200)), radius: 10, mode: mode,
    highlighterOnly: false)
  #expect(twice.count < writing.count || twice.map(\.samples.count) != writing.map(\.samples.count))
}

@Test(arguments: EraserMode.allCases)
func aWideEraserComingFromOutsideDoesNotReachUnderAStrip(mode: EraserMode) {
  // A line in the middle of a strip. The eraser crosses both from above: its edge is over the
  // line while its middle is still on open paper.
  let hidden = ink([Point(100, 200), Point(170, 200)], width: 2.5)
  let tape = strip(from: Point(90, 200), to: Point(180, 200), width: 22)
  let result = Editing.erase(
    strokes: [hidden, tape], along: swipe(from: Point(135, 150), to: Point(135, 250)), radius: 12,
    mode: mode, highlighterOnly: false)
  #expect(result == [hidden], "the strip goes, the line under it is exactly as it was")
}

@Test func inkThatSticksOutFromUnderAStripIsErasedWhereItShows() {
  let long = ink(swipe(from: Point(100, 200), to: Point(260, 200), steps: 80), width: 2.5)
  let tape = strip(from: Point(90, 200), to: Point(180, 200), width: 22)
  // Hit in the open with a stroke eraser: the stroke can be seen there, so it goes. The strip is
  // never under the middle of the eraser and stays.
  let whole = Editing.erase(
    strokes: [long, tape], along: swipe(from: Point(230, 170), to: Point(230, 230)), radius: 8,
    mode: .stroke, highlighterOnly: false)
  #expect(whole == [tape])
  // A precise eraser run along the line, from its open end into the strip: the strip goes when
  // the eraser reaches it, the line is rubbed out as far as it showed, and the rest is kept.
  let precise = Editing.erase(
    strokes: [long, tape], along: swipe(from: Point(270, 200), to: Point(120, 200), steps: 80),
    radius: 6, mode: .precision, highlighterOnly: false)
  #expect(!precise.contains { $0.isTape })
  let left = precise.flatMap(\.samples).map(\.point.x)
  #expect(left.min() == 100, "the hidden end is untouched")
  #expect((left.max() ?? 0) <= 181 && (left.max() ?? 0) >= 170, "kept up to the edge of the strip")
}

@Test func theEraserGoesThroughAStripThatIsPeeledBack() {
  let writing = word(at: 100, 200)
  let tape = strip(from: Point(90, 200), to: Point(180, 200), revealed: true)
  let result = Editing.erase(
    strokes: writing + [tape], along: swipe(from: Point(80, 200), to: Point(190, 200)), radius: 10,
    mode: .stroke, highlighterOnly: false)
  #expect(result == [tape], "what can be read is erased, the strip stays to be covered again")
}

@Test func erasingBesideAStripLeavesTheStrip() {
  // A word right under the strip, in the open. The eraser's edge reaches the band, its middle not.
  let visible = word(at: 100, 222)
  let tape = strip(from: Point(90, 200), to: Point(180, 200), width: 24)
  let result = Editing.erase(
    strokes: visible + [tape], along: swipe(from: Point(80, 222), to: Point(190, 222)), radius: 10,
    mode: .stroke, highlighterOnly: false)
  #expect(result == [tape])
}

@Test func eraseHighlighterOnlyLeavesTape() {
  let tape = strip(from: Point(90, 200), to: Point(180, 200))
  // One line of marker under the strip and one in the open below it.
  let hidden = ink([Point(90, 200), Point(180, 200)], width: 16, tool: .highlighter)
  let open = ink([Point(90, 240), Point(180, 240)], width: 16, tool: .highlighter)
  let overTape = Editing.erase(
    strokes: [hidden, open, tape], along: swipe(from: Point(80, 200), to: Point(190, 200)),
    radius: 10, mode: .stroke, highlighterOnly: true)
  #expect(overTape == [hidden, open, tape], "the strip is not marker, and what it hides is safe")
  let overMarker = Editing.erase(
    strokes: [hidden, open, tape], along: swipe(from: Point(80, 240), to: Point(190, 240)),
    radius: 10, mode: .stroke, highlighterOnly: true)
  #expect(overMarker == [hidden, tape])
}

@Test func aSessionReportsTheAreaOfAStripItTookAndStillKnowsTheInkUnderIt() {
  let writing = word(at: 100, 200)
  let tape = strip(from: Point(90, 200), to: Point(180, 200))
  var session = EraseSession(strokes: writing + [tape])
  let area = session.erase(at: Point(120, 200), radius: 8, mode: .stroke, highlighterOnly: false)
  #expect(area != nil)
  if let area {
    #expect(area.x <= 78 && area.x + area.width >= 192, "the whole strip has to be repainted")
  }
  #expect(session.strokes == writing)
  // The same gesture goes on over the word: it was hidden when the gesture began.
  #expect(session.erase(at: Point(140, 200), radius: 8, mode: .stroke, highlighterOnly: false) == nil)
  #expect(session.strokes(reaching: Rect(x: 90, y: 190, width: 100, height: 20)) == writing)
}

@Test func tapeDoesNotWidenTheEraserSearchForInk() {
  // Ink 30 points from the eraser is out of reach whether or not a 40 point strip is on the page.
  let far = ink([Point(100, 100), Point(160, 100)])
  let tape = strip(from: Point(100, 400), to: Point(300, 400), width: 40)
  var session = EraseSession(strokes: [far, tape])
  #expect(session.erase(at: Point(130, 130), radius: 10, mode: .stroke, highlighterOnly: false) == nil)
  #expect(session.strokes.count == 2)
}

// MARK: gestures that read ink leave tape alone

@Test func aScribbleLeavesTapeAndWhatItHides() throws {
  let writing = word(at: 100, 200)
  // A scrub back and forth over the word.
  var scrub: [Point] = []
  for pass in 0..<8 {
    let y = 192.0 + Double(pass) * 2.5
    scrub += pass.isMultiple(of: 2)
      ? swipe(from: Point(92, y), to: Point(172, y), steps: 20)
      : swipe(from: Point(172, y), to: Point(92, y), steps: 20)
  }
  let open = try #require(InkGestures.scratchOutcome(scrub, strokes: writing))
  #expect(open.strokes.isEmpty, "without tape the scribble erases the word")
  let tape = strip(from: Point(90, 200), to: Point(180, 200), width: 30)
  #expect(InkGestures.scratchOutcome(scrub, strokes: writing + [tape]) == nil)
  // Peeled back, the word can be seen and scribbled out; the strip stays.
  var peeled = tape
  peeled.tape?.revealed = true
  let seen = try #require(InkGestures.scratchOutcome(scrub, strokes: writing + [peeled]))
  #expect(seen.strokes == [peeled])
}

@Test func aStripDrawnAsARingIsNotALoopToSelectWith() throws {
  let ring = (0...80).map { i -> Point in
    let angle = Double(i) / 80 * 2 * .pi
    return Point(200 + 60 * cos(angle), 200 + 60 * sin(angle))
  }
  #expect(InkGestures.loopPolygon(ink(ring)) != nil)
  let tape = try #require(
    Stroke.tape(along: ring, color: .yellow, width: 12, pattern: .plain, straight: false))
  #expect(tape.samples.count >= 12)
  #expect(InkGestures.loopPolygon(tape) == nil)
}

// MARK: what a change repaints

@Test func peelingAStripRepaintsOnlyTheStrip() {
  var page = Page()
  var pencil = ink([Point(300, 600), Point(360, 640)])
  pencil.style = .pencil
  page.strokes = word(at: 100, 200) + [pencil, strip(from: Point(90, 200), to: Point(180, 200))]
  var peeled = page
  peeled.toggleTape(at: Point(120, 200))
  guard case .area(let area) = PageDiff.change(from: page, to: peeled) else {
    Issue.record("a peeled strip is a local change, also on a page with pencil ink")
    return
  }
  #expect(area.contains(Point(90, 200)) && area.contains(Point(180, 200)))
  #expect(area.width < 250 && area.height < 200)
}

@Test func theTapeToolIsOnTheStandardBarAndReachesABarSavedBeforeIt() {
  #expect(ToolbarLayout.standard.visible.contains(.tape))
  let saved = ToolbarLayout(storedOrder: "eraser,pen,highlighter,shapes,lasso", storedHidden: "")
  #expect(saved.order.contains(.tape))
  #expect(saved.order.firstIndex(of: .tape)! > saved.order.firstIndex(of: .lasso)!)
}
