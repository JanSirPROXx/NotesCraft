import Foundation

// What a page edit changed on the page as drawn, so a page that is kept as tiles only redraws the
// tiles the edit reaches: an undone stroke at 6x zoom is a handful of tiles, not the whole screen.
public enum PageChange: Equatable, Sendable {
  case none
  // The edit only touched pixels inside this rectangle (page units).
  case area(Rect)
  // Paper, order or text changed: nothing short of a redraw is safe.
  case everything
}

public enum PageDiff {
  public static func change(from old: Page, to new: Page) -> PageChange {
    if old == new { return .none }
    guard old.paper == new.paper, old.backgroundPDF == new.backgroundPDF,
      old.backgroundPage == new.backgroundPage, old.backgroundSize == new.backgroundSize,
      old.texts == new.texts
    else { return .everything }
    var area: Rect?
    func add(_ rect: Rect, pad: Double) {
      let padded = Rect(
        x: rect.x - pad, y: rect.y - pad, width: rect.width + 2 * pad, height: rect.height + 2 * pad)
      area = area.map { union($0, padded) } ?? padded
    }
    // Strokes and images are drawn in array order, so an item that moved in the order changes
    // the pixels between it and what it passed, outside anything that is listed as changed.
    guard let strokes = changed(old.strokes, new.strokes, id: \.id) else { return .everything }
    // Pencil strokes that follow each other are drawn as one run with one grain; an edit among
    // them regroups the run, which can change pixels beyond the edit. Appending at the end of
    // the page does not.
    if !strokes.isEmpty, old.strokes.contains(where: \.isPencil) || new.strokes.contains(where: \.isPencil) {
      let appendOnly =
        new.strokes.count > old.strokes.count && Array(new.strokes.prefix(old.strokes.count)) == old.strokes
      if !appendOnly { return .everything }
    }
    for stroke in strokes { add(stroke.bounds, pad: stroke.width * 2 + 2) }
    guard let images = changed(old.images, new.images, id: \.id) else { return .everything }
    for image in images { add(image.bounds, pad: 2) }
    return area.map { .area($0) } ?? .none
  }

  // The items that are new, gone or different, or nil when the ones that stayed are not in the
  // order they were in. Items are returned in both versions: the old pixels have to be cleaned up
  // as well as the new ones drawn.
  private static func changed<T: Equatable>(
    _ old: [T], _ new: [T], id: KeyPath<T, UUID>
  ) -> [T]? {
    var before: [UUID: T] = [:]
    before.reserveCapacity(old.count)
    for item in old { before[item[keyPath: id]] = item }
    var result: [T] = []
    var kept: [UUID] = []
    var after = Set<UUID>()
    after.reserveCapacity(new.count)
    for item in new {
      let key = item[keyPath: id]
      after.insert(key)
      if let previous = before[key] {
        kept.append(key)
        if previous != item {
          result.append(previous)
          result.append(item)
        }
      } else {
        result.append(item)
      }
    }
    var order = 0
    for item in old {
      let key = item[keyPath: id]
      if after.contains(key) {
        guard order < kept.count, kept[order] == key else { return nil }
        order += 1
      } else {
        result.append(item)
      }
    }
    return result
  }

  private static func union(_ a: Rect, _ b: Rect) -> Rect {
    let minX = min(a.x, b.x)
    let minY = min(a.y, b.y)
    return Rect(
      x: minX, y: minY, width: max(a.x + a.width, b.x + b.width) - minX,
      height: max(a.y + a.height, b.y + b.height) - minY)
  }
}
