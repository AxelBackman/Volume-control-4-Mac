import SwiftUI

struct AppRowView: View {
    let row: MixerRow
    let icon: NSImage?
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 24, height: 24)
                .opacity(row.isMuted ? 0.4 : (row.isPlaying ? 1 : 0.55))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(row.isPlaying ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text("\(Int((row.isMuted ? 0 : row.volume) * 100))%")
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: Binding(get: { Double(row.volume) },
                                      set: { onVolumeChange(Float($0)) }),
                       in: 0...1)
                    .controlSize(.small)
                    .disabled(row.isMuted)

                LevelMeter(level: row.isMuted ? 0 : row.level)
            }

            Button(action: onToggleMute) {
                Image(systemName: row.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(row.isMuted ? Color.red : Color.secondary)
            .help(row.isMuted ? "Unmute" : "Mute")
        }
        .padding(.vertical, 4)
        .opacity(row.hasStream ? 1 : 0.55)
        .help(row.hasStream ? row.name : "\(row.name) - idle, no audio stream open")
        .animation(.easeInOut(duration: 0.15), value: row.isPlaying)
        .animation(.easeInOut(duration: 0.15), value: row.hasStream)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.secondary)
        }
    }
}
