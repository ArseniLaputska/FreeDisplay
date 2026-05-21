import SwiftUI

// MARK: - DisplayDetailView

struct DisplayDetailView: View {
    @Bindable var display: DisplayInfo
    @Environment(DisplayManager.self) var displayManager
    
    private let ddcService = DDCService.shared
    
    @State private var showModeList: Bool = false
    @State private var showDDCControl: Bool = false
    @State private var showColorProfile: Bool = false
    @State private var showAdvancedDisplay: Bool = false
    @State private var showImageAdjustment: Bool = false
    @State private var colorSpaceName: String = ""

    private func sectionKey(_ name: String) -> String {
        "fd.expanded.\(display.displayUUID).\(name)"
    }

    private func loadExpanded(_ name: String, default value: Bool) -> Bool {
        let key = sectionKey(name)
        guard UserDefaults.standard.object(forKey: key) != nil else { return value }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func saveExpanded(_ name: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: sectionKey(name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Brightness slider
            BrightnessSliderView(display: display)

            if !display.isBuiltin {
                Divider().opacity(0.3).padding(.vertical, 2)

                ExpandableRow(
                    icon: "slider.horizontal.below.rectangle",
                    iconColor: .green,
                    label: "DDC Control",
                    subtitle: ddcSubtitle,
                    isExpanded: $showDDCControl
                )

                if showDDCControl {
                    DDCControlPanelView(display: display)
                        .padding(.leading, 8)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        ))
                }
            }

            Divider().opacity(0.3).padding(.vertical, 2)

            // HiDPI toggle — before mode list (natural workflow: enable HiDPI → pick resolution)
            HiDPIRowView(display: display)

            // Display mode list toggle row
            ExpandableRow(
                icon: "rectangle.on.rectangle",
                label: "Display Mode",
                subtitle: {
                    var parts: [String] = []
                    if let mode = display.currentDisplayMode {
                        parts.append(mode.resolutionString)
                    }
                    if display.currentDisplayMode?.isHiDPI == true {
                        parts.append("HiDPI")
                    }
                    return parts.joined(separator: " · ")
                }(),
                isExpanded: $showModeList
            )

            if showModeList {
                DisplayModeListView(display: display)
                    .padding(.leading, 8)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }

            Divider().opacity(0.3).padding(.vertical, 2)

            // Color profile section
            ExpandableRow(
                icon: "paintpalette.fill",
                iconColor: .purple,
                label: "Color Profile",
                subtitle: colorSpaceName,
                isExpanded: $showColorProfile
            )

            if showColorProfile {
                ColorProfileView(display: display)
                    .padding(.leading, 8)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }

            ExpandableRow(
                icon: "waveform.path.ecg.rectangle",
                iconColor: .teal,
                label: "Advanced Display",
                subtitle: "HDR / EDID",
                isExpanded: $showAdvancedDisplay
            )

            if showAdvancedDisplay {
                AdvancedDisplayPanelView(display: display)
                    .padding(.leading, 8)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }

            // Image adjustment section
            ExpandableRow(
                icon: "slider.horizontal.3",
                label: "Image Adjustments",
                isExpanded: $showImageAdjustment
            )

            if showImageAdjustment {
                ImageAdjustmentView(display: display)
                    .padding(.leading, 8)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }

            Divider().opacity(0.3).padding(.vertical, 2)

            // Set as main display
            MainDisplayView(display: display)

            // Notch management (built-in with notch only)
            NotchView(display: display)

        }
        .padding(.leading, 32)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .onAppear {
            showModeList = loadExpanded("modeList", default: false)
            showDDCControl = loadExpanded("ddcControl", default: false)
            showColorProfile = loadExpanded("colorProfile", default: false)
            showAdvancedDisplay = loadExpanded("advancedDisplay", default: false)
            showImageAdjustment = loadExpanded("imageAdjust", default: false)
        }
        .onChange(of: showModeList) { _, v in saveExpanded("modeList", v) }
        .onChange(of: showDDCControl) { _, v in saveExpanded("ddcControl", v) }
        .onChange(of: showColorProfile) { _, v in saveExpanded("colorProfile", v) }
        .onChange(of: showAdvancedDisplay) { _, v in saveExpanded("advancedDisplay", v) }
        .onChange(of: showImageAdjustment) { _, v in saveExpanded("imageAdjust", v) }
        .task(id: display.displayID) {
            if display.availableModes.isEmpty {
                await display.loadDetails()
            }

            colorSpaceName = ""
            guard !Task.isCancelled else { return }
            let service = ColorProfileService.shared
            if let url = service.currentProfileURL(for: display.displayID),
               let profile = ColorProfileService.makeProfile(from: url) {
                colorSpaceName = profile.name
            } else {
                colorSpaceName = service.currentColorSpaceName(for: display.displayID)
            }
        }
    }

    private var ddcSubtitle: String {
        if ddcService.ddcSuppressedDisplayIDs.contains(display.displayID)
            || ddcService.isDDCReadSuppressed(for: display.displayID) {
            return "Unavailable"
        }
        return BrightnessService.shared.isDDCAvailable(for: display.displayID) == true ? "Hardware" : "Diagnostics"
    }
}

// MARK: - DDCControlPanelView

private struct DDCControlPanelView: View {
    @Bindable var display: DisplayInfo

    @State private var snapshots: [DDCService.VCPFeatureSnapshot] = []
    @State private var isLoading: Bool = false
    @State private var isRunningCommand: Bool = false
    @State private var isDDCUnavailable: Bool = false
    @State private var statusMessage: String?
    @State private var contrast: Double = 50
    @State private var volume: Double = 50
    @State private var selectedInputID: UInt16 = DDCService.commonInputSources.first?.id ?? 0x11

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            commandHeader
            if isDDCUnavailable {
                ddcUnavailableRow
            } else {
                contrastRow
                volumeRow
                inputRow
                powerRow
            }
            diagnosticsRows
        }
        .task(id: display.displayID) {
            await refreshDiagnostics()
        }
    }

    private var commandHeader: some View {
        HStack(spacing: 6) {
            Text("DDC/CI")
                .font(.caption)
                .foregroundColor(isDDCUnavailable ? .red : .secondary)
            Spacer()
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Button {
                Task { await refreshDiagnostics() }
            } label: {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help("Refresh DDC diagnostics")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var contrastRow: some View {
        DDCSliderRow(
            icon: "circle.righthalf.filled",
            title: "Contrast",
            value: $contrast,
            isDisabled: isRunningCommand
                || isDDCUnavailable
        ) { value in
            await writePercent(code: DDCService.contrastVCP, value: value, successText: "Contrast written")
        }
    }

    private var volumeRow: some View {
        DDCSliderRow(
            icon: "speaker.wave.2.fill",
            title: "Volume",
            value: $volume,
            isDisabled: isRunningCommand || isDDCUnavailable
        ) { value in
            await writePercent(code: DDCService.volumeVCP, value: value, successText: "Volume written")
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cable.connector")
                .foregroundColor(.green)
                .frame(width: 18)
                .font(.caption)
                .accessibilityHidden(true)

            Text("Input")
                .font(.caption)
                .frame(width: 76, alignment: .leading)

            Picker("", selection: $selectedInputID) {
                ForEach(DDCService.commonInputSources) { source in
                    Text(source.label).tag(source.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(isRunningCommand || isDDCUnavailable)

            Button("Apply") {
                Task {
                    guard let source = DDCService.commonInputSources.first(where: { $0.id == selectedInputID }) else { return }
                    await runCommand(successText: "Input written") {
                        await DDCService.shared.setInputSource(source, displayID: display.displayID)
                    }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isRunningCommand || isDDCUnavailable)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private var powerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "power")
                .foregroundColor(.green)
                .frame(width: 18)
                .font(.caption)
                .accessibilityHidden(true)

            Text("Soft Off")
                .font(.caption)
                .frame(width: 76, alignment: .leading)

            Button("Wake") {
                Task {
                    await runCommand(successText: "Wake command sent") {
                        await DDCService.shared.setPowerMode(.on, displayID: display.displayID)
                    }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isRunningCommand || isDDCUnavailable)

            Button("Standby") {
                Task {
                    await runCommand(successText: "Standby command sent") {
                        await DDCService.shared.setPowerMode(.standby, displayID: display.displayID)
                    }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isRunningCommand || isDDCUnavailable)

            Button("Off") {
                Task {
                    await runCommand(successText: "Off command sent") {
                        await DDCService.shared.setPowerMode(.off, displayID: display.displayID)
                    }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.red)
            .disabled(isRunningCommand || isDDCUnavailable)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .help("Sends DDC VCP 0xD6 power commands. This is not a true macOS disconnect.")
    }

    private var ddcUnavailableRow: some View {
        CapabilityNoticeRow(
            icon: "exclamationmark.triangle.fill",
            color: .orange,
            title: "DDC/CI unavailable on this link",
            detail: "This connection is falling back to software brightness."
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var diagnosticsRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isDDCUnavailable {
                EmptyView()
            } else if snapshots.isEmpty && !isLoading {
                Text("No DDC diagnostics yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                SectionBadgeSmall(title: "VCP Diagnostics")
                ForEach(snapshots) { snapshot in
                    DDCSnapshotRow(snapshot: snapshot)
                }
            }
        }
    }

    @MainActor
    private func refreshDiagnostics() async {
        guard !isLoading else { return }
        isLoading = true
        statusMessage = nil
        if DDCService.shared.isDDCReadSuppressed(for: display.displayID) {
            isDDCUnavailable = true
            statusMessage = "DDC unavailable"
            snapshots = DDCService.diagnosticFeatures.map {
                DDCService.VCPFeatureSnapshot(feature: $0, current: nil, max: nil)
            }
            isLoading = false
            return
        }

        let loaded = await DDCService.shared.readDiagnosticSnapshot(displayID: display.displayID)
        snapshots = loaded
        applySnapshotValues(loaded)
        isDDCUnavailable = loaded.allSatisfy { $0.current == nil }
            || DDCService.shared.isDDCReadSuppressed(for: display.displayID)
        if isDDCUnavailable {
            statusMessage = "DDC unavailable"
        }
        isLoading = false
    }

    @MainActor
    private func writePercent(code: UInt8, value: Double, successText: String) async {
        await runCommand(successText: successText) {
            await DDCService.shared.writePercentVCP(
                displayID: display.displayID,
                command: code,
                percent: value
            )
        }
    }

    @MainActor
    private func runCommand(successText: String, action: @escaping () async -> Bool) async {
        guard !isRunningCommand else { return }
        guard !isDDCUnavailable else {
            statusMessage = "DDC unavailable"
            return
        }
        isRunningCommand = true
        statusMessage = nil
        let success = await action()
        statusMessage = success ? successText : "DDC write failed"
        isRunningCommand = false
        if success {
            await refreshDiagnostics()
        }
    }

    private func applySnapshotValues(_ snapshots: [DDCService.VCPFeatureSnapshot]) {
        for snapshot in snapshots {
            guard let current = snapshot.current else { continue }
            switch snapshot.feature.code {
            case DDCService.contrastVCP:
                contrast = percentValue(current: current, max: snapshot.max)
            case DDCService.volumeVCP:
                volume = percentValue(current: current, max: snapshot.max)
            case DDCService.inputSourceVCP:
                selectedInputID = current
            default:
                break
            }
        }
    }

    private func percentValue(current: UInt16, max maximum: UInt16?) -> Double {
        guard let maximum, maximum > 0 else { return min(100.0, Double(current)) }
        return min(100.0, Swift.max(0.0, Double(current) / Double(maximum) * 100.0))
    }
}

private struct DDCSliderRow: View {
    let icon: String
    let title: LocalizedStringKey
    @Binding var value: Double
    let isDisabled: Bool
    let onCommit: (Double) async -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.green)
                .frame(width: 18)
                .font(.caption)
                .accessibilityHidden(true)

            Text(title)
                .font(.caption)
                .frame(width: 76, alignment: .leading)

            Slider(value: $value, in: 0...100, step: 1) { editing in
                if !editing {
                    Task { await onCommit(value) }
                }
            }
            .disabled(isDisabled)

            Text("\(Int(value))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

private struct SectionBadgeSmall: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

private struct CapabilityNoticeRow: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
                .font(.caption)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct DDCSnapshotRow: View {
    let snapshot: DDCService.VCPFeatureSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Text(snapshot.feature.codeString)
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospaced()
                .frame(width: 38, alignment: .leading)

            Text(snapshot.feature.name)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Text(snapshot.valueString)
                .font(.caption2)
                .foregroundColor(snapshot.current == nil ? .red : .secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

// MARK: - AdvancedDisplayPanelView

private struct AdvancedDisplayPanelView: View {
    @Bindable var display: DisplayInfo
    @Environment(DisplayManager.self) var displayManager
    @State private var state: AdvancedDisplayState?
    @State private var statusMessage: String?
    @State private var selectedOutputModeID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Display Link")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if let state {
                AdvancedInfoRow(label: "Signal", value: signalSummary(state))
                AdvancedInfoRow(label: "Dynamic Range", value: dynamicRangeSummary(state))
                AdvancedInfoRow(label: "Display ID", value: "\(state.vendorID) / \(state.productID)")

                if hasPrivateControls(state) {
                    CapabilityNoticeRow(
                        icon: "checkmark.circle.fill",
                        color: .green,
                        title: "Advanced controls available",
                        detail: "Only capabilities reported by this display are shown below."
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                } else {
                    CapabilityNoticeRow(
                        icon: "info.circle.fill",
                        color: .secondary,
                        title: "No private controls exposed for this display",
                        detail: "The panel stays read-only; software brightness and HiDPI overrides can still work."
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                if state.canSetOutputMode {
                    outputModeRow(state)
                }

                if state.canSetHDR || state.canRequestHeadroom || state.canSoftDisconnect {
                    HStack(spacing: 8) {
                        if state.canSetHDR {
                            Button(state.hdrEnabled == true ? "Disable HDR" : "Enable HDR") {
                                let next = !(state.hdrEnabled ?? false)
                                let ok = AdvancedDisplayService.shared.setHDRMode(next, for: display.displayID)
                                statusMessage = ok ? "HDR toggled" : "HDR private API disabled"
                                refresh()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }

                        if state.canRequestHeadroom {
                            Button("Max Headroom") {
                                let target = max(state.potentialHeadroom ?? state.edrPotential, 1.0)
                                let ok = AdvancedDisplayService.shared.requestHeadroom(target, for: display.displayID)
                                statusMessage = ok ? "Max headroom requested" : "Headroom API disabled"
                                refresh()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)

                            Button("Reset Headroom") {
                                let ok = AdvancedDisplayService.shared.requestHeadroom(1.0, for: display.displayID)
                                statusMessage = ok ? "Headroom reset" : "Headroom API disabled"
                                refresh()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }

                        if state.canSoftDisconnect {
                            Button("Soft Disconnect") {
                                let ok = AdvancedDisplayService.shared.softDisconnect(display: display)
                                statusMessage = ok ? "Display disabled" : "Soft disconnect unavailable"
                                if ok {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                        displayManager.refreshDisplays()
                                    }
                                } else {
                                    refresh()
                                }
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }

                if state.canForceColorOutput {
                    HStack(spacing: 8) {
                        Button("System Color") {
                            forceColorMode(0)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        Button("Force RGB") {
                            forceColorMode(1)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        Button("Force YCbCr") {
                            forceColorMode(2)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }

                HStack(spacing: 8) {
                    if state.hasEDID {
                        Button("Copy EDID") {
                            let ok = AdvancedDisplayService.shared.copyEDIDHex(for: display.displayID)
                            statusMessage = ok ? "EDID copied" : "No EDID"
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    Button("Software Boost") {
                        let adj = GammaAdjustment(gain: 20)
                        GammaService.shared.apply(adj, for: display.displayID)
                        statusMessage = "Software boost applied"
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Button("Reset") {
                        GammaService.shared.resetSingleDisplay(display.displayID)
                        statusMessage = "Reset"
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else {
                Text("Reading...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .task(id: display.displayID) {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    @ViewBuilder
    private func outputModeRow(_ state: AdvancedDisplayState) -> some View {
        let selected = state.outputModes.first { $0.id == selectedOutputModeID }
            ?? state.outputModes.first(where: \.isActive)
            ?? state.outputModes.first

        HStack(spacing: 8) {
            Text("Output")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)

            Picker("", selection: $selectedOutputModeID) {
                ForEach(state.outputModes) { mode in
                    Text(mode.label).tag(mode.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 110)

            Button("Apply") {
                applySelectedOutputMode(state)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!state.canSetOutputMode || selected == nil)
            .help(selected?.tokenDescription ?? "No output mode selected")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)

        if let selected {
            AdvancedInfoRow(label: "Output Token", value: selected.tokenDescription)
        }
    }

    private func refresh() {
        let next = AdvancedDisplayService.shared.state(for: display.displayID)
        state = next
        if selectedOutputModeID.isEmpty || !next.outputModes.contains(where: { $0.id == selectedOutputModeID }) {
            selectedOutputModeID = next.outputModes.first(where: \.isActive)?.id ?? next.outputModes.first?.id ?? ""
        }
    }

    private func applySelectedOutputMode(_ state: AdvancedDisplayState) {
        guard let mode = state.outputModes.first(where: { $0.id == selectedOutputModeID }) else {
            statusMessage = "No output mode selected"
            return
        }
        let ok = AdvancedDisplayService.shared.setOutputMode(mode, for: display.displayID)
        statusMessage = ok ? "Output mode applied" : "Output mode failed"
        refresh()
    }

    private func forceColorMode(_ rawMode: Int32) {
        let ok = AdvancedDisplayService.shared.forceColorOutput(rawMode, for: display.displayID)
        statusMessage = ok ? "Color command sent" : "Color private API unavailable"
        refresh()
    }

    private func hasPrivateControls(_ state: AdvancedDisplayState) -> Bool {
        state.canSetHDR ||
        state.canRequestHeadroom ||
        state.canForceColorOutput ||
        state.canSetOutputMode ||
        state.canSoftDisconnect ||
        state.hasEDID
    }

    private func signalSummary(_ state: AdvancedDisplayState) -> String {
        let transport = state.colorTransport == "Unknown" ? "transport unknown" : state.colorTransport
        let encoding = state.pixelEncoding == "Unknown" ? "" : " · \(state.pixelEncoding)"
        return "\(transport) · \(state.bitsPerChannel)-bit\(encoding)"
    }

    private func dynamicRangeSummary(_ state: AdvancedDisplayState) -> String {
        if let nits = state.displayNits {
            return "\(state.dynamicRange) · \(String(format: "%.0f", nits)) nits"
        }
        let headroom = state.potentialHeadroom ?? state.edrPotential
        if headroom > 1.0 {
            return "\(state.dynamicRange) · \(String(format: "%.2fx", headroom)) headroom"
        }
        return state.dynamicRange
    }
}

private struct AdvancedInfoRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
