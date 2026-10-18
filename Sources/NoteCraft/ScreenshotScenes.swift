#if DEBUG
  import Foundation
  import NoteCraftCore

  // Sample pages for the App Store screenshots (`scripts/screenshots.sh`). Launching with
  // `--screenshot-scenes=notes,circuit,graph,whiteboard` fills each new, empty document with the
  // next scene, so the screenshots show real rendering of handwriting-like ink, shapes and text
  // instead of an empty page. Debug builds only; Release builds do not contain this file's code.
  @MainActor enum ScreenshotScenes {
    private static var queue: [String] = {
      ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix("--screenshot-scenes=") }
        .map { $0.dropFirst("--screenshot-scenes=".count).split(separator: ",").map(String.init) }
        ?? []
    }()

    static func next() -> String? { queue.isEmpty ? nil : queue.removeFirst() }

    static func fill(_ notebook: inout Notebook, scene: String) {
      guard !notebook.pages.isEmpty else { return }
      var page = notebook.pages[0]
      var art = Artist()
      switch scene {
      case "notes": art.notes(&page)
      case "circuit": art.circuit(&page)
      case "graph": art.graph(&page)
      case "whiteboard":
        art.whiteboard(&page)
        notebook.viewport = ViewTransform(scale: 1, offset: Point(30, 30))
      default: return
      }
      notebook.pages[0] = page
      notebook.revision += 1
    }
  }

  // Draws like a hand: slightly wobbling lines with varying pressure.
  private struct Artist {
    var seed: UInt64 = 7
    mutating func random() -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(seed >> 33) / Double(1 << 31)
    }
    mutating func wobble(_ amount: Double) -> Double { (random() - 0.5) * 2 * amount }

    mutating func stroke(
      _ points: [Point], color: InkColor = .ink, width: Double = 2.2, wobble amount: Double = 0.7,
      tool: InkTool = .pen
    ) -> Stroke {
      var samples: [Sample] = []
      var phase = random() * 6
      for (index, point) in points.enumerated() {
        phase += 0.35
        let ease = min(1, Double(index) / 4, Double(points.count - 1 - index) / 4 + 0.3)
        samples.append(
          Sample(
            point: Point(point.x + wobble(amount), point.y + wobble(amount)),
            pressure: max(0.3, min(1, (0.55 + 0.25 * sin(phase)) * (0.5 + 0.5 * ease) + 0.15)),
            altitude: 0.9))
      }
      var stroke = Stroke(samples: samples, color: color, width: width, tool: tool, style: .fountain)
      if tool == .highlighter { stroke.style = .ballpoint }
      return stroke
    }

    mutating func line(
      _ a: Point, _ b: Point, color: InkColor = .ink, width: Double = 2.2, wobble: Double = 0.7
    ) -> Stroke {
      let steps = max(2, Int(a.distance(to: b) / 4))
      let points = (0...steps).map { i -> Point in
        let t = Double(i) / Double(steps)
        return Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
      }
      return stroke(points, color: color, width: width, wobble: wobble)
    }

    mutating func curve(
      from x0: Double, to x1: Double, color: InkColor, width: Double = 2.6,
      _ f: (Double) -> Double
    ) -> Stroke {
      let steps = Int((x1 - x0) / 3)
      return stroke(
        (0...steps).map { i in
          let x = x0 + (x1 - x0) * Double(i) / Double(steps)
          return Point(x, f(x))
        }, color: color, width: width, wobble: 0.35)
    }

    mutating func loop(
      center: Point, rx: Double, ry: Double, color: InkColor, width: Double = 2.4
    ) -> Stroke {
      // A little more than a full turn, the way a circled word is drawn.
      stroke(
        (0...64).map { i in
          let angle = -1.2 + Double(i) / 64 * 2 * .pi * 1.08
          let drift = 1 + 0.04 * Double(i) / 64
          return Point(
            center.x + rx * drift * cos(angle), center.y + ry * drift * sin(angle))
        }, color: color, width: width, wobble: 0.4)
    }

    mutating func highlight(_ a: Point, _ b: Point, color: InkColor = .yellow, width: Double = 16)
      -> Stroke
    {
      var stroke = Stroke(
        samples: [Sample(point: a), Sample(point: b)], color: color, width: width,
        tool: .highlighter)
      stroke.style = .ballpoint
      return stroke
    }

    func text(
      _ string: String, at origin: Point, size: Double = 19, color: InkColor = .ink,
      font: String? = "BradleyHandITCTT-Bold", width: Double? = nil, align: String? = nil
    ) -> TextBox {
      var box = TextBox(origin: origin, text: string)
      box.size = size
      box.color = color
      box.fontName = font
      box.boxWidth = width ?? max(120, Double(string.count) * size * 0.62)
      box.alignment = align
      return box
    }

    func shape(
      _ kind: ShapeKind, _ center: Point, _ width: Double, _ height: Double,
      rotation: Double = 0, color: InkColor = .ink, line: Double = 2.4, fill: InkColor? = nil,
      opacity: Double? = nil
    ) -> Stroke {
      .shape(
        ShapeSpec(kind: kind, center: center, width: width, height: height, rotation: rotation),
        color: color, width: line, fill: fill, fillOpacity: opacity)
    }

    // MARK: Scenes

    mutating func notes(_ page: inout Page) {
      page.paper.pattern = .ruled
      let blue = InkColor.blue
      page.texts.append(
        text("Electric circuits", at: Point(40, 58), size: 36, color: blue, font: "Noteworthy-Bold"))
      page.strokes.append(
        stroke(
          (0...50).map { Point(40 + Double($0) * 5.2, 106 + sin(Double($0) * 0.5) * 2.2) },
          color: blue, width: 3))
      page.texts.append(text("Fri 16 Oct", at: Point(418, 78), size: 17, color: .red))
      page.strokes.append(.sticker(.star, at: Point(546, 86), size: Point(34, 34)))
      let bullets = [
        "Current I flows from + to −",
        "Voltage U drives the current",
        "Resistance R slows it down",
      ]
      for (i, line) in bullets.enumerated() {
        let y = 148 + Double(i) * 24
        page.strokes.append(.sticker(.check, at: Point(52, y + 12), size: Point(16, 16)))
        page.texts.append(text(line, at: Point(72, y - 7), size: 19))
      }
      // The main law, highlighted and circled.
      page.strokes.append(highlight(Point(70, 258), Point(238, 258), width: 24))
      page.texts.append(text("U = R · I", at: Point(78, 232), size: 32, color: .ink, font: "Noteworthy-Bold"))
      page.strokes.append(loop(center: Point(154, 252), rx: 104, ry: 28, color: .red))
      page.texts.append(text("Ohm's law", at: Point(290, 242), size: 20, color: .red))
      page.strokes.append(line(Point(262, 252), Point(286, 252), color: .red, width: 2.4))
      page.texts.append(text("Series", at: Point(40, 316), size: 24, color: blue, font: "Noteworthy-Bold"))
      page.texts.append(text("R = R₁ + R₂ + R₃", at: Point(150, 318), size: 22))
      page.texts.append(text("Parallel", at: Point(40, 364), size: 24, color: blue, font: "Noteworthy-Bold"))
      page.texts.append(text("1/R = 1/R₁ + 1/R₂", at: Point(150, 366), size: 22))
      // A worked example in a box.
      page.strokes.append(
        shape(.roundedRectangle, Point(298, 490), 484, 124, color: .green, line: 2.6))
      page.texts.append(text("Example", at: Point(62, 440), size: 20, color: .green, font: "Noteworthy-Bold"))
      page.texts.append(text("R₁ = 100 Ω    R₂ = 220 Ω", at: Point(62, 474), size: 20))
      page.texts.append(text("R = 100 + 220 = 320 Ω", at: Point(62, 506), size: 20, color: blue))
      page.strokes.append(.sticker(.check, at: Point(520, 490), size: Point(34, 34)))
      page.strokes.append(
        line(Point(62, 532), Point(300, 532), color: blue, width: 2.4, wobble: 0.9))
      page.texts.append(text("Remember: units!", at: Point(332, 582), size: 22, color: .red))
      page.strokes.append(
        shape(.arrow, Point(312, 578), 46, 0, rotation: -2.5, color: .red, line: 2.6))
      // Two resistors in series on one wire: rectangles drawn right on the line.
      let wireY = 700.0
      let white = InkColor(red: 1, green: 1, blue: 1)
      page.texts.append(text("In series", at: Point(40, 636), size: 24, color: blue, font: "Noteworthy-Bold"))
      page.strokes.append(line(Point(60, wireY), Point(540, wireY), width: 2.6))
      page.strokes.append(shape(.rectangle, Point(200, wireY), 80, 28, line: 2.6, fill: white, opacity: 1))
      page.strokes.append(shape(.rectangle, Point(400, wireY), 80, 28, line: 2.6, fill: white, opacity: 1))
      page.texts.append(text("R₁", at: Point(188, wireY - 52), size: 20, color: blue, width: 40))
      page.texts.append(text("R₂", at: Point(388, wireY - 52), size: 20, color: blue, width: 40))
      page.strokes.append(shape(.arrow, Point(300, wireY - 26), 50, 0, color: .red, line: 2.6))
      page.texts.append(text("I", at: Point(294, wireY - 58), size: 20, color: .red, width: 30))
    }

    mutating func circuit(_ page: inout Page) {
      page.paper.pattern = .squared
      let left = 170.0, right = 460.0, top = 244.0, bottom = 484.0
      let wire = InkColor.ink
      page.texts.append(
        text("Series-parallel circuit", at: Point(40, 58), size: 34, color: .blue, font: "Noteworthy-Bold"))
      // Wires first, resistors on top: each rectangle sits on its wire.
      page.strokes.append(line(Point(left, top), Point(right, top), color: wire, width: 2.6))
      page.strokes.append(line(Point(right, top), Point(right, bottom), color: wire, width: 2.6))
      page.strokes.append(line(Point(right, bottom), Point(left, bottom), color: wire, width: 2.6))
      // The left wire is interrupted by the battery.
      let mid = (top + bottom) / 2
      page.strokes.append(line(Point(left, bottom), Point(left, mid + 9), color: wire, width: 2.6))
      page.strokes.append(line(Point(left, mid - 9), Point(left, top), color: wire, width: 2.6))
      // Battery on the left wire.
      page.strokes.append(line(Point(left - 34, mid - 9), Point(left + 34, mid - 9), width: 3.4, wobble: 0.3))
      page.strokes.append(line(Point(left - 18, mid + 9), Point(left + 18, mid + 9), width: 3.4, wobble: 0.3))
      page.texts.append(text("+", at: Point(left - 64, mid - 40), size: 24, color: .red, width: 30))
      page.texts.append(text("−", at: Point(left - 64, mid + 2), size: 24, color: .blue, width: 30))
      page.texts.append(text("U = 9 V", at: Point(left - 124, mid + 30), size: 20, width: 100))
      // Resistors: white-filled rectangles that hide the wire underneath.
      let white = InkColor(red: 1, green: 1, blue: 1)
      page.strokes.append(shape(.rectangle, Point(300, top), 84, 30, color: .ink, line: 2.6, fill: white, opacity: 1))
      page.strokes.append(
        shape(.rectangle, Point(right, mid), 84, 30, rotation: .pi / 2, color: .ink, line: 2.6, fill: white, opacity: 1))
      page.strokes.append(shape(.rectangle, Point(300, bottom), 84, 30, color: .ink, line: 2.6, fill: white, opacity: 1))
      page.texts.append(text("R₁ 100 Ω", at: Point(256, top - 52), size: 20, color: .blue))
      page.texts.append(text("R₂\n220 Ω", at: Point(right + 30, mid - 26), size: 20, color: .blue, width: 80))
      page.texts.append(text("R₃ 47 Ω", at: Point(264, bottom + 30), size: 20, color: .blue))
      // Current direction.
      page.strokes.append(shape(.arrow, Point(190, top - 22), 60, 0, color: .red, line: 2.6))
      page.texts.append(text("I", at: Point(184, top - 54), size: 22, color: .red))
      page.strokes.append(
        shape(.arrow, Point(right - 28, 312), 50, 0, rotation: .pi / 2, color: .red, line: 2.6))
      // Junction dots.
      for corner in [Point(left, top), Point(right, top), Point(right, bottom), Point(left, bottom)] {
        page.strokes.append(
          shape(.ellipse, corner, 9, 9, color: .ink, line: 1.5, fill: .ink, opacity: 1))
      }
      // The calculation.
      page.strokes.append(highlight(Point(60, 626), Point(400, 626), width: 24))
      page.texts.append(text("R = R₁ + R₂ + R₃ = 367 Ω", at: Point(64, 602), size: 24, font: "Noteworthy-Bold"))
      page.texts.append(text("I = U / R ≈ 24.5 mA", at: Point(64, 656), size: 24, color: .blue, font: "Noteworthy-Bold"))
      page.strokes.append(loop(center: Point(200, 668), rx: 150, ry: 24, color: .red))
      page.strokes.append(.sticker(.bolt, at: Point(520, 640), size: Point(40, 52)))
    }

    mutating func graph(_ page: inout Page) {
      page.paper.pattern = .graph
      let ox = 130.0, oy = 470.0
      page.texts.append(
        text("Functions", at: Point(40, 58), size: 36, color: .blue, font: "Noteworthy-Bold"))
      // Axes with arrow heads.
      page.strokes.append(line(Point(ox - 70, oy), Point(540, oy), width: 2.4))
      page.strokes.append(line(Point(ox, oy + 120), Point(ox, 190), width: 2.4))
      page.strokes.append(shape(.arrow, Point(528, oy), 24, 0, color: .ink, line: 2.4))
      page.strokes.append(shape(.arrow, Point(ox, 202), 24, 0, rotation: -.pi / 2, color: .ink, line: 2.4))
      page.texts.append(text("x", at: Point(544, oy + 4), size: 22))
      page.texts.append(text("y", at: Point(ox + 10, 176), size: 22))
      let period = 300.0
      page.strokes.append(
        curve(from: ox, to: ox + period * 1.2, color: .blue) { x in
          oy - 100 * sin((x - ox) / period * 2 * .pi)
        })
      page.strokes.append(
        curve(from: ox, to: ox + period * 1.2, color: .red) { x in
          oy - 100 * cos((x - ox) / period * 2 * .pi)
        })
      for k in 1...2 {
        let x = ox + period * Double(k) / 2
        page.strokes.append(line(Point(x, oy - 6), Point(x, oy + 6), width: 2))
        page.texts.append(text(k == 2 ? "2π" : "π", at: Point(x - 10, oy + 12), size: 18, width: 40))
      }
      page.texts.append(text("sin(x)", at: Point(ox + 250, oy + 96), size: 22, color: .blue))
      page.texts.append(text("cos(x)", at: Point(ox + 296, oy - 140), size: 22, color: .red))
      // A marked point and its tangent.
      let px = ox + period / 4
      page.strokes.append(shape(.ellipse, Point(px, oy - 100), 12, 12, color: .green, line: 2.4, fill: .green, opacity: 1))
      page.strokes.append(line(Point(px - 36, oy - 100), Point(px + 36, oy - 100), color: .green, width: 2.4, wobble: 0.3))
      page.texts.append(text("max = 1", at: Point(px - 24, oy - 176), size: 20, color: .green))
      page.strokes.append(highlight(Point(70, 640), Point(380, 640), width: 26))
      page.texts.append(text("sin²x + cos²x = 1", at: Point(76, 614), size: 28, font: "Noteworthy-Bold"))
      page.strokes.append(loop(center: Point(226, 640), rx: 170, ry: 30, color: .green))
      page.strokes.append(.sticker(.check, at: Point(500, 640), size: Point(40, 40)))
    }

    mutating func whiteboard(_ page: inout Page) {
      page.paper.pattern = .dotted
      let center = Point(520, 520)
      page.texts.append(
        text("Project ideas", at: Point(60, 130), size: 40, color: .blue, font: "Noteworthy-Bold"))
      let nodes: [(String, Double, ShapeKind, InkColor)] = [
        ("Handwriting", -2.5, .roundedRectangle, .blue),
        ("PDF", -1.1, .roundedRectangle, .red),
        ("Shapes", 0.2, .roundedRectangle, .green),
        ("Scan", 1.35, .roundedRectangle, .blue),
        ("Search", 2.4, .roundedRectangle, .red),
      ]
      for (label, angle, kind, color) in nodes {
        let node = Point(center.x + 330 * cos(angle), center.y + 250 * sin(angle))
        // The connector runs between the two outlines instead of centre to centre.
        let dx = node.x - center.x, dy = node.y - center.y
        let length = hypot(dx, dy)
        let ux = dx / length, uy = dy / length
        let outer = 1 / hypot(ux / 125, uy / 75)
        let inner = min(85 / max(0.001, abs(ux)), 32 / max(0.001, abs(uy)))
        page.strokes.append(
          line(
            Point(center.x + ux * (outer + 4), center.y + uy * (outer + 4)),
            Point(node.x - ux * (inner + 4), node.y - uy * (inner + 4)), color: color, width: 3))
        page.strokes.append(
          shape(kind, node, 170, 64, color: color, line: 3, fill: color, opacity: 0.18))
        page.texts.append(
          text(label, at: Point(node.x - 85, node.y - 15), size: 24, color: color.darkened(),
               font: "Noteworthy-Bold", width: 170, align: "center"))
      }
      page.strokes.append(
        shape(.ellipse, center, 250, 150, color: .blue, line: 3.4, fill: .blue, opacity: 0.2))
      page.texts.append(
        text("NotesCraft", at: Point(center.x - 120, center.y - 24), size: 38, color: .blue.darkened(),
             font: "Noteworthy-Bold", width: 240, align: "center"))
      page.strokes.append(.sticker(.star, at: Point(880, 250), size: Point(54, 54)))
      page.strokes.append(.sticker(.heart, at: Point(150, 760), size: Point(54, 50)))
      page.strokes.append(.sticker(.cloud, at: Point(840, 780), size: Point(96, 62)))
      page.strokes.append(.sticker(.bolt, at: Point(300, 900), size: Point(44, 58)))
      page.texts.append(text("fast & private", at: Point(380, 876), size: 26, color: .red))
      page.strokes.append(
        shape(.arrow, Point(350, 880), 80, 0, rotation: .pi, color: .red, line: 2.8))
    }
  }
#endif
