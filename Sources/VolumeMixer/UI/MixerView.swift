import SwiftUI

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MixerView: View {
    @Bindable var viewModel: MixerViewModel

    /// Measured height of the app rows, so the scroll view gets a real height instead of
    /// collapsing inside the self-sizing menu bar window.
    @State private var contentHeight: CGFloat = 0

    private let maxListHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let message = viewModel.status.message {
                banner(message)
            }

            Divider()
            masterRow
            Divider()

            if viewModel.rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(viewModel.rows) { row in
                            AppRowView(row: row,
                                       icon: viewModel.icon(for: row),
                                       onVolumeChange: { viewModel.setVolume($0, for: row.id) },
                                       onToggleMute: { viewModel.toggleMute(for: row.id) })
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: ContentHeightKey.self, value: geometry.size.height)
                        }
                    )
                }
                .frame(height: min(max(contentHeight, 60), maxListHeight))
                .onPreferenceChange(ContentHeightKey.self) { height in
                    contentHeight = height
                }
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    /// Drives the output device's own volume when it has one, otherwise scales every tapped
    /// app. Which of the two is in play only shows up in the tooltip - the difference matters
    /// (the device volume also covers audio the mixer never sees) but not enough to spend a
    /// line of the popover on.
    private var masterRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13))
                .frame(width: 24)
                .foregroundStyle(viewModel.masterMuted ? Color.red : Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Master audio")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("\(Int((viewModel.masterMuted ? 0 : viewModel.masterVolume) * 100))%")
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(viewModel.masterVolume) },
                                      set: { viewModel.setMasterVolume(Float($0)) }),
                       in: 0...1)
                    .controlSize(.small)
                    .disabled(viewModel.masterMuted)
            }

            Button(action: { viewModel.toggleMasterMute() }) {
                Image(systemName: viewModel.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(viewModel.masterMuted ? Color.red : Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(viewModel.status.masterIsSystemVolume
              ? "Controls the output device volume, like the volume keys"
              : "\(viewModel.status.outputDeviceName) has no software volume, so this scales the apps below")
    }

    private var header: some View {
        HStack {
            Text("Volume Mixer")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !viewModel.status.outputDeviceName.isEmpty {
                Text(viewModel.status.outputDeviceName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.status.permission == .denied {
                    Button("Open Privacy Settings") { viewModel.openPermissionSettings() }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No apps are playing audio")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: $viewModel.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
