import SwiftUI

// MARK: - Menu bar panel

/// Compact panel shown when the menu bar icon is clicked.
struct MenuBarPanel: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            stats
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("iPadScreen")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            StatusBadge(state: state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            PairingCodeView(state: state, compact: true)
            ConnectionPicker(state: state)
            DisplayPicker(state: state)
            FPSSlider(state: state)
            QualityControl(state: state)
            ScaleSlider(state: state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var stats: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                StatItem(value: String(format: "%.0f", state.currentFPS), unit: "fps")
                StatItem(value: String(format: "%.0f", state.currentQuality * 100), unit: "% quality")
                StatItem(value: String(format: "%.1f", state.megabitsPerSecond), unit: "Mbps")
            }
            Sparkline(values: state.fpsHistory, maximum: Double(max(state.targetFPS, 1)))
                .frame(height: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Button(state.isRunning ? "Stop" : "Start") {
                state.onStartStop?(!state.isRunning)
            }
            .keyboardShortcut(.defaultAction)

            Spacer()

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "macwindow")
            }
            .help("Open window")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Main window

struct MainWindow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HSplitView {
            preview
                .frame(minWidth: 380)
            sidebar
                .frame(width: 300)
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    private var preview: some View {
        VStack(spacing: 14) {
            HStack {
                StatusBadge(state: state)
                Spacer()
                Text(state.frameSize == .zero ? "—"
                     : "\(Int(state.frameSize.width))×\(Int(state.frameSize.height))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Live frame rate chart. The picture itself isn't shown here:
            // drawing a second copy would add load to the stream capturing
            // the mirrored display.
            Sparkline(values: state.fpsHistory, maximum: Double(max(state.targetFPS, 1)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 20) {
                StatItem(value: String(format: "%.0f", state.currentFPS), unit: "fps")
                StatItem(value: String(format: "%.0f", state.currentQuality * 100), unit: "% quality")
                StatItem(value: String(format: "%.1f", state.megabitsPerSecond), unit: "Mbps")
                StatItem(value: "\(state.clientCount)", unit: "devices")
            }
        }
        .padding(18)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))

                PairingCodeView(state: state, compact: false)

                Divider()

                ConnectionPicker(state: state)
                DisplayPicker(state: state)

                Divider()

                FPSSlider(state: state)
                QualityControl(state: state)
                ScaleSlider(state: state)

                Divider()

                Button(state.isRunning ? "Stop" : "Start") {
                    state.onStartStop?(!state.isRunning)
                }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(18)
        }
    }
}

// MARK: - Shared components

struct StatusBadge: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        if !state.isRunning { return .secondary }
        return state.clientCount > 0 ? .green : .orange
    }

    private var text: String {
        // If something is wrong, saying what is more useful than
        // "Stopped": this is where the user learns why it isn't running.
        if !state.statusText.isEmpty && !state.isRunning { return state.statusText }
        if !state.isRunning { return "Stopped" }
        if state.clientCount == 0 { return "Waiting for iPad" }
        // USB selected but running over Wi-Fi: say so, rather than showing
        // a label that contradicts the picker.
        if state.useUSB && state.connection == .wifi { return "Wi-Fi · no USB cable" }
        return "\(state.connection.rawValue) · connected"
    }
}

/// The pairing code a device enters to get the stream over Wi-Fi.
struct PairingCodeView: View {
    @ObservedObject var state: AppState
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pairing code")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Text(state.pairingCode)
                    .font(.system(size: compact ? 20 : 30, weight: .semibold, design: .monospaced))
                    .kerning(compact ? 4 : 8)
                    .textSelection(.enabled)
                Spacer()
                Button("New code") { state.onRegenerateCode?() }
                    .controlSize(.small)
                    .help("Pick a new code and forget every paired iPad")
            }

            if !compact {
                Text("Needed once, to pair an iPad over Wi-Fi. Connecting the cable pairs it without a code.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ConnectionPicker: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connection")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("", selection: $state.useUSB) {
                Text("Wi-Fi").tag(false)
                Text("USB").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(state.useUSB
                 ? "Uses the cable when attached, Wi-Fi otherwise. Also changes the iPad app."
                 : "Wi-Fi only. Also changes the iPad app.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

struct DisplayPicker: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mirrored display")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("", selection: $state.selectedDisplayID) {
                ForEach(state.availableDisplays) { display in
                    Text(display.label).tag(display.id)
                }
            }
            .labelsHidden()
        }
    }
}

struct FPSSlider: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Frame rate")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(state.targetFPS) fps")
                    .font(.system(size: 11, design: .monospaced))
            }
            Slider(
                value: Binding(
                    get: { Double(state.targetFPS) },
                    set: { state.targetFPS = Int($0) }),
                in: 5...60, step: 5)
        }
    }
}

struct QualityControl: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Quality")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Automatic", isOn: $state.autoQuality)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
            }

            HStack(spacing: 8) {
                Slider(value: $state.manualQuality, in: 0.15...0.95)
                    .disabled(state.autoQuality)
                Text("\(Int((state.autoQuality ? state.currentQuality : state.manualQuality) * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 34, alignment: .trailing)
                    .foregroundStyle(state.autoQuality ? .secondary : .primary)
            }
        }
    }
}

struct ScaleSlider: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Resolution scale")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", state.scale * 100))
                    .font(.system(size: 11, design: .monospaced))
            }
            Slider(value: $state.scale, in: 0.25...1.0, step: 0.05)
            Text("Lowering it cuts decode work on the iPad; it affects frame rate the most.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

struct StatItem: View {
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}

/// Small chart of the last 60 frame rate samples.
struct Sparkline: View {
    let values: [Double]
    let maximum: Double

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let scale = max(maximum, values.max() ?? 1)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geo.size.width * Double(index) / Double(values.count - 1)
                        let y = geo.size.height * (1 - min(value / scale, 1))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}
