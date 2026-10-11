import ImageIO
import NoteCraftCore
import SwiftUI

struct ImageHandles: View {
  let asset: PageAsset
  let data: Data
  let viewScale: Double
  var viewOffset = Point(0, 0)
  let onCommit: (PageAsset) -> Void
  @GestureState private var drag = CGSize.zero
  @GestureState private var magnification = 1.0
  @GestureState private var rotation = Angle.zero
  @GestureState private var resize = 1.0
  private func resizeFactor(_ translation: CGSize) -> Double {
    let dx =
      Double(translation.width) * Foundation.cos(asset.rotation) + Double(translation.height)
      * Foundation.sin(asset.rotation)
    return max(0.1, min(10, 1 + dx / max(1, asset.frame.width * viewScale)))
  }
  var body: some View {
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    {
      Image(decorative: image, scale: 1)
        .resizable().frame(
          width: asset.frame.width * viewScale * resize,
          height: asset.frame.height * viewScale * resize
        )
        .overlay {
          Rectangle().stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        .overlay(alignment: .bottomTrailing) {
          Circle().fill(.white).overlay(Circle().stroke(.blue, lineWidth: 2)).frame(
            width: 12, height: 12
          ).frame(width: 32, height: 32).contentShape(Rectangle()).offset(x: 16, y: 16)
            .highPriorityGesture(
              DragGesture().updating($resize) { value, state, _ in
                state = resizeFactor(value.translation)
              }.onEnded { value in
                var changed = asset
                let factor = resizeFactor(value.translation)
                changed.frame.width *= factor
                changed.frame.height *= factor
                onCommit(changed)
              }
            )
            .accessibilityLabel("Resize image")
        }
        .scaleEffect(magnification).rotationEffect(Angle(radians: asset.rotation) + rotation)
        .position(
          x: (asset.frame.x + asset.frame.width * resize / 2) * viewScale + viewOffset.x,
          y: (asset.frame.y + asset.frame.height * resize / 2) * viewScale + viewOffset.y
        ).offset(drag)
        .gesture(
          DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded {
            value in
            var changed = asset
            changed.frame.x += value.translation.width / viewScale
            changed.frame.y += value.translation.height / viewScale
            onCommit(changed)
          }
        )
        .simultaneousGesture(
          MagnifyGesture().updating($magnification) { value, state, _ in
            state = max(0.1, min(10, value.magnification))
          }.onEnded { value in
            var changed = asset
            let factor = max(0.1, min(10, value.magnification))
            changed.frame.x += changed.frame.width * (1 - factor) / 2
            changed.frame.y += changed.frame.height * (1 - factor) / 2
            changed.frame.width *= factor
            changed.frame.height *= factor
            onCommit(changed)
          }
        )
        .simultaneousGesture(
          RotateGesture().updating($rotation) { value, state, _ in state = value.rotation }.onEnded
          { value in
            var changed = asset
            changed.rotation += value.rotation.radians
            onCommit(changed)
          }
        )
        .accessibilityLabel(
          "Selected image. Drag to move, pinch to resize, or rotate with two fingers.")
    }
  }
}
