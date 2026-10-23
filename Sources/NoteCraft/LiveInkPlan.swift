// What the live stroke needs on one frame. Segment `i` (from the midpoint before sample `i - 1`,
// bent towards it, to the midpoint before sample `i`) needs samples `i - 2 ... i`, so it is final
// once sample `i` exists, and it stays final unless a sample it uses is still waiting for its
// measured Pencil force. Final segments are baked once; the rest is redrawn every frame together
// with the predicted samples.
struct LiveInkPlan: Equatable {
  // Segments to bake now.
  let bake: Range<Int>
  // The new baked-through index.
  let bakedThrough: Int
  // The tail starts at this sample, and its first segment is this index into the tail's samples.
  let tailStart: Int
  let tailFirstSegment: Int

  init(count: Int, bakedThrough: Int, firstPending: Int?) {
    // The second-to-last sample is the newest whose successor is known.
    var stable = count - 2
    if let firstPending { stable = min(stable, firstPending - 1) }
    self.bakedThrough = max(bakedThrough, stable)
    bake = (bakedThrough + 1)..<(self.bakedThrough + 1)
    // One baked sample is kept in the tail: the first tail segment starts at its midpoint with its
    // tangent.
    tailStart = max(0, self.bakedThrough - 1)
    tailFirstSegment = max(1, self.bakedThrough + 1 - tailStart)
  }
}
