import CoreGraphics
import Foundation
import ImageIO
import NoteCraftCore
import Testing
import UniformTypeIdentifiers

@testable import NoteCraft

// The packs that come with the marketplace, made by code so that they are exact and can be made
// again. `swift test` only checks that the committed catalog is valid; to write it again run
//
//   NOTECRAFT_BUILD_CATALOG=1 swift test --filter buildTheStarterCatalog
//
// which rewrites `catalog/` (index.json, packs/ and previews/). Pack content is deterministic: the
// same code makes the same bytes.

// MARK: drawing a page

private struct Ids {
  var seed: UInt8
  var next = 0
  mutating func make() -> UUID {
    next += 1
    return UUID(uuidString: String(format: "%08X-0000-4000-8000-%012X", UInt32(seed) << 16 | 0xC0DE, next))!
  }
}

private let paperLine = InkColor(red: 0.62, green: 0.65, blue: 0.70)
private let softLine = InkColor(red: 0.80, green: 0.82, blue: 0.86)
private let dark = InkColor(red: 0.16, green: 0.19, blue: 0.25)
private let mute = InkColor(red: 0.45, green: 0.49, blue: 0.56)

private struct PageDraft {
  var page = Page(paper: Paper(size: .a4, pattern: .blank))
  var ids: Ids

  init(ids: Ids) {
    self.ids = ids
    page.id = self.ids.make()
  }

  mutating func add(_ stroke: Stroke) {
    var s = stroke
    s.id = ids.make()
    page.strokes.append(s)
  }
  mutating func line(
    _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, width: Double = 1,
    color: InkColor = paperLine
  ) {
    add(.shape(.dragged(.line, from: Point(x1, y1), to: Point(x2, y2)), color: color, width: width))
  }
  mutating func box(
    _ x: Double, _ y: Double, _ w: Double, _ h: Double, width: Double = 1,
    color: InkColor = paperLine, fill: InkColor? = nil, rounded: Bool = false
  ) {
    add(
      .shape(
        .dragged(rounded ? .roundedRectangle : .rectangle, from: Point(x, y), to: Point(x + w, y + h)),
        color: color, width: width, fill: fill, fillOpacity: fill == nil ? nil : 1))
  }
  mutating func text(
    _ text: String, _ x: Double, _ y: Double, size: Double = 14, color: InkColor = dark,
    width: Double = 260, align: String? = nil
  ) {
    var box = TextBox(origin: Point(x, y), text: text)
    box.id = ids.make()
    box.size = size
    box.color = color
    box.boxWidth = width
    box.alignment = align
    page.texts.append(box)
  }
  // A square to tick.
  mutating func checkbox(_ x: Double, _ y: Double, size: Double = 14) {
    box(x, y, size, size, width: 1.2, color: mute, rounded: true)
  }
  // A row of lines to write on.
  mutating func ruling(from y: Double, to end: Double, spacing: Double, x1: Double, x2: Double) {
    var at = y
    while at <= end {
      line(x1, at, x2, at, width: 0.8, color: softLine)
      at += spacing
    }
  }
}

// MARK: pack definitions

private struct StarterPack {
  var entry: CatalogEntry  // size and hash are filled in when the pack is built
  var content: [String: Data]
  var preview: @MainActor (CGContext, CGSize) -> Void
}

private func notebookContent(_ pages: [Page], title: String) throws -> [String: Data] {
  var notebook = Notebook(title: title, pages: pages)
  notebook.id = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!
  let wrapper = try NotebookPackage(notebook: notebook).fileWrapper()
  guard let manifest = wrapper.fileWrappers?["manifest.json"]?.regularFileContents else {
    throw PackageError.invalidPackage
  }
  return ["manifest.json": manifest]
}

private func draft(
  _ id: String, _ kind: PackKind, _ name: String, _ category: CatalogCategory, _ summary: String,
  tags: [String], pages: Int? = nil
) -> CatalogEntry {
  CatalogEntry(
    id: id, kind: kind, name: name, author: "NotesCraft", summary: summary, category: category,
    tags: tags, version: "1.0", license: "CC0-1.0", file: "packs/\(id).ncpack",
    preview: "previews/\(id).png", size: 1, sha256: String(repeating: "0", count: 64), pages: pages)
}

// MARK: templates

private func cornell() throws -> StarterPack {
  var d = PageDraft(ids: Ids(seed: 1))
  d.text("Title", 40, 34, size: 12, color: mute)
  d.line(40, 74, 555, 74, width: 1.4, color: dark)
  d.text("Date", 400, 34, size: 12, color: mute)
  d.text("Cues & questions", 40, 90, size: 11, color: mute, width: 160)
  d.text("Notes", 215, 90, size: 11, color: mute, width: 200)
  d.line(205, 86, 205, 680, width: 1.2, color: dark)
  d.line(40, 680, 555, 680, width: 1.4, color: dark)
  d.ruling(from: 120, to: 660, spacing: 28, x1: 215, x2: 555)
  d.text("Summary", 40, 690, size: 11, color: mute)
  d.ruling(from: 740, to: 810, spacing: 28, x1: 40, x2: 555)
  return StarterPack(
    entry: draft(
      "free.template.cornell-notes", .template, "Cornell Notes", .study,
      "A page for lectures and reading: cues on the left, notes on the right, a summary at the bottom.",
      tags: ["lecture", "notes", "study"], pages: 1),
    content: try notebookContent([d.page], title: "Cornell Notes"),
    preview: { c, size in drawPage(d.page, in: c, size: size) })
}

private func todo() throws -> StarterPack {
  var d = PageDraft(ids: Ids(seed: 2))
  d.text("To-do", 40, 36, size: 30)
  d.text("Date", 430, 46, size: 12, color: mute, width: 120)
  d.line(40, 84, 555, 84, width: 1.4, color: dark)
  d.text("Today", 40, 100, size: 11, color: mute)
  for row in 0..<10 {
    let y = 128 + Double(row) * 34
    d.checkbox(44, y)
    d.line(70, y + 18, 555, y + 18, width: 0.8, color: softLine)
  }
  d.text("Later", 40, 480, size: 11, color: mute)
  for row in 0..<8 {
    let y = 508 + Double(row) * 34
    d.checkbox(44, y)
    d.line(70, y + 18, 555, y + 18, width: 0.8, color: softLine)
  }
  return StarterPack(
    entry: draft(
      "free.template.to-do-list", .template, "To-do List", .life,
      "Eighteen lines with a box to tick, split into today and later.",
      tags: ["tasks", "checklist"], pages: 1),
    content: try notebookContent([d.page], title: "To-do List"),
    preview: { c, size in drawPage(d.page, in: c, size: size) })
}

private func meeting() throws -> StarterPack {
  var d = PageDraft(ids: Ids(seed: 3))
  d.text("Meeting notes", 40, 34, size: 28)
  d.line(40, 80, 555, 80, width: 1.4, color: dark)
  d.text("Topic", 40, 92, size: 11, color: mute)
  d.line(90, 106, 555, 106, width: 0.8, color: softLine)
  d.text("Date", 40, 120, size: 11, color: mute)
  d.line(90, 134, 300, 134, width: 0.8, color: softLine)
  d.text("People", 320, 120, size: 11, color: mute)
  d.line(370, 134, 555, 134, width: 0.8, color: softLine)
  d.text("Agenda", 40, 160, size: 13, color: dark)
  d.box(40, 182, 515, 120, color: softLine, rounded: true)
  d.text("Notes", 40, 318, size: 13, color: dark)
  d.box(40, 340, 515, 290, color: softLine, rounded: true)
  d.text("Action items", 40, 646, size: 13, color: dark)
  for row in 0..<4 {
    let y = 672 + Double(row) * 34
    d.checkbox(44, y)
    d.line(70, y + 18, 400, y + 18, width: 0.8, color: softLine)
    d.line(420, y + 18, 555, y + 18, width: 0.8, color: softLine)
  }
  d.text("What", 70, 812, size: 10, color: mute, width: 100)
  d.text("Who", 420, 812, size: 10, color: mute, width: 100)
  return StarterPack(
    entry: draft(
      "free.template.meeting-notes", .template, "Meeting Notes", .work,
      "Topic, date and people, an agenda, room for notes, and action items with an owner.",
      tags: ["meeting", "agenda", "actions"], pages: 1),
    content: try notebookContent([d.page], title: "Meeting Notes"),
    preview: { c, size in drawPage(d.page, in: c, size: size) })
}

private func weeklyPage(ids: Ids, week: Int? = nil) -> PageDraft {
  var d = PageDraft(ids: ids)
  d.text(week.map { "Week \($0)" } ?? "Week of", 40, 30, size: 28)
  d.line(40, 76, 555, 76, width: 1.4, color: dark)
  let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
  let height = 92.0
  for (i, day) in days.enumerated() {
    let y = 92 + Double(i) * (height + 6)
    d.box(40, y, 515, height, color: softLine, rounded: true)
    d.text(day, 52, y + 8, size: 12, color: mute, width: 120)
    d.ruling(from: y + 40, to: y + height - 10, spacing: 22, x1: 52, x2: 543)
  }
  return d
}

private func weekly() throws -> StarterPack {
  let d = weeklyPage(ids: Ids(seed: 4))
  return StarterPack(
    entry: draft(
      "free.template.weekly-layout", .template, "Weekly Layout", .home,
      "One page for the whole week: a box with writing lines for every day, Monday to Sunday.",
      tags: ["week", "schedule"], pages: 1),
    content: try notebookContent([d.page], title: "Weekly Layout"),
    preview: { c, size in drawPage(d.page, in: c, size: size) })
}

private func groceries() throws -> StarterPack {
  var d = PageDraft(ids: Ids(seed: 5))
  d.text("Shopping list", 40, 36, size: 30)
  d.line(40, 84, 555, 84, width: 1.4, color: dark)
  let columns: [(String, Double)] = [("Fresh", 40), ("Pantry", 220), ("Other", 400)]
  for (title, x) in columns {
    d.text(title, x, 100, size: 12, color: mute, width: 140)
    for row in 0..<18 {
      let y = 128 + Double(row) * 36
      d.checkbox(x + 2, y)
      d.line(x + 26, y + 18, x + 150, y + 18, width: 0.8, color: softLine)
    }
  }
  return StarterPack(
    entry: draft(
      "free.template.shopping-list", .template, "Shopping List", .home,
      "Three columns of tick boxes: fresh food, the pantry, and everything else.",
      tags: ["groceries", "list"], pages: 1),
    content: try notebookContent([d.page], title: "Shopping List"),
    preview: { c, size in drawPage(d.page, in: c, size: size) })
}

// MARK: planners

private func weeklyPlanner() throws -> StarterPack {
  let pages = (1...4).map { weeklyPage(ids: Ids(seed: UInt8(10 + $0)), week: $0).page }
  return StarterPack(
    entry: draft(
      "free.planner.weekly-planner", .planner, "Weekly Planner", .work,
      "Four weeks, a page each, with a box for every day. Opens as a new notebook.",
      tags: ["week", "schedule", "month"], pages: 4),
    content: try notebookContent(pages, title: "Weekly Planner"),
    preview: { c, size in drawPage(pages[0], in: c, size: size) })
}

private func habitTracker() throws -> StarterPack {
  var d = PageDraft(ids: Ids(seed: 20))
  d.text("Habit tracker", 40, 30, size: 28)
  d.text("Month", 430, 40, size: 12, color: mute, width: 120)
  d.line(40, 76, 555, 76, width: 1.4, color: dark)
  let left = 150.0
  let cell = (555 - left) / 31
  for day in 1...31 {
    d.text("\(day)", left + Double(day - 1) * cell, 88, size: 7, color: mute, width: cell, align: "center")
  }
  for row in 0..<14 {
    let y = 108 + Double(row) * 40
    d.line(40, y + 32, 555, y + 32, width: 0.6, color: softLine)
    d.text("Habit", 44, y + 8, size: 11, color: mute, width: 100)
    for day in 0..<31 {
      let x = left + Double(day) * cell + (cell - 8) / 2
      d.box(x, y + 12, 8, 8, width: 0.7, color: mute, rounded: true)
    }
  }
  return StarterPack(
    entry: draft(
      "free.planner.habit-tracker", .planner, "Habit Tracker", .home,
      "Fourteen habits down the side, thirty-one days across: tick a box for every day you keep one.",
      tags: ["habits", "month", "tracker"], pages: 1),
    content: try notebookContent([d.page], title: "Habit Tracker"),
    preview: { c, size in drawPage(d.page, in: c, size: size) })
}

private func studyPlanner() throws -> StarterPack {
  var overview = PageDraft(ids: Ids(seed: 30))
  overview.text("Semester overview", 40, 30, size: 28)
  overview.line(40, 76, 555, 76, width: 1.4, color: dark)
  overview.text("Courses", 40, 92, size: 12, color: mute)
  for row in 0..<6 {
    let y = 114 + Double(row) * 40
    overview.box(40, y, 515, 32, color: softLine, rounded: true)
    overview.text("Course", 50, y + 8, size: 11, color: mute, width: 150)
    overview.text("Exam", 420, y + 8, size: 11, color: mute, width: 100)
  }
  overview.text("Goals", 40, 372, size: 12, color: mute)
  for row in 0..<5 {
    let y = 398 + Double(row) * 34
    overview.checkbox(44, y)
    overview.line(70, y + 18, 555, y + 18, width: 0.8, color: softLine)
  }
  overview.text("Deadlines", 40, 590, size: 12, color: mute)
  overview.ruling(from: 618, to: 810, spacing: 32, x1: 40, x2: 555)

  var timetable = PageDraft(ids: Ids(seed: 31))
  timetable.text("Timetable", 40, 30, size: 28)
  timetable.line(40, 76, 555, 76, width: 1.4, color: dark)
  let days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
  let colWidth = (555 - 90.0) / 5
  for (i, day) in days.enumerated() {
    timetable.text(day, 90 + Double(i) * colWidth, 88, size: 11, color: mute, width: colWidth, align: "center")
  }
  for hour in 0..<11 {
    let y = 112 + Double(hour) * 64
    timetable.text(String(format: "%02d:00", 8 + hour), 40, y + 4, size: 9, color: mute, width: 46)
    timetable.line(40, y, 555, y, width: 0.6, color: softLine)
  }
  for i in 0...5 { timetable.line(90 + Double(i) * colWidth, 108, 90 + Double(i) * colWidth, 816, width: 0.6, color: softLine) }

  var exam = PageDraft(ids: Ids(seed: 32))
  exam.text("Exam preparation", 40, 30, size: 28)
  exam.line(40, 76, 555, 76, width: 1.4, color: dark)
  exam.text("Course", 40, 92, size: 12, color: mute)
  exam.line(100, 106, 330, 106, width: 0.8, color: softLine)
  exam.text("Date", 360, 92, size: 12, color: mute)
  exam.line(400, 106, 555, 106, width: 0.8, color: softLine)
  exam.text("Topics to revise", 40, 130, size: 12, color: mute)
  for row in 0..<14 {
    let y = 156 + Double(row) * 30
    exam.checkbox(44, y)
    exam.line(70, y + 16, 400, y + 16, width: 0.8, color: softLine)
  }
  exam.text("Questions to ask", 40, 596, size: 12, color: mute)
  exam.ruling(from: 626, to: 810, spacing: 30, x1: 40, x2: 555)

  let pages = [overview.page, timetable.page, exam.page]
  return StarterPack(
    entry: draft(
      "free.planner.study-planner", .planner, "Study Planner", .study,
      "A semester overview, a weekly timetable and an exam preparation page, as a new notebook.",
      tags: ["semester", "timetable", "exams"], pages: 3),
    content: try notebookContent(pages, title: "Study Planner"),
    preview: { c, size in drawPage(pages[0], in: c, size: size) })
}

// MARK: stickers

private func clip(_ title: String, ids: inout Ids, width: Double, height: Double, _ draw: (inout PageDraft) -> Void)
  -> ElementClip
{
  var d = PageDraft(ids: ids)
  draw(&d)
  ids = d.ids
  d.page.backgroundSize = Point(width, height)
  return ElementClip(id: ids.make(), title: title, content: d.page)
}

private func stickerPack(
  _ id: String, _ name: String, _ category: CatalogCategory, _ summary: String, tags: [String],
  seed: UInt8, _ clips: (inout Ids) -> [ElementClip]
) throws -> StarterPack {
  var ids = Ids(seed: seed)
  let made = clips(&ids)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let json = try encoder.encode(made)
  return StarterPack(
    entry: draft(id, .sticker, name, category, summary, tags: tags, pages: nil),
    content: ["elements.json": json],
    preview: { c, size in drawStickers(made, in: c, size: size) })
}

private let highlightColors: [(String, InkColor)] = [
  ("Yellow", InkColor(red: 1.0, green: 0.92, blue: 0.35)), ("Green", InkColor(red: 0.55, green: 0.90, blue: 0.55)),
  ("Pink", InkColor(red: 1.0, green: 0.62, blue: 0.80)), ("Blue", InkColor(red: 0.50, green: 0.78, blue: 1.0)),
  ("Orange", InkColor(red: 1.0, green: 0.74, blue: 0.40)), ("Purple", InkColor(red: 0.78, green: 0.65, blue: 1.0)),
]

private func highlighterStrips() throws -> StarterPack {
  try stickerPack(
    "free.sticker.highlighter-strips", "Highlighter Strips", .study,
    "Six soft strips of colour to lay under a heading or behind a word.",
    tags: ["highlight", "colour", "study"], seed: 40
  ) { ids in
    highlightColors.map { name, color in
      clip("\(name) strip", ids: &ids, width: 200, height: 26) { d in
        d.add(Stroke(samples: [Sample(point: Point(10, 13)), Sample(point: Point(190, 13))], color: color, width: 22, tool: .highlighter))
      }
    }
  }
}

private func washiTape() throws -> StarterPack {
  let tapes: [(String, InkColor, InkColor)] = [
    ("Rose", InkColor(red: 0.98, green: 0.78, blue: 0.84), InkColor(red: 0.96, green: 0.58, blue: 0.70)),
    ("Mint", InkColor(red: 0.74, green: 0.93, blue: 0.84), InkColor(red: 0.45, green: 0.80, blue: 0.64)),
    ("Sky", InkColor(red: 0.76, green: 0.88, blue: 0.99), InkColor(red: 0.48, green: 0.70, blue: 0.95)),
    ("Sun", InkColor(red: 0.99, green: 0.93, blue: 0.68), InkColor(red: 0.96, green: 0.80, blue: 0.32)),
    ("Lilac", InkColor(red: 0.87, green: 0.80, blue: 0.98), InkColor(red: 0.68, green: 0.55, blue: 0.92)),
    ("Peach", InkColor(red: 0.99, green: 0.84, blue: 0.72), InkColor(red: 0.96, green: 0.65, blue: 0.45)),
  ]
  return try stickerPack(
    "free.sticker.washi-tape", "Washi Tape", .life,
    "Six pieces of striped paper tape to decorate a page or hold a picture.",
    tags: ["tape", "decor", "journal"], seed: 41
  ) { ids in
    tapes.map { name, base, stripe in
      clip("\(name) tape", ids: &ids, width: 180, height: 40) { d in
        d.box(4, 4, 172, 32, width: 0.8, color: stripe, fill: base)
        for i in stride(from: 16.0, to: 168.0, by: 18.0) {
          d.add(Stroke(samples: [Sample(point: Point(i, 6)), Sample(point: Point(i - 8, 34))], color: stripe, width: 2.4))
        }
      }
    }
  }
}

private func banners() throws -> StarterPack {
  let labels: [(String, InkColor)] = [
    ("TO DO", InkColor(red: 0.83, green: 0.30, blue: 0.30)), ("NOTES", InkColor(red: 0.18, green: 0.45, blue: 0.80)),
    ("IDEAS", InkColor(red: 0.90, green: 0.62, blue: 0.10)), ("DONE", InkColor(red: 0.18, green: 0.55, blue: 0.40)),
    ("IMPORTANT", InkColor(red: 0.60, green: 0.25, blue: 0.70)), ("LATER", InkColor(red: 0.40, green: 0.45, blue: 0.52)),
  ]
  return try stickerPack(
    "free.sticker.headers-and-banners", "Headers & Banners", .work,
    "Six coloured labels (To do, Notes, Ideas, Done, Important, Later) to head a section.",
    tags: ["header", "label", "sections"], seed: 42
  ) { ids in
    labels.map { name, color in
      clip(name.capitalized, ids: &ids, width: 150, height: 40) { d in
        d.box(4, 4, 142, 32, width: 1, color: color.darkened(0.2), fill: color, rounded: true)
        var t = TextBox(origin: Point(4, 12), text: name)
        t.id = d.ids.make()
        t.size = 15
        t.boxWidth = 142
        t.alignment = "center"
        t.color = InkColor(red: 1, green: 1, blue: 1)
        d.page.texts.append(t)
      }
    }
  }
}

private func marks() throws -> StarterPack {
  try stickerPack(
    "free.sticker.arrows-and-marks", "Arrows & Marks", .study,
    "Curved and straight arrows, a bracket, a squiggle underline and numbered circles from one to five.",
    tags: ["arrow", "numbers", "annotate"], seed: 43
  ) { ids in
    var result: [ElementClip] = []
    result.append(
      clip("Arrow", ids: &ids, width: 120, height: 40) { d in
        d.add(.shape(.dragged(.arrow, from: Point(8, 20), to: Point(112, 20)), color: InkColor.red, width: 3))
      })
    result.append(
      clip("Curved arrow", ids: &ids, width: 120, height: 70) { d in
        // A quadratic curve from the lower left to the right, and a head turned to where it ends.
        let from = Point(10, 58), control = Point(48, -8), to = Point(106, 44)
        let curve = (0...24).map { i -> Sample in
          let t = Double(i) / 24
          let u = 1 - t
          return Sample(
            point: Point(
              u * u * from.x + 2 * u * t * control.x + t * t * to.x,
              u * u * from.y + 2 * u * t * control.y + t * t * to.y))
        }
        d.add(Stroke(samples: curve, color: InkColor.blue, width: 3))
        let heading = atan2(to.y - control.y, to.x - control.x)
        for turn in [Double.pi * 0.8, -Double.pi * 0.8] {
          let tip = Point(to.x + 14 * cos(heading + turn), to.y + 14 * sin(heading + turn))
          d.add(Stroke(samples: [Sample(point: to), Sample(point: tip)], color: InkColor.blue, width: 3))
        }
      })
    result.append(
      clip("Bracket", ids: &ids, width: 40, height: 120) { d in
        d.add(Stroke(samples: [Sample(point: Point(30, 6)), Sample(point: Point(12, 10)), Sample(point: Point(12, 110)), Sample(point: Point(30, 114))], color: InkColor.ink, width: 3))
      })
    result.append(
      clip("Squiggle underline", ids: &ids, width: 200, height: 24) { d in
        let wave = (0...60).map { i -> Sample in
          let t = Double(i) / 60
          return Sample(point: Point(8 + 184 * t, 12 + 5 * sin(t * .pi * 14)))
        }
        d.add(Stroke(samples: wave, color: InkColor.red, width: 2.6))
      })
    for number in 1...5 {
      result.append(
        clip("Number \(number)", ids: &ids, width: 44, height: 44) { d in
          d.add(.shape(.dragged(.ellipse, from: Point(4, 4), to: Point(40, 40)), color: InkColor.blue, width: 2.4, fill: InkColor.blue, fillOpacity: 1))
          var t = TextBox(origin: Point(4, 10), text: "\(number)")
          t.id = d.ids.make()
          t.size = 20
          t.boxWidth = 36
          t.alignment = "center"
          t.color = InkColor(red: 1, green: 1, blue: 1)
          d.page.texts.append(t)
        })
    }
    return result
  }
}

// MARK: themes

private func themePack(
  id: String, name: String, category: CatalogCategory, summary: String, tags: [String],
  light: [String: String], dark: [String: String], design: String
) throws -> StarterPack {
  let json: [String: Any] = [
    "format": 1, "id": id, "name": name, "author": "NotesCraft", "version": "1.0",
    "colors": ["light": light, "dark": dark], "typography": ["design": design],
  ]
  let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
  let theme = try ThemeFile.parse(data)
  return StarterPack(
    entry: draft(id, .theme, name, category, summary, tags: tags),
    content: ["theme.json": data],
    preview: { c, size in drawTheme(theme, in: c, size: size) })
}

private func themes() throws -> [StarterPack] {
  let sunset = try themePack(
    id: "free.theme.sunset", name: "Sunset", category: .life,
    summary: "Warm oranges and deep browns, with a rounded typeface.", tags: ["warm", "orange"],
    light: [
      "background": "#FFF3E6", "surface": "#FFFFFF", "surfaceRaised": "#FFE0C2", "field": "#FFE9D6",
      "separator": "#F2C9A3", "textPrimary": "#3A1F12", "textSecondary": "#8A5A3C",
      "accent": "#E4572E", "accentText": "#FFFFFF", "secondaryAccent": "#F2A33A",
      "tabBar": "#7A2E1A", "toolBar": "#A23E22", "toolBarText": "#FFF3E6",
      "toolSelection": "#FFF3E6", "toolSelectionText": "#7A2E1A", "quickBar": "#FFFFFF",
      "quickBarText": "#3A1F12", "sheet": "#FFF3E6", "sheetText": "#3A1F12", "sheetSecondaryText": "#8A5A3C",
    ],
    dark: [
      "background": "#1A0F0A", "surface": "#26150E", "surfaceRaised": "#3A2216", "field": "#2F1B11",
      "separator": "#4A2C1B", "textPrimary": "#FFEBD9", "textSecondary": "#C79A7A",
      "accent": "#FF7A4D", "accentText": "#1A0F0A", "secondaryAccent": "#FFB347",
      "tabBar": "#3A1308", "toolBar": "#5A2110", "toolBarText": "#FFEBD9",
      "toolSelection": "#FFEBD9", "toolSelectionText": "#3A1308", "quickBar": "#33190F",
      "quickBarText": "#FFEBD9", "sheet": "#26150E", "sheetText": "#FFEBD9", "sheetSecondaryText": "#C79A7A",
    ], design: "rounded")
  let ocean = try themePack(
    id: "free.theme.ocean", name: "Ocean", category: .home,
    summary: "Cool blues and sea greens, light and dark.", tags: ["blue", "cool"],
    light: [
      "background": "#EEF6FB", "surface": "#FFFFFF", "surfaceRaised": "#D6E9F5", "field": "#E1EFF8",
      "separator": "#BDD8EA", "textPrimary": "#0F2A3D", "textSecondary": "#4B6E85",
      "accent": "#0A7EA4", "accentText": "#FFFFFF", "secondaryAccent": "#1BA6A6",
      "tabBar": "#0E3F5C", "toolBar": "#14587F", "toolBarText": "#EAF6FF",
      "toolSelection": "#EAF6FF", "toolSelectionText": "#0E3F5C", "quickBar": "#FFFFFF",
      "quickBarText": "#0F2A3D", "sheet": "#EEF6FB", "sheetText": "#0F2A3D", "sheetSecondaryText": "#4B6E85",
    ],
    dark: [
      "background": "#05121B", "surface": "#0A1D2B", "surfaceRaised": "#133349", "field": "#0E283A",
      "separator": "#1C4560", "textPrimary": "#E6F4FF", "textSecondary": "#8CB3CB",
      "accent": "#2BB5E0", "accentText": "#03121B", "secondaryAccent": "#37D1C4",
      "tabBar": "#08283D", "toolBar": "#0E4466", "toolBarText": "#E6F4FF",
      "toolSelection": "#E6F4FF", "toolSelectionText": "#08283D", "quickBar": "#0F2C40",
      "quickBarText": "#E6F4FF", "sheet": "#0A1D2B", "sheetText": "#E6F4FF", "sheetSecondaryText": "#8CB3CB",
    ], design: "standard")
  let forest = try themePack(
    id: "free.theme.forest", name: "Forest", category: .home,
    summary: "Deep greens and moss with a serif typeface.", tags: ["green", "calm"],
    light: [
      "background": "#F1F5EC", "surface": "#FBFDF8", "surfaceRaised": "#DCE8D0", "field": "#E6EFDC",
      "separator": "#C5D6B3", "textPrimary": "#1F2D1A", "textSecondary": "#5A6E50",
      "accent": "#3F7D3A", "accentText": "#FFFFFF", "secondaryAccent": "#8A9A2B",
      "tabBar": "#22411F", "toolBar": "#2F5A2B", "toolBarText": "#F1F8EA",
      "toolSelection": "#F1F8EA", "toolSelectionText": "#22411F", "quickBar": "#FBFDF8",
      "quickBarText": "#1F2D1A", "sheet": "#F1F5EC", "sheetText": "#1F2D1A", "sheetSecondaryText": "#5A6E50",
    ],
    dark: [
      "background": "#0B120A", "surface": "#121B10", "surfaceRaised": "#1F2D1C", "field": "#182315",
      "separator": "#2B3F27", "textPrimary": "#E6F0DE", "textSecondary": "#9BB28E",
      "accent": "#6FBF68", "accentText": "#08110A", "secondaryAccent": "#C2D24A",
      "tabBar": "#14260F", "toolBar": "#1F3A1A", "toolBarText": "#E6F0DE",
      "toolSelection": "#E6F0DE", "toolSelectionText": "#14260F", "quickBar": "#1B2A17",
      "quickBarText": "#E6F0DE", "sheet": "#121B10", "sheetText": "#E6F0DE", "sheetSecondaryText": "#9BB28E",
    ], design: "serif")
  return [sunset, ocean, forest]
}

// MARK: previews

@MainActor private func drawPage(_ page: Page, in c: CGContext, size: CGSize) {
  c.setFillColor(CGColor(gray: 1, alpha: 1))
  c.fill(CGRect(origin: .zero, size: size))
  c.saveGState()
  let scale = min(size.width / page.dimensions.x, size.height / page.dimensions.y)
  c.scaleBy(x: scale, y: scale)
  PageRenderer.render(page, assets: [:], in: c)
  c.restoreGState()
}

@MainActor private func drawStickers(_ clips: [ElementClip], in c: CGContext, size: CGSize) {
  c.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1))
  c.fill(CGRect(origin: .zero, size: size))
  let columns = 2
  let rows = (clips.count + columns - 1) / columns
  let cellW = (size.width - 40) / Double(columns)
  let cellH = min(90, (size.height - 40) / Double(rows))
  for (i, clip) in clips.enumerated() {
    let col = Double(i % columns)
    let row = Double(i / columns)
    let dims = clip.content.dimensions
    let scale = min((cellW - 16) / dims.x, (cellH - 16) / dims.y, 2.5)
    c.saveGState()
    c.translateBy(
      x: 20 + col * cellW + (cellW - dims.x * scale) / 2, y: 20 + row * cellH + (cellH - dims.y * scale) / 2)
    c.scaleBy(x: scale, y: scale)
    PageRenderer.render(clip.content, assets: [:], in: c, includeBackground: false)
    c.restoreGState()
  }
}

private func drawTheme(_ theme: Theme, in c: CGContext, size: CGSize) {
  func color(_ palette: ThemePalette, _ token: ThemeColorToken) -> CGColor {
    let v = palette[token] ?? ThemeColor(red: 1, green: 0, blue: 1)
    return CGColor(srgbRed: v.red, green: v.green, blue: v.blue, alpha: v.alpha)
  }
  let light = theme.palette(for: .light, base: .standard)
  let dark = theme.palette(for: .dark, base: .standard)
  for (index, palette) in [light, dark].enumerated() {
    let w = size.width / 2
    let x = Double(index) * w
    c.setFillColor(color(palette, .background))
    c.fill(CGRect(x: x, y: 0, width: w, height: size.height))
    c.setFillColor(color(palette, .tabBar))
    c.fill(CGRect(x: x, y: 0, width: w, height: 30))
    c.setFillColor(color(palette, .toolBar))
    c.fill(CGRect(x: x, y: 30, width: w, height: 36))
    c.setFillColor(color(palette, .toolSelection))
    c.fill(CGRect(x: x + 18, y: 36, width: 28, height: 24))
    c.setFillColor(color(palette, .editorSurround))
    c.fill(CGRect(x: x, y: 66, width: w, height: size.height - 66))
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(CGRect(x: x + 18, y: 110, width: w - 36, height: size.height - 130))
    c.setFillColor(color(palette, .quickBar))
    c.fill(CGRect(x: x + 14, y: 78, width: w - 28, height: 24))
    for (i, token) in [ThemeColorToken.accent, .secondaryAccent, .favorite, .danger].enumerated() {
      c.setFillColor(color(palette, token))
      c.fillEllipse(in: CGRect(x: x + 26 + Double(i) * 30, y: 140, width: 22, height: 22))
    }
    c.setFillColor(color(palette, .textPrimary))
    c.fill(CGRect(x: x + 28, y: 190, width: 100, height: 8))
    c.setFillColor(color(palette, .textSecondary))
    c.fill(CGRect(x: x + 28, y: 210, width: 70, height: 6))
  }
}

@MainActor private func png(size: CGSize, _ draw: @MainActor (CGContext, CGSize) -> Void) throws -> Data {
  guard
    let c = CGContext(
      data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { throw PackageError.invalidPackage }
  // y down, like a page.
  c.translateBy(x: 0, y: size.height)
  c.scaleBy(x: 1, y: -1)
  draw(c, size)
  guard let image = c.makeImage() else { throw PackageError.invalidPackage }
  let out = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
    throw PackageError.invalidPackage
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw PackageError.invalidPackage }
  return out as Data
}

// MARK: building

@MainActor private func allStarterPacks() throws -> [StarterPack] {
  var packs: [StarterPack] = []
  packs += [try cornell(), try todo(), try meeting(), try weekly(), try groceries()]
  packs += [try weeklyPlanner(), try habitTracker(), try studyPlanner()]
  packs += [try highlighterStrips(), try washiTape(), try banners(), try marks()]
  packs += try themes()
  return packs
}

@MainActor private func buildCatalog(into root: URL) throws {
  let fm = FileManager.default
  try? fm.removeItem(at: root.appendingPathComponent("packs"))
  try? fm.removeItem(at: root.appendingPathComponent("previews"))
  try fm.createDirectory(at: root.appendingPathComponent("packs"), withIntermediateDirectories: true)
  try fm.createDirectory(at: root.appendingPathComponent("previews"), withIntermediateDirectories: true)
  var entries: [CatalogEntry] = []
  for pack in try allStarterPacks() {
    var entry = pack.entry
    let manifest = PackManifest(id: entry.id, kind: entry.kind, name: entry.name, version: entry.version)
    let data = try Pack.build(manifest: manifest, content: pack.content)
    entry.size = data.count
    entry.sha256 = sha256Hex(data)
    try data.write(to: root.appendingPathComponent(entry.file))
    let isPage = entry.kind == .template || entry.kind == .planner
    let size = isPage ? CGSize(width: 420, height: 594) : CGSize(width: 420, height: 300)
    try png(size: size, pack.preview).write(to: root.appendingPathComponent(entry.preview!))
    entries.append(entry)
  }
  let index = CatalogIndex(updated: "2026-10-26", packs: entries)
  try index.encoded().write(to: root.appendingPathComponent("index.json"))
}

private let repository = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["NOTECRAFT_BUILD_CATALOG"] != nil))
func buildTheStarterCatalog() throws {
  try buildCatalog(into: repository.appendingPathComponent("catalog"))
}

@MainActor @Test func theStarterPacksAreAllValidAndSmall() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try buildCatalog(into: directory)
  let index = try CatalogIndex.parse(Data(contentsOf: directory.appendingPathComponent("index.json")))
  #expect(index.packs.count == 15)
  for kind in PackKind.allCases { #expect(index.packs.contains { $0.kind == kind }, "\(kind)") }
  for category in CatalogCategory.allCases { #expect(index.packs.contains { $0.category == category }, "\(category)") }
  for entry in index.packs {
    #expect(entry.size < 200_000, "\(entry.id) is \(entry.size) bytes")
    let preview = try Data(contentsOf: directory.appendingPathComponent(entry.preview!))
    #expect(preview.count < 150_000 && preview.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(entry.id) preview")
  }
}
