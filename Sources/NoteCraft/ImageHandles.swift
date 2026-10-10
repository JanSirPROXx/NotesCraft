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
  var body: some View {
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    {
      Image(decorative: image, scale: 1)
        .resizable().frame(
          width: asset.frame.width * viewScale, height: asset.frame.height * viewScale
        )
        .overlay {
          Rectangle().stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        .overlay(alignment: .bottomTrailing) {
          Circle().fill(.white).overlay(Circle().stroke(.blue, lineWidth: 2)).frame(
            width: 12, height: 12
          ).offset(x: 6, y: 6)
        }
        .scaleEffect(magnification).rotationEffect(Angle(radians: asset.rotation) + rotation)
        .position(
          x: (asset.frame.x + asset.frame.width / 2) * viewScale + viewOffset.x,
          y: (asset.frame.y + asset.frame.height / 2) * viewScale + viewOffset.y
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
