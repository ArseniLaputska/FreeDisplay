import SwiftUI

struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    @State private var localBrightness: Double = 50
    @State private var isDragging: Bool = false
    @State private var valueHighlighted: Bool = false
    @State private var highlightTask: Task<Void, Never>?
    @State private var ddcStatus: Bool? = nil  // nil=unknown, true=DDC, false=Software
    /// Throttle DDC writes during drag to ~100ms intervals.
    @State private var lastDDCWrite: Date = .distantPast
    private static let sliderRange: ClosedRange<Double> = 5...100

    private static func sliderValue(_ value: Double) -> Double {
        guard value.isFinite else { return 50 }
        return min(sliderRange.upperBound, max(sliderRange.lowerBound, value))
    }

    var body: some View {
        VStack(spacing: 2) {
            // Mode indicator row
            HStack(spacing: 4) {
                Spacer()
                if display.isBuiltin {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("System")
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else if let status = ddcStatus {
                    Circle()
                        .fill(status ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(status ? "DDC" : "Software")
                        .font(.caption2)
                        .foregroundColor(status ? .green : .orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .accessibilityLabel(
                display.isBuiltin
                    ? String(localized: "Brightness control mode: System")
                    : (ddcStatus == true
                        ? String(localized: "Brightness control mode: DDC hardware")
                        : String(localized: "Brightness control mode: Software simulation"))
            )
            .help(display.isBuiltin ? "System brightness: controlled through macOS display APIs" : "DDC: direct hardware brightness control\nSoftware: simulated brightness through gamma")

            HStack(spacing: 6) {
                let sunIcon: String = {
                    if localBrightness < 30 { return "sun.min" }
                    else if localBrightness < 70 { return "sun.min.fill" }
                    else { return "sun.max.fill" }
                }()
                Image(systemName: sunIcon)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(width: 14)
                    .animation(.easeInOut(duration: 0.2), value: sunIcon)
                    .accessibilityHidden(true)

                Slider(value: $localBrightness, in: Self.sliderRange, step: 1) { editing in
                    isDragging = editing
                    if !editing {
                        // Drag ended — apply final value with smooth transition and show highlight.
                        withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = true }
                        highlightTask?.cancel()
                        highlightTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            withAnimation(.easeOut(duration: 0.3)) { valueHighlighted = false }
                        }
                        Task { @MainActor in
                            // Use smooth transition from current hardware brightness to slider value.
                            BrightnessService.shared.setBrightnessSmooth(localBrightness, for: display)
                            updateDDCStatus()
                        }
                        lastDDCWrite = Date()
                    }
                }
                .accessibilityLabel("Display brightness")
                .accessibilityValue("\(Int(localBrightness))%")
                .help("Drag to adjust brightness")
                .onChange(of: localBrightness) { _, newValue in
                    let safeValue = Self.sliderValue(newValue)
                    if safeValue != newValue {
                        localBrightness = safeValue
                        return
                    }
                    guard isDragging else { return }
                    // Apply immediately — the service chooses software or DDC internally.
                    // For DDC displays, throttle to ~100ms to avoid flooding the I2C bus.
                    let isDDC = ddcStatus == true
                    let now = Date()
                    if isDDC && now.timeIntervalSince(lastDDCWrite) < 0.1 {
                        // Too soon for another DDC write; the drag-end handler will flush the final value.
                        display.brightness = safeValue
                        return
                    }
                    lastDDCWrite = now
                    display.brightness = safeValue
                    Task { @MainActor in
                        await BrightnessService.shared.setBrightness(safeValue, for: display)
                    }
                }

                Image(systemName: "sun.max")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                let brightnessLabel: String = {
                    if ddcStatus == false {
                        return "\(String(localized: "Software")) \(Int(localBrightness))%"
                    }
                    return "\(Int(localBrightness))%"
                }()
                Text(brightnessLabel)
                    .font(.caption)
                    .foregroundColor(valueHighlighted ? .accentColor : .secondary)
                    .frame(width: 52, alignment: .trailing)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .task(id: display.displayID) {
            localBrightness = Self.sliderValue(display.brightness)
            updateDDCStatus()
        }
        .onChange(of: display.brightness) { _, newValue in
            let safeValue = Self.sliderValue(newValue)
            if !isDragging && abs(safeValue - localBrightness) >= 1 {
                localBrightness = safeValue
            }
        }
    }

    private func updateDDCStatus() {
        guard !display.isBuiltin else {
            ddcStatus = nil
            return
        }
        ddcStatus = BrightnessService.shared.isDDCAvailable(for: display.displayID) ?? false
    }
}

struct CombinedBrightnessView: View {
    let displays: [DisplayInfo]
    @State private var combinedBrightness: Double = 50
    @State private var isDragging: Bool = false
    /// Throttle DDC writes during drag to ~100ms intervals.
    @State private var lastDDCWrite: Date = .distantPast
    private static let sliderRange: ClosedRange<Double> = 5...100

    private static func sliderValue(_ value: Double) -> Double {
        guard value.isFinite else { return 50 }
        return min(sliderRange.upperBound, max(sliderRange.lowerBound, value))
    }

    private var averageBrightness: Double {
        guard !displays.isEmpty else { return 50 }
        let values = displays.map { Self.sliderValue($0.brightness) }
        return values.reduce(0, +) / Double(values.count)
    }

    /// True if any display in the group uses DDC (so we apply throttle).
    private var anyDDC: Bool {
        displays.contains { BrightnessService.shared.isDDCAvailable(for: $0.displayID) == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
                    .accessibilityHidden(true)
                Text("Brightness (combined)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(combinedBrightness))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                Slider(value: $combinedBrightness, in: Self.sliderRange, step: 1) { editing in
                    isDragging = editing
                    if !editing {
                        // Drag ended — flush final value to all displays with smooth transition.
                        Task { @MainActor in
                            for display in displays {
                                BrightnessService.shared.setBrightnessSmooth(combinedBrightness, for: display)
                            }
                        }
                        lastDDCWrite = Date()
                    }
                }
                .accessibilityLabel("Combined brightness")
                .accessibilityValue("\(Int(combinedBrightness))%")
                .onChange(of: combinedBrightness) { _, newValue in
                    let safeValue = Self.sliderValue(newValue)
                    if safeValue != newValue {
                        combinedBrightness = safeValue
                        return
                    }
                    guard isDragging else { return }
                    let now = Date()
                    if anyDDC && now.timeIntervalSince(lastDDCWrite) < 0.1 {
                        // Throttle DDC — update model only; drag-end flushes final value.
                        for display in displays { display.brightness = safeValue }
                        return
                    }
                    lastDDCWrite = now
                    Task { @MainActor in
                        for display in displays {
                            display.brightness = safeValue
                            await BrightnessService.shared.setBrightness(safeValue, for: display)
                        }
                    }
                }

                Image(systemName: "sun.max")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear {
            combinedBrightness = Self.sliderValue(averageBrightness)
        }
        .onChange(of: averageBrightness) { _, newValue in
            guard !isDragging else { return }
            combinedBrightness = Self.sliderValue(newValue)
        }
    }
}
