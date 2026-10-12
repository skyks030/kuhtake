import SwiftUI

enum FormatWindow {
    static func show() {
        WindowPresenter.shared.show(id: "format", title: "Dateiformat", size: CGSize(width: 520, height: 470)) {
            FormatView()
        }
    }
}

struct FormatView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Video") {
                Picker("Codec", selection: $settings.codec) {
                    ForEach(VideoCodecOption.allCases) { Text($0.label).tag($0) }
                }
                Picker("Container", selection: $settings.container) {
                    ForEach(ContainerFormat.allCases) { Text($0.label).tag($0) }
                }
                .disabled(settings.codec.isProRes)
                if settings.codec.isProRes {
                    Text("ProRes wird immer als QuickTime (.mov) gespeichert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Auflösung", selection: $settings.resolution) {
                    ForEach(ResolutionMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Bildrate", selection: $settings.frameRate) {
                    ForEach(FrameRateOption.allCases) { Text($0.label).tag($0) }
                }
                if !settings.codec.isProRes {
                    LabeledContent("Datenrate") {
                        HStack {
                            Slider(value: Binding(get: { settings.bitrateMbps }, set: { settings.bitrateMbps = $0.rounded() }), in: 2...100)
                            Text("\(Int(settings.bitrateMbps)) Mbit/s").monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Ton & Bild") {
                Toggle("Ton der Quelle mit aufnehmen", isOn: $settings.recordAudio)
                Toggle("Mauszeiger mit aufnehmen", isOn: $settings.showCursor)
            }
            Section {
                Text("„Native Auflösung“ übernimmt die Pixelgröße des Fensters bzw. Bildschirms beim Start der Aufnahme. Bei festen Formaten wird das Bild ins Format eingepasst; freie Flächen werden schwarz (Letterbox/Pillarbox). Der Ton wird direkt aus der App abgegriffen – auch wenn der Mac stumm geschaltet ist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}
