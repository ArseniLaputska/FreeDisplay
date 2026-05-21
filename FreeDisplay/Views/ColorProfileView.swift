import SwiftUI

/// Expandable section for ICC color profile selection.
/// Lists all installed profiles alphabetically; highlights the active one.
struct ColorProfileView: View {
    @ObservedObject var display: DisplayInfo
    @State private var profiles: [ICCProfile] = []
    @State private var isLoading: Bool = false
    @State private var selectedPath: URL?
    @State private var applyingPath: URL? = nil
    @State private var applyError: String?
    @State private var applySuccess = false
    @State private var hiddenIncompatibleCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 14, height: 14)
                    Text("Loading profiles...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else if profiles.isEmpty {
                Text("No profiles found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                if applySuccess {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Applied")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                if let error = applyError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }

                if hiddenIncompatibleCount > 0 {
                    CapabilityNoticeRow(
                        icon: "info.circle.fill",
                        color: .secondary,
                        title: "Showing display-compatible RGB profiles",
                        detail: "\(hiddenIncompatibleCount) print/non-display profiles hidden"
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }

                // Recommended profiles (display-specific or well-known)
                let recommended = recommendedProfiles
                let rest = otherProfiles

                if !recommended.isEmpty {
                    SectionBadge(title: "Recommended")
                    ForEach(recommended) { profile in
                        ProfileRow(
                            profile: profile,
                            isSelected: selectedPath == profile.path,
                            isApplying: applyingPath == profile.path,
                            isDisabled: applyingPath != nil,
                            onTap: { applyProfile(profile) }
                        )
                        .help("Switch to this color profile")
                    }
                }

                if !rest.isEmpty {
                    SectionBadge(title: "All Profiles")
                    ForEach(rest) { profile in
                        ProfileRow(
                            profile: profile,
                            isSelected: selectedPath == profile.path,
                            isApplying: applyingPath == profile.path,
                            isDisabled: applyingPath != nil,
                            onTap: { applyProfile(profile) }
                        )
                        .help("Switch to this color profile")
                    }
                }
            }
        }
        .task { await loadProfiles() }
    }

    // MARK: - Grouping

    private var recommendedProfiles: [ICCProfile] {
        let keywords = ["sRGB", "P3", "Display", "LCD", "Apple", "Color LCD", display.name]
        return profiles.filter { p in
            p.colorSpaceType == "RGB" &&
            keywords.contains { p.name.localizedCaseInsensitiveContains($0) }
        }
    }

    private var otherProfiles: [ICCProfile] {
        let recommended = Set(recommendedProfiles.map(\.path))
        return profiles.filter { profile in
            profile.colorSpaceType == "RGB" && !recommended.contains(profile.path)
        }
    }

    // MARK: - Actions

    @MainActor
    private func loadProfiles() async {
        isLoading = true
        let displayID = display.displayID
        let svc = ColorProfileService.shared
        let loaded = await svc.enumerateProfiles()
        let currentURL = svc.currentProfileURL(for: displayID)
        profiles = loaded
        hiddenIncompatibleCount = loaded.filter { $0.colorSpaceType != "RGB" }.count
        selectedPath = currentURL
        isLoading = false
    }

    @MainActor
    private func applyProfile(_ profile: ICCProfile) {
        guard applyingPath == nil else { return }
        applyError = nil
        applySuccess = false
        Task { @MainActor in
            applyingPath = profile.path
            defer { applyingPath = nil }
            let success = ColorProfileService.shared.setProfile(profile, for: display.displayID)
            try? await Task.sleep(nanoseconds: 350_000_000)
            let verifiedURL = ColorProfileService.shared.currentProfileURL(for: display.displayID)
            if success, verifiedURL == nil || urlsMatch(verifiedURL, profile.path) {
                selectedPath = verifiedURL ?? profile.path
                applySuccess = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    applySuccess = false
                }
            } else {
                selectedPath = verifiedURL
                applyError = String(localized: "macOS did not keep this profile for this display")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    applyError = nil
                }
            }
        }
    }

    private func urlsMatch(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path ||
            lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }
}

// MARK: - Sub-views

private struct SectionBadge: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.blue)
            .cornerRadius(4)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

private struct CapabilityNoticeRow: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct ProfileRow: View {
    let profile: ICCProfile
    let isSelected: Bool
    let isApplying: Bool
    let isDisabled: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isApplying {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.caption)
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .frame(width: 14)
                }
                Text(profile.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if profile.colorSpaceType != "RGB" {
                    Text(profile.colorSpaceType)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled && !isApplying)
        .opacity(isDisabled && !isApplying ? 0.45 : 1.0)
        .background(isSelected ? Color.blue.opacity(0.05) : Color.primary.opacity(isHovered ? 0.06 : 0))
        .onHover { isHovered = $0 }
    }
}
