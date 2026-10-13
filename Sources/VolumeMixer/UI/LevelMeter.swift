import SwiftUI

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: geometry.size.width * CGFloat(displayLevel))
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.05), value: level)
    }

    /// Peak amplitude is linear; a mild curve makes quiet passages visible.
    private var displayLevel: Float {
        min(1, pow(max(0, level), 0.5))
    }
}
