import SwiftUI

/// Says so when Accessibility is not granted.
///
/// Without it every app except the browsers reaches the model as a bare name —
/// "Terminal", "Outlook", "Teams" — and it went unnoticed for weeks, because an ad-hoc
/// rebuild silently invalidates the grant while System Settings still shows it on.
struct PermissionBanner: View {
    @State private var granted = Permissions.accessibilityStatus() == .granted
    private let recheck = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if !granted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Accessibility permission missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    Text("Hansel can't read window titles, so it guesses your task from app names only. In Accessibility, turn Hansel off and on again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings") {
                        Permissions.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
        .onReceive(recheck) { _ in
            granted = Permissions.accessibilityStatus() == .granted
        }
    }
}
