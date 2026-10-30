import NoteCraftCore
import SwiftUI

// One calculation that is being worked out, as far as the page shows it: the writing that was
// recognized (it lights up) and the spot where the answer will stand (three dots wait there).
// It is not part of the document; it lives for a second or two.
struct CalculatorActivity: Equatable, Identifiable {
  enum Phase: Equatable { case reading, answered }
  let id: UUID
  var pageID: UUID
  // The strokes that were read, thinned out: the glow only needs their shape.
  var outline: [[Point]]
  var glyphHeight: Double
  var inkWidth: Double
  // Left end of the answer on the baseline.
  var anchor: Point
  var color: InkColor
  var phase: Phase

  init(id: UUID = UUID(), pageID: UUID, gathering: Gathering, color: InkColor) {
    self.id = id
    self.pageID = pageID
    outline = gathering.strokes.map { stroke in
      let step = max(1, stroke.samples.count / 24)
      var points = stride(from: 0, to: stroke.samples.count, by: step).map { stroke.samples[$0].point }
      if let last = stroke.samples.last?.point, points.last != last { points.append(last) }
      return points
    }
    glyphHeight = gathering.glyphHeight
    inkWidth = gathering.strokes.map(\.width).max() ?? 2.5
    anchor = gathering.answerOrigin
    self.color = color
    phase = .reading
  }
}

#if os(iOS)
  import UIKit

  // The glow and the dots, as Core Animation layers over the page. They are not drawn into the
  // page, so neither the tiles nor the ink overlay are touched while they run, and a SwiftUI
  // state change is needed only when an animation starts or ends, never per frame.
  @MainActor final class CalculatorEffectsView: UIView {
    private final class Effect {
      let glow = CAShapeLayer()
      let shine = CAShapeLayer()
      let dots = CALayer()
      var dotsGone = false
    }
    private var effects: [UUID: Effect] = [:]
    private var layerScale: CGFloat = 2

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      isOpaque = false
      backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setLayerScale(_ scale: CGFloat) {
      layerScale = max(1, scale)
      for effect in effects.values {
        for layer in [effect.glow, effect.shine, effect.dots] { layer.contentsScale = layerScale }
      }
    }

    // `map` takes page points to this view; `zoom` is view points per page point.
    func apply(_ activities: [CalculatorActivity], map: (Point) -> CGPoint, zoom: CGFloat) {
      let ids = Set(activities.map(\.id))
      for id in effects.keys where !ids.contains(id) {
        remove(effects[id]!)
        effects[id] = nil
      }
      for activity in activities {
        if let effect = effects[activity.id] {
          if activity.phase == .answered, !effect.dotsGone { fadeOutDots(effect) }
        } else if activity.phase == .reading {
          effects[activity.id] = start(activity, map: map, zoom: zoom)
        }
      }
    }

    private func remove(_ effect: Effect) {
      for layer in [effect.glow, effect.shine, effect.dots] { layer.removeFromSuperlayer() }
    }

    private func start(_ a: CalculatorActivity, map: (Point) -> CGPoint, zoom: CGFloat) -> Effect {
      let effect = Effect()
      let color = UIColor(red: a.color.red, green: a.color.green, blue: a.color.blue, alpha: 1)
      let reduceMotion = UIAccessibility.isReduceMotionEnabled
      let height = a.glyphHeight * zoom

      let path = UIBezierPath()
      for line in a.outline {
        guard let first = line.first else { continue }
        path.move(to: map(first))
        for point in line.dropFirst() { path.addLine(to: map(point)) }
        if line.count == 1 { path.addLine(to: map(first)) }
      }
      let box = path.bounds.insetBy(dx: -height, dy: -height)

      for layer in [effect.glow, effect.shine] {
        layer.frame = bounds
        layer.path = path.cgPath
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.contentsScale = layerScale
        layer.opacity = 0
        layer.shadowOffset = .zero
        layer.shadowOpacity = 1
      }
      // The glow: the writing's own shape, thickened, in the pen colour, with a soft halo.
      effect.glow.strokeColor = color.withAlphaComponent(0.85).cgColor
      effect.glow.lineWidth = CGFloat(a.inkWidth) * zoom + max(2, height * 0.12)
      effect.glow.shadowColor = color.cgColor
      effect.glow.shadowRadius = 2
      // The shine: a lighter line that a band of light drags across the writing, left to right.
      effect.shine.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
      effect.shine.lineWidth = CGFloat(a.inkWidth) * zoom + max(1, height * 0.04)
      effect.shine.shadowColor = UIColor.white.cgColor
      effect.shine.shadowRadius = max(2, height * 0.12)
      layer.addSublayer(effect.glow)
      if !reduceMotion {
        let band = CAGradientLayer()
        band.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        let width = max(box.width * 0.45, height)
        band.frame = CGRect(x: box.minX - width, y: box.minY, width: width, height: box.height)
        effect.shine.mask = band
        layer.addSublayer(effect.shine)
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = box.minX - width / 2
        sweep.toValue = box.maxX + width / 2
        sweep.duration = 0.7
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        band.add(sweep, forKey: "sweep")
        band.position.x = box.maxX + width / 2
      }

      CATransaction.begin()
      CATransaction.setCompletionBlock { [weak effect] in
        effect?.glow.removeFromSuperlayer()
        effect?.shine.removeFromSuperlayer()
      }
      let duration = reduceMotion ? 0.6 : 0.9
      let fade = CAKeyframeAnimation(keyPath: "opacity")
      fade.values = [0, 1, 0.9, 0]
      fade.keyTimes = [0, 0.2, 0.6, 1]
      fade.duration = duration
      effect.glow.add(fade, forKey: "fade")
      let halo = CAKeyframeAnimation(keyPath: "shadowRadius")
      halo.values = [2, height * 0.5, height * 0.3, 2]
      halo.keyTimes = [0, 0.25, 0.6, 1]
      halo.duration = duration
      effect.glow.add(halo, forKey: "halo")
      if !reduceMotion {
        let shineFade = CAKeyframeAnimation(keyPath: "opacity")
        shineFade.values = [0, 1, 1, 0]
        shineFade.keyTimes = [0, 0.1, 0.8, 1]
        shineFade.duration = 0.75
        effect.shine.add(shineFade, forKey: "fade")
      }
      CATransaction.commit()

      addDots(a, to: effect, map: map, zoom: zoom, color: color, reduceMotion: reduceMotion)
      return effect
    }

    // Three dots on the baseline where the answer will start, pulsing one after the other.
    private func addDots(
      _ a: CalculatorActivity, to effect: Effect, map: (Point) -> CGPoint, zoom: CGFloat,
      color: UIColor, reduceMotion: Bool
    ) {
      let size = max(4, a.glyphHeight * zoom * 0.2)
      let origin = map(a.anchor)
      effect.dots.frame = bounds
      effect.dots.contentsScale = layerScale
      for i in 0..<3 {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.backgroundColor = color.cgColor
        dot.contentsScale = layerScale
        dot.position = CGPoint(
          x: origin.x + size * 0.5 + CGFloat(i) * size * 1.9, y: origin.y - a.glyphHeight * zoom * 0.18)
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.3, 1, 0.3]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 0.9
        pulse.repeatCount = .infinity
        pulse.timeOffset = Double(i) * 0.18
        dot.add(pulse, forKey: "pulse")
        if !reduceMotion {
          let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
          bounce.values = [0.7, 1.15, 0.7]
          bounce.keyTimes = [0, 0.5, 1]
          bounce.duration = 0.9
          bounce.repeatCount = .infinity
          bounce.timeOffset = Double(i) * 0.18
          dot.add(bounce, forKey: "bounce")
        }
        effect.dots.addSublayer(dot)
      }
      layer.addSublayer(effect.dots)
    }

    private func fadeOutDots(_ effect: Effect) {
      effect.dotsGone = true
      CATransaction.begin()
      CATransaction.setCompletionBlock { [weak effect] in effect?.dots.removeFromSuperlayer() }
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.toValue = 0
      fade.duration = 0.18
      effect.dots.opacity = 0
      effect.dots.add(fade, forKey: "out")
      CATransaction.commit()
    }
  }
#endif
