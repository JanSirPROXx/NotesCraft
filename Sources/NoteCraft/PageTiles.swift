#if os(iOS)
  import NoteCraftCore
  import UIKit

  // The static content of a page (paper or PDF, images, ink, text) drawn as tiles. A page seen at
  // 6x zoom is far more pixels than a layer can hold, but only the part on screen has to exist: the
  // page is cut into tiles at the density it is seen at, the tiles near the view are drawn, and a
  // tile that has not arrived shows what was there a moment ago.
  //
  // Committing a stroke or erasing draws straight into the tiles that it touches, so the page never
  // shows a gap between the live ink being replaced and the page having it. Every change of the
  // page is a new generation; a tile is up to date when it shows the current one.
  @MainActor final class PageTileView: UIView {
    struct Content {
      var page: Page
      var assets: [String: Data]
    }

    private final class Tile {
      let id: TileGrid.ID
      let layer = CALayer()
      var image: CGImage?
      // The generation of the page the image shows, and the newest one asked for.
      var version = -1
      var requested = -1
      var task: Task<Void, Never>?
      init(id: TileGrid.ID) { self.id = id }
    }

    // What to draw: the page as it is right now, which is not always the page in the notebook (the
    // objects being moved are not in it, nor the strokes the eraser has taken away).
    var content: () -> Content? = { nil }
    // A page that is cheap to draw has the tiles on screen drawn at once, so it never shows an
    // empty sheet; a heavy one is drawn in the background and the old tile stays until it is ready.
    var drawsOnScreenAtOnce: () -> Bool = { true }

    private var grid = TileGrid(pageSize: Point(0, 0), density: 1)
    private var wantedPageSize = CGSize.zero
    private var wantedDensity: CGFloat = 0
    private var pageSize = CGSize.zero
    private(set) var density: CGFloat = 0
    private var tiles: [TileGrid.ID: Tile] = [:]
    // The layers of the previous density, shown until the new one has drawn what is on screen.
    private var retired: [CALayer] = []
    private var generation = 0
    // The part of the page in the scroll view and a margin around it, in view points.
    private var onScreen = CGRect.null
    private var near = CGRect.null
    private var redrawPending = false
    private var scrollObservation: NSKeyValueObservation?
    private weak var scroll: UIScrollView?

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isOpaque = false
      backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: geometry

    // Page units per view point, and device pixels per page unit.
    private var pageUnitsPerPoint: Double {
      bounds.width > 0 ? Double(pageSize.width) / Double(bounds.width) : 1
    }
    private var pixelsPerPageUnit: Double { Double(density) / max(0.0001, pageUnitsPerPoint) }

    // Tile size in pixels: big tiles when the whole page is small on screen, so a PDF page is not
    // parsed twenty times to be drawn once.
    private func tilePixels(for density: CGFloat) -> Int { density > 3 ? 512 : 1024 }

    // The size of the page in page units and the pixel density it is shown at.
    func configure(pageSize: CGSize, density: CGFloat) {
      wantedPageSize = pageSize
      wantedDensity = density
      applyConfiguration()
    }

    private func applyConfiguration() {
      guard bounds.width > 0, bounds.height > 0, wantedDensity > 0, wantedPageSize.width > 0
      else { return }
      let boundsSize = Point(Double(bounds.width), Double(bounds.height))
      let sameDensity = density > 0 && abs(wantedDensity - density) / density < 0.02
      guard wantedPageSize != pageSize || !sameDensity || grid.pageSize != boundsSize else {
        return
      }
      pageSize = wantedPageSize
      density = wantedDensity
      // Tiles of another density are no use for the new grid, but they are all there is on screen
      // until the new ones are drawn.
      for tile in tiles.values {
        tile.task?.cancel()
        tile.layer.zPosition = -1
        retired.append(tile.layer)
      }
      tiles.removeAll()
      grid = TileGrid(pageSize: boundsSize, density: Double(density), tilePixels: tilePixels(for: density))
      refreshVisible(budget: 3, force: true)
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      applyConfiguration()
      let budget = redrawPending ? 9 : 3
      let force = redrawPending
      redrawPending = false
      refreshVisible(budget: budget, force: force)
    }

    // MARK: what is on screen

    override func didMoveToWindow() {
      super.didMoveToWindow()
      scrollObservation?.invalidate()
      scrollObservation = nil
      scroll = nil
      guard window != nil else {
        releaseTiles()
        return
      }
      var ancestor = superview
      while let view = ancestor {
        if let found = view as? UIScrollView {
          scroll = found
          break
        }
        ancestor = view.superview
      }
      scrollObservation = scroll?.observe(\.contentOffset, options: []) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refreshVisible(budget: 3, force: false) }
      }
      refreshVisible(budget: 3, force: true)
    }

    private func refreshVisible(budget: Int, force: Bool) {
      guard let scroll, window != nil, bounds.width > 0 else { return }
      let view = scroll.bounds
      let margin = view.insetBy(dx: -view.width * 0.25, dy: -view.height * 0.25)
      let visible = convert(view, from: scroll).intersection(bounds)
      let close = convert(margin, from: scroll).intersection(bounds)
      guard force || visible != onScreen || close != near else { return }
      onScreen = visible
      near = close
      // A pinch changes what is on screen at every frame, and the density the tiles are drawn at
      // is about to change with it: nothing is drawn until it has settled.
      if scroll.isZooming || scroll.isZoomBouncing {
        scheduleSettledRefresh()
        return
      }
      update(budget: budget)
    }

    private static let maxTiles = 120
    private var settleScheduled = false
    private func scheduleSettledRefresh() {
      guard !settleScheduled else { return }
      settleScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
        guard let self else { return }
        self.settleScheduled = false
        self.refreshVisible(budget: 3, force: true)
      }
    }

    private func gridRect(_ rect: CGRect) -> Rect {
      Rect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    // Draws what is missing near the view, the middle of the screen first, and lets go of what is
    // far away. `budget` tiles of a light page are drawn right here, the rest in the background.
    private func update(budget: Int) {
      guard grid.count > 0 else { return }
      guard !near.isNull, !near.isEmpty else {
        dropTiles { _ in true }
        dropRetired()
        return
      }
      let keep = near.insetBy(dx: -near.width * 0.25, dy: -near.height * 0.25)
      dropTiles { !$0.layer.frame.intersects(keep) }
      var missing: [TileGrid.ID] = []
      for id in grid.ids(intersecting: gridRect(near)) {
        if let tile = tiles[id], tile.version == generation || tile.requested == generation {
          continue
        }
        missing.append(id)
      }
      if !missing.isEmpty {
        let around = onScreen.isNull ? near : onScreen
        var remaining = drawsOnScreenAtOnce() ? budget : 0
        // However far it is zoomed, a page never holds more tiles than this.
        let room = max(0, Self.maxTiles - tiles.count)
        for id in grid.ordered(missing, around: gridRect(around)).prefix(room) {
          let tile = tiles[id] ?? makeTile(id)
          if remaining > 0, tile.layer.frame.intersects(onScreen) {
            renderNow(tile)
            remaining -= 1
          } else {
            request(tile)
          }
        }
      }
      dropRetiredIfDrawn()
    }

    private func dropTiles(where remove: (Tile) -> Bool) {
      var gone: [TileGrid.ID] = []
      for (id, tile) in tiles where remove(tile) { gone.append(id) }
      guard !gone.isEmpty else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for id in gone {
        tiles[id]?.task?.cancel()
        tiles[id]?.layer.removeFromSuperlayer()
        tiles[id] = nil
      }
      CATransaction.commit()
    }

    private func makeTile(_ id: TileGrid.ID) -> Tile {
      let tile = Tile(id: id)
      let r = grid.rect(of: id)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      tile.layer.frame = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
      tile.layer.isOpaque = true
      tile.layer.contentsGravity = .resize
      tile.layer.magnificationFilter = .linear
      tile.layer.minificationFilter = .trilinear
      tile.layer.zPosition = 0
      layer.addSublayer(tile.layer)
      CATransaction.commit()
      tiles[id] = tile
      return tile
    }

    // The old tiles go once everything that is on screen has been drawn at the new density.
    private func dropRetiredIfDrawn() {
      guard !retired.isEmpty, !onScreen.isNull else { return }
      let visible = grid.ids(intersecting: gridRect(onScreen))
      guard visible.allSatisfy({ tiles[$0]?.image != nil }) else { return }
      dropRetired()
    }

    private func dropRetired() {
      guard !retired.isEmpty else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for layer in retired { layer.removeFromSuperlayer() }
      CATransaction.commit()
      retired.removeAll()
    }

    // MARK: drawing tiles

    private func docRect(of id: TileGrid.ID) -> CGRect {
      let r = grid.rect(of: id)
      let k = pageUnitsPerPoint
      return CGRect(x: r.x * k, y: r.y * k, width: r.width * k, height: r.height * k)
    }

    private func context(for id: TileGrid.ID) -> CGContext? {
      let size = grid.pixelSize(of: id)
      return CGContext(
        data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    // The page's units, y down, with the top left of the tile at the top left of the bitmap.
    private func applyPageTransform(_ c: CGContext, _ id: TileGrid.ID) {
      let rect = docRect(of: id)
      let size = grid.pixelSize(of: id)
      c.translateBy(x: 0, y: Double(size.height))
      c.scaleBy(x: pixelsPerPageUnit, y: -pixelsPerPageUnit)
      c.translateBy(x: -rect.minX, y: -rect.minY)
    }

    private func request(_ tile: Tile) {
      guard let content = content() else { return }
      tile.requested = generation
      let asked = generation
      let id = tile.id
      let rect = docRect(of: id)
      let size = grid.pixelSize(of: id)
      let resolution = pixelsPerPageUnit
      let gridAtRequest = grid
      tile.task?.cancel()
      tile.task = Task { @MainActor [weak self] in
        let rendered = await PageCacheWorker.shared.renderTile(
          content.page, assets: content.assets, origin: rect.origin, resolution: resolution,
          pixelWidth: size.width, pixelHeight: size.height)
        // A task that was cancelled has been replaced by a newer one, or its tile is gone.
        guard !Task.isCancelled, let self, self.grid == gridAtRequest, let tile = self.tiles[id],
          let rendered
        else { return }
        // A drawing that arrives after a newer one of the same tile is out of date.
        if asked >= tile.version {
          self.store(rendered.image, in: tile)
          tile.version = asked
        }
        // The page has changed since this was asked for.
        if tile.version != self.generation, tile.requested != self.generation {
          self.request(tile)
        }
        self.dropRetiredIfDrawn()
      }
    }

    private func renderNow(_ tile: Tile) {
      guard let content = content(), let c = context(for: tile.id) else { return }
      tile.task?.cancel()
      applyPageTransform(c, tile.id)
      PageRenderer.render(content.page, assets: content.assets, in: c, cull: docRect(of: tile.id))
      store(c.makeImage(), in: tile)
      tile.version = generation
      tile.requested = generation
    }

    private func store(_ image: CGImage?, in tile: Tile) {
      tile.image = image
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      tile.layer.contents = image
      CATransaction.commit()
    }

    // MARK: changes to the page

    // The page changed in a way that is not a plain addition of a stroke. Every tile that has an
    // image and touches `area` (page units; all of them without one) is out of date and is drawn
    // again before the next frame; the others still show the page.
    func invalidate(inPageRect area: CGRect? = nil) {
      let previous = generation
      generation += 1
      if let area {
        for tile in tiles.values where tile.version == previous {
          if !docRect(of: tile.id).intersects(area) { tile.version = generation }
        }
      }
      redrawPending = true
      setNeedsLayout()
    }

    // A stroke was committed: it goes into the tiles it touches, and nothing else changes.
    func append(_ stroke: Stroke) {
      let box = stroke.bounds
      let pad = stroke.width * 2 + 2
      let area = CGRect(
        x: box.x - pad, y: box.y - pad, width: box.width + 2 * pad, height: box.height + 2 * pad)
      advance(touching: area) { PageRenderer.stroke(stroke, in: $0) }
    }

    // The eraser took ink away from `area` (page units): that part of each tile is drawn again from
    // the strokes that reach it.
    func patch(inPageRect area: CGRect, strokes: [Stroke], page: Page, assets: [String: Data]) {
      var patchPage = page
      patchPage.strokes = strokes
      advance(touching: area) { c in
        c.saveGState()
        c.clip(to: area)
        PageRenderer.render(patchPage, assets: assets, in: c, cull: area)
        c.restoreGState()
      }
    }

    // A new generation in which only `area` differs: the tiles that were up to date and reach it
    // are drawn into, the other up-to-date ones are still right, and whatever was behind stays
    // behind and is drawn from the new page when it is asked for.
    private func advance(touching area: CGRect, _ draw: (CGContext) -> Void) {
      let previous = generation
      generation += 1
      var behind = false
      for tile in tiles.values {
        guard tile.version == previous else {
          behind = true
          continue
        }
        if docRect(of: tile.id).intersects(area), let image = tile.image,
          let c = context(for: tile.id)
        {
          let size = grid.pixelSize(of: tile.id)
          c.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
          applyPageTransform(c, tile.id)
          draw(c)
          store(c.makeImage(), in: tile)
        }
        tile.version = generation
      }
      if behind {
        redrawPending = true
        setNeedsLayout()
      }
    }

    // The part of the page that is on screen, in view points; null while it is not.
    var visibleRect: CGRect { onScreen }

    // True once every tile on screen shows the current page.
    var isCurrent: Bool {
      guard !onScreen.isNull, grid.count > 0 else { return false }
      return grid.ids(intersecting: gridRect(onScreen)).allSatisfy { tiles[$0]?.version == generation }
    }

    // Drops everything, e.g. when the view leaves the screen.
    func releaseTiles() {
      for tile in tiles.values {
        tile.task?.cancel()
        tile.layer.removeFromSuperlayer()
      }
      for layer in retired { layer.removeFromSuperlayer() }
      tiles.removeAll()
      retired.removeAll()
      onScreen = .null
      near = .null
    }
  }
#endif
