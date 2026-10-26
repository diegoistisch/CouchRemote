import ActivityKit
import RemoteKit
import SwiftUI
import WidgetKit

@main
struct CouchRemoteWidgets: WidgetBundle {
    var body: some Widget {
        RemoteLiveActivity()
    }
}

/// Fernbedienung auf dem Sperrbildschirm und in der Dynamic Island.
/// Trackpad und Tastatur gehen hier nicht (Live Activities kennen nur Knöpfe),
/// dafür das Steuerkreuz, das am Mac die Startseite bedient.
struct RemoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            LockScreenView(macName: context.state.macName)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    KeyButton(key: .fullscreen, systemImage: "arrow.up.left.and.arrow.down.right", label: "Vollbild")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    KeyButton(key: .home, systemImage: "house", label: "Home")
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 8) {
                        Label(context.state.macName, systemImage: "tv")
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        PowerButton()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            KeyButton(key: .left, systemImage: "chevron.left", label: "Links")
                            KeyButton(key: .up, systemImage: "chevron.up", label: "Hoch")
                            KeyButton(key: .select, systemImage: "circle.fill", label: "OK")
                            KeyButton(key: .down, systemImage: "chevron.down", label: "Runter")
                            KeyButton(key: .right, systemImage: "chevron.right", label: "Rechts")
                        }
                        HStack(spacing: 6) {
                            KeyButton(key: .volumeDown, systemImage: "speaker.minus", label: "Leiser")
                            KeyButton(key: .mute, systemImage: "speaker.slash", label: "Stumm")
                            KeyButton(key: .playPause, systemImage: "playpause.fill", label: "Play/Pause",
                                      prominent: true)
                            KeyButton(key: .volumeUp, systemImage: "speaker.plus", label: "Lauter")
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "tv")
            } compactTrailing: {
                Image(systemName: "playpause.fill")
            } minimal: {
                Image(systemName: "tv")
            }
            .keylineTint(.accentColor)
        }
    }
}

private struct LockScreenView: View {
    let macName: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // Steuerkreuz mit OK in der Mitte
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    KeyButton(key: .up, systemImage: "chevron.up", label: "Hoch")
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
                GridRow {
                    KeyButton(key: .left, systemImage: "chevron.left", label: "Links")
                    KeyButton(key: .select, systemImage: "circle.fill", label: "OK", prominent: true)
                    KeyButton(key: .right, systemImage: "chevron.right", label: "Rechts")
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    KeyButton(key: .down, systemImage: "chevron.down", label: "Runter")
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            .frame(width: 124)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(macName, systemImage: "tv")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    PowerButton()
                }
                HStack(spacing: 6) {
                    KeyButton(key: .fullscreen, systemImage: "arrow.up.left.and.arrow.down.right", label: "Vollbild")
                    KeyButton(key: .home, systemImage: "house", label: "Home")
                    KeyButton(key: .playPause, systemImage: "playpause.fill", label: "Play/Pause",
                              prominent: true)
                }
                HStack(spacing: 6) {
                    KeyButton(key: .volumeDown, systemImage: "speaker.minus", label: "Leiser")
                    KeyButton(key: .mute, systemImage: "speaker.slash", label: "Stumm")
                    KeyButton(key: .volumeUp, systemImage: "speaker.plus", label: "Lauter")
                }
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

/// Knopf, der eine Taste über `RemoteKeyIntent` an den Mac schickt.
private struct KeyButton: View {
    let key: RemoteKey
    let systemImage: String
    let label: String
    var prominent = false

    var body: some View {
        Button(intent: RemoteKeyIntent(key)) {
            Image(systemName: systemImage)
                .font(.system(size: key == .select ? 12 : 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(prominent ? Color.accentColor : Color.white.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// ⏻: Fernseher einschalten (CouchHost schickt das Wake-on-LAN-Paket).
private struct PowerButton: View {
    var body: some View {
        Button(intent: TVPowerIntent()) {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fernseher ein/aus")
    }
}
