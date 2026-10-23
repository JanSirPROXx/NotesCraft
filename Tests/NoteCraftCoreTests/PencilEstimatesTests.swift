import Foundation
import Testing

@testable import NoteCraftCore

@Test func inkMayOnlyAdvanceToTheFirstSampleStillWaitingForItsMeasurement() {
  var pending = PendingEstimates()
  #expect(pending.earliest == nil)
  pending.expect(updateIndex: 7, forSample: 4)
  pending.expect(updateIndex: 8, forSample: 5)
  pending.expect(updateIndex: 9, forSample: 6)
  #expect(pending.earliest == 4)

  // A first refinement arrives but more are due: the sample keeps holding the ink back.
  #expect(pending.receive(updateIndex: 7, complete: false) == 4)
  #expect(pending.earliest == 4)
  #expect(pending.receive(updateIndex: 7, complete: true) == 4)
  #expect(pending.earliest == 5)

  // Out of order is fine.
  #expect(pending.receive(updateIndex: 9, complete: true) == 6)
  #expect(pending.earliest == 5)
  #expect(pending.receive(updateIndex: 8, complete: true) == 5)
  #expect(pending.isEmpty)
}

@Test func anUpdateThisStrokeNeverAskedForIsIgnored() {
  var pending = PendingEstimates()
  pending.expect(updateIndex: 3, forSample: 1)
  // A late update of the previous stroke carries an index that is not waiting here.
  #expect(pending.receive(updateIndex: 99, complete: true) == nil)
  #expect(pending.earliest == 1)
  pending.removeAll()
  #expect(pending.receive(updateIndex: 3, complete: true) == nil)
}

@Test func anUpdateThatNeverArrivesStopsHoldingTheInkBack() {
  var pending = PendingEstimates()
  pending.expect(updateIndex: 1, forSample: 2)
  pending.expect(updateIndex: 2, forSample: 40)
  pending.expire(newest: 41)
  #expect(pending.earliest == 40)
  pending.expire(newest: 200)
  #expect(pending.isEmpty)
}
