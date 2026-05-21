import SwiftUI

// MARK: - Shared Icon Helper

/// A colored rounded-square SF Symbol icon, consistent with macOS Settings style.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

// MARK: - ExpandableRow

struct ExpandableRow: View {
    let icon: String
    var iconColor: Color = .blue
    let label: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: icon, color: iconColor)
            Text(LocalizedStringKey(label)).font(.body)
            Spacer()
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(isExpanded ? "\(label), expanded" : "\(label), collapsed")
        .accessibilityHint("Click to expand or collapse this section")
        .accessibilityAddTraits(.isButton)
        .help("Click to expand or collapse this section")
    }
}

struct MenuBarView: View {
    @Environment(DisplayManager.self) var displayManager
    
    @State private var updateService = UpdateService.shared
    @State private var settings = SettingsService.shared
    @State private var virtualDisplayService = VirtualDisplayService.shared
    @State private var advancedDisplayService = AdvancedDisplayService.shared
    
    @State private var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    @State private var showArrangement: Bool = false
    @State private var showVirtualDisplays: Bool = false
    @State private var showSoftDisconnects: Bool = false
    @State private var showAutoBrightness: Bool = false
    @State private var showSettings: Bool = false
    @State private var quitHovered: Bool = false

    private var visibleDisplays: [DisplayInfo] {
        displayManager.displays.filter { !virtualDisplayService.isVirtualDisplay($0.displayID) }
    }

    private var displayIDs: [CGDirectDisplayID] {
        displayManager.displays.map(\.displayID)
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Display list
                ForEach(visibleDisplays) { display in
                    VStack(spacing: 0) {
                        DisplayRowView(
                            display: display,
                            isExpanded: expandedDisplayIDs.contains(display.displayID),
                            onToggleExpand: {
                                if expandedDisplayIDs.contains(display.displayID) {
                                    expandedDisplayIDs.remove(display.displayID)
                                } else {
                                    expandedDisplayIDs.insert(display.displayID)
                                }
                            }
                        )

                        if expandedDisplayIDs.contains(display.displayID) {
                            DisplayDetailView(display: display)
                        }
                    }
                }

                // Preset list (Phase 19)
                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                PresetListView()

                // Display arrangement section (Phase 4)
                if visibleDisplays.count > 1 {
                    Divider()
                        .opacity(0.3)
                        .padding(.vertical, 2)

                    ExpandableRow(
                        icon: "rectangle.3.offgrid",
                        iconColor: .blue,
                        label: "Arrange Displays",
                        isExpanded: $showArrangement
                    )

                    if showArrangement {
                        ArrangementView()
                            .environment(displayManager)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Combined brightness control (Phase 2)
                if settings.showCombinedBrightness {
                    CombinedBrightnessView(displays: displayManager.displays)
                    Divider()
                        .opacity(0.3)
                        .padding(.vertical, 2)
                }

                // Tools header
                Text("Tools")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                // Virtual display tool entry (Phase 10)
                ExpandableRow(
                    icon: "display.2",
                    iconColor: .blue,
                    label: "Virtual Displays",
                    isExpanded: $showVirtualDisplays
                )

                if showVirtualDisplays {
                    VirtualDisplayView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                ExpandableRow(
                    icon: "display.trianglebadge.exclamationmark",
                    iconColor: .red,
                    label: "Soft Disconnects",
                    subtitle: advancedDisplayService.softDisconnectedDisplays.isEmpty
                        ? nil
                        : "\(advancedDisplayService.softDisconnectedDisplays.count)",
                    isExpanded: $showSoftDisconnects
                )

                if showSoftDisconnects {
                    SoftDisconnectedDisplaysView()
                        .environment(displayManager)
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Auto brightness entry (Phase 11)
                ExpandableRow(
                    icon: "sun.and.horizon.fill",
                    iconColor: .orange,
                    label: "Auto Brightness",
                    isExpanded: $showAutoBrightness
                )

                if showAutoBrightness {
                    AutoBrightnessView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Settings section (Phase 12)
                ExpandableRow(
                    icon: "gearshape.fill",
                    iconColor: .gray,
                    label: "Settings",
                    isExpanded: $showSettings
                )

                if showSettings {
                    SettingsView()
                        .padding(.leading, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()
                    .opacity(0.3)
                    .padding(.vertical, 2)

                // Update prompt (Phase 12)
                if updateService.hasUpdate, let ver = updateService.latestVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text("Version \(ver) available")
                            .font(.caption)
                            .foregroundColor(.green)
                        Spacer()
                        Button("View") { updateService.openReleasePage() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .help("Download and install the latest version")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(6)
                    .padding(.horizontal, 8)
                }

            }
        }

        Divider().opacity(0.3)

        // Version and quit controls pinned at the bottom.
        HStack {
            Text("FreeDisplay v\(updateService.currentVersion)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .accessibilityHidden(true)
                    Text("Quit")
                }
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(quitHovered ? Color.primary.opacity(0.06) : .clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(quitHovered ? .red : .secondary)
            .onHover { quitHovered = $0 }
            .help("Quit FreeDisplay")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        } // end VStack
        .frame(width: 340, height: 620)
        .padding(.vertical, 8)
        .onChange(of: displayIDs) { _, newIDs in
            let validIDs = Set(newIDs)
            expandedDisplayIDs = expandedDisplayIDs.intersection(validIDs)
        }
        .task {
            if settings.checkUpdatesOnLaunch {
                await updateService.checkForUpdates()
            }
        }
    }
}

// MARK: - SoftDisconnectedDisplaysView

private struct SoftDisconnectedDisplaysView: View {
    @State private var service = AdvancedDisplayService.shared
    @Environment(DisplayManager.self) var displayManager
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }

            if service.softDisconnectedDisplays.isEmpty {
                Text("No soft-disconnected displays")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                ForEach(service.softDisconnectedDisplays) { record in
                    HStack(spacing: 8) {
                        Image(systemName: "display")
                            .foregroundColor(.red)
                            .frame(width: 18)
                            .font(.caption)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.name)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(record.vendorID) / \(record.productID)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            let ok = service.reconnectSoftDisconnectedDisplay(record)
                            statusMessage = ok ? "Reconnect requested" : "Reconnect failed"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                displayManager.refreshDisplays()
                            }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Reconnect display")

                        Button {
                            service.forgetSoftDisconnectedDisplay(record.displayID)
                            statusMessage = "Removed"
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .help("Forget record")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @State private var settings = SettingsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Launch at login
            Toggle(isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    if newValue {
                        LaunchService.shared.enable()
                    } else {
                        LaunchService.shared.disable()
                    }
                    settings.launchAtLogin = newValue
                }
            )) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "power", color: .green)
                        .accessibilityHidden(true)
                    Text("Launch at Login")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Start FreeDisplay automatically at login")

            // First launch prompt: recommend launch at login.
            if !settings.launchAtLoginPrompted {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("Launch at login is recommended")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Got it") {
                        settings.launchAtLoginPrompted = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .onAppear {
                    // Mark as prompted so it only shows once
                    // User dismisses manually via the "Got it" button.
                }
            }

            // Show combined brightness
            Toggle(isOn: $settings.showCombinedBrightness) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "sun.min.fill", color: .yellow)
                        .accessibilityHidden(true)
                    Text("Show Combined Brightness")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Show one brightness slider for all displays in the menu bar")

            // Check for updates at launch
            Toggle(isOn: $settings.checkUpdatesOnLaunch) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "arrow.clockwise.circle", color: .blue)
                        .accessibilityHidden(true)
                    Text("Check for Updates at Launch")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Automatically check for a new version on launch")
        }
        .padding(.vertical, 6)
    }
}

// MARK: - DisplayRowView

struct DisplayRowView: View {
    @Bindable var display: DisplayInfo
    @Environment(DisplayManager.self) var displayManager
    @State private var isHovered: Bool = false

    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                    .rotationEffect(Angle(degrees: isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    .accessibilityHidden(true)

                MenuItemIcon(systemName: display.isBuiltin ? "laptopcomputer" : "display", color: .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let mode = display.currentDisplayMode {
                        Text(mode.resolutionString)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                if display.isMain {
                    Text("Main")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(3)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }
            .help("Expand display control panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open in System Settings", systemImage: "display")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.name, forType: .string)
            } label: {
                Label("Copy Display Name", systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel("Display: \(display.name)\(display.isMain ? ", main display" : "")\(isExpanded ? ", expanded" : ", collapsed")")
        .accessibilityHint("Click to expand the control panel")
        .accessibilityAddTraits(.isButton)
    }
}
