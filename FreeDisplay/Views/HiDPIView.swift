import SwiftUI

struct HiDPIRowView: View {
    @Bindable var display: DisplayInfo
    @State private var isHovered = false
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var isHiDPIOn: Bool = false
    @State private var selectedPresetID: String = "1920x1080"
    @State private var customWidth: String = "1920"
    @State private var customHeight: String = "1080"

    private var presetModes: [HiDPIService.LogicalResolution] {
        let (nativeW, nativeH) = display.nativeResolution
        let aspect = Double(nativeW) / Double(max(nativeH, 1))
        let common: [HiDPIService.LogicalResolution] = [
            .init(width: 1280, height: Int((1280.0 / aspect).rounded()) & ~1),
            .init(width: 1600, height: Int((1600.0 / aspect).rounded()) & ~1),
            .init(width: 1920, height: Int((1920.0 / aspect).rounded()) & ~1),
            .init(width: 2048, height: Int((2048.0 / aspect).rounded()) & ~1),
            .init(width: 2560, height: Int((2560.0 / aspect).rounded()) & ~1),
            .init(width: 3008, height: Int((3008.0 / aspect).rounded()) & ~1),
        ]
        var seen = Set<String>()
        return common
            .filter { $0.width >= 800 && $0.height >= 600 && $0.width <= nativeW }
            .filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        let (nativeW, nativeH) = display.nativeResolution

        if display.isBuiltin || (nativeW <= 1920 && nativeH <= 1080) {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    MenuItemIcon(systemName: "sparkles", color: .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HiDPI Mode")
                            .font(.body)
                        Text(isHiDPIOn ? "Override installed" : "Admin permission required")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else if isHiDPIOn {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(isHovered ? 0.06 : 0))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isLoading else { return }
                    toggle()
                }

                customControls
            }
            .onHover { isHovered = $0 }
            .onAppear {
                isHiDPIOn = HiDPIService.shared.isHiDPIEnabled(
                    vendor: display.vendorNumber,
                    product: display.modelNumber
                )
            }
            .alert("HiDPI action failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let msg = errorMessage {
                    Text(msg)
                }
            }
        }
    }

    private var customControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Scale")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 42, alignment: .leading)

                Picker("", selection: $selectedPresetID) {
                    ForEach(presetModes) { mode in
                        Text(mode.label).tag(mode.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                Button("Write") {
                    applyCustomModes(includeCustom: false)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isLoading || presetModes.isEmpty)
            }

            HStack(spacing: 6) {
                Text("Custom")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 42, alignment: .leading)

                TextField("W", text: $customWidth)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 56)

                Text("×")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("H", text: $customHeight)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 56)

                Button("Add + Write") {
                    applyCustomModes(includeCustom: true)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isLoading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
    }

    private func toggle() {
        isLoading = true
        if isHiDPIOn {
            let err = HiDPIService.shared.disableHiDPI(
                for: display.displayID,
                vendor: display.vendorNumber,
                product: display.modelNumber
            )
            isLoading = false
            if let err {
                errorMessage = err
            } else {
                isHiDPIOn = false
            }
        } else {
            Task {
                // Use the highest available mode as native resolution,
                // not display.pixelWidth which is the CURRENT resolution
                let (nativeW, nativeH) = display.nativeResolution
                let err = await HiDPIService.shared.enableHiDPI(
                    for: display.displayID,
                    vendor: display.vendorNumber,
                    product: display.modelNumber,
                    nativeWidth: nativeW,
                    nativeHeight: nativeH
                )
                isLoading = false
                if let err {
                    errorMessage = err
                } else {
                    isHiDPIOn = true
                    HiDPIService.shared.refreshModes(for: display)
                }
            }
        }
    }

    private func applyCustomModes(includeCustom: Bool) {
        let modes = customModeList(includeCustom: includeCustom)
        guard !modes.isEmpty else {
            errorMessage = "No valid HiDPI resolution"
            return
        }
        isLoading = true
        Task {
            let (nativeW, nativeH) = display.nativeResolution
            let err = await HiDPIService.shared.enableHiDPI(
                for: display.displayID,
                vendor: display.vendorNumber,
                product: display.modelNumber,
                nativeWidth: nativeW,
                nativeHeight: nativeH,
                customLogicalModes: modes
            )
            isLoading = false
            if let err {
                errorMessage = err
            } else {
                isHiDPIOn = true
                HiDPIService.shared.refreshModes(for: display)
            }
        }
    }

    private func customModeList(includeCustom: Bool) -> [HiDPIService.LogicalResolution] {
        var modes = presetModes
        if let selected = presetModes.first(where: { $0.id == selectedPresetID }) {
            modes.insert(selected, at: 0)
        }
        if includeCustom,
           let width = Int(customWidth),
           let height = Int(customHeight),
           width >= 800,
           height >= 600 {
            modes.insert(.init(width: width, height: height), at: 0)
        }
        var seen = Set<String>()
        return modes.filter { seen.insert($0.id).inserted }
    }
}
