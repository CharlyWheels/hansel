import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
            CalendarSettingsView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            DebugSettingsView()
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        .padding()
    }
}

struct GeneralSettingsView: View {
    @AppStorage("idleThresholdMinutes") private var idleThresholdMinutes: Int = 5
    @AppStorage("autoStartActivityMinutes") private var autoStartActivityMinutes: Int = 10
    @AppStorage("promptIdleMinutes") private var promptIdleMinutes: Int = 2
    @AppStorage("periodicCheckMinutes") private var periodicCheckMinutes: Int = 90
    @AppStorage("switchPromptTimeoutMinutes") private var switchPromptTimeoutMinutes: Int = 10
    @AppStorage("autoSwitchOnMeetingJoin") private var autoSwitchOnMeetingJoin: Bool = true
    @AppStorage("longAwayMinutes") private var longAwayMinutes: Int = 60
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Auto-start") {
                Stepper("Idle threshold: \(idleThresholdMinutes) min",
                        value: $idleThresholdMinutes, in: 1...30)
                Stepper("Activity auto-start after: \(autoStartActivityMinutes) min",
                        value: $autoStartActivityMinutes, in: 5...60)
                Text("When the system has been idle for longer than the threshold, the timer will not auto-start. After the configured minutes of continuous activity without a running timer, the AI drafts a new entry and the timer starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Check-ins") {
                Stepper("Remove away time after: \(promptIdleMinutes) min",
                        value: $promptIdleMinutes, in: 1...120)
                Stepper("Stop the timer if away for: \(longAwayMinutes) min",
                        value: $longAwayMinutes, in: 15...480, step: 15)
                Stepper("Periodic check-in every: \(periodicCheckMinutes) min",
                        value: $periodicCheckMinutes, in: 15...480, step: 15)
                Stepper("Unanswered switch question expires after: \(switchPromptTimeoutMinutes) min",
                        value: $switchPromptTimeoutMinutes, in: 2...60)
                Text("Time away from the Mac is not tracked. After a short absence the away time is removed and the task carries on; after a long one (or overnight) the entry is closed when you left. You can keep the time from the notice in the menu bar. Listening on a call with the screen unlocked counts as present. Long-running entries also get a periodic check-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Meetings") {
                Toggle("Switch automatically when I join a calendar meeting", isOn: $autoSwitchOnMeetingJoin)
                Text("When a meeting with other people or a video link is in progress and your microphone turns on, the running entry is closed and the meeting starts, without asking. Personal calendar blocks never trigger it. You can undo it from the menu bar for 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, new in LaunchAtLogin.setEnabled(new) }
                Text("Status: \(LaunchAtLogin.statusDescription). Move the app to /Applications first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionsSettingsView: View {
    @State private var calendar: PermissionStatus = .unknown
    @State private var accessibility: PermissionStatus = .unknown
    @State private var automation: [String: PermissionStatus] = [:]
    @State private var axSelfTest: String = ""

    private let pollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Calendar") {
                permissionRow(
                    title: "Calendar — Full Access",
                    detail: "Required to auto-start the timer for iCloud events.",
                    status: calendar,
                    action: {
                        Task {
                            _ = await Permissions.requestCalendarAccess()
                            refresh()
                        }
                    },
                    actionLabel: "Request"
                )
            }
            Section("Accessibility") {
                permissionRow(
                    title: "Accessibility",
                    detail: "Required to read focused window titles for AI classification.",
                    status: accessibility,
                    action: { Permissions.openAccessibilitySettings() },
                    actionLabel: "Open Settings"
                )
                HStack {
                    Button("Run self-test") { runAXSelfTest() }
                    Text(axSelfTest).font(.caption).foregroundStyle(.secondary)
                }
                if accessibility != .granted {
                    Text("Each rebuild changes the binary hash, so macOS invalidates the saved Accessibility grant even though the entry still appears in System Settings. Toggle the TimeTracker row OFF then ON in Privacy & Security → Accessibility, then relaunch the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Automation") {
                ForEach(BrowserTarget.all) { browser in
                    automationRow(browser)
                }
                HStack {
                    Button("Open Automation settings") { Permissions.openAutomationSettings() }
                    Spacer()
                }
                Text("macOS shows the prompt the first time TimeTracker reads a browser's active tab. Click Test to trigger it now, or wait until the activity monitor reaches that browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Refresh now", action: refresh)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(pollTimer) { _ in refresh() }
    }

    private func refresh() {
        calendar = Permissions.calendarStatus()
        accessibility = Permissions.accessibilityStatus()
        var next: [String: PermissionStatus] = [:]
        for b in BrowserTarget.all {
            next[b.bundleID] = Permissions.automationStatus(forBundleID: b.bundleID)
        }
        automation = next
    }

    private func automationRow(_ browser: BrowserTarget) -> some View {
        let status = automation[browser.bundleID] ?? .unknown
        return HStack(alignment: .center) {
            Circle().fill(color(for: status)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.displayName)
                Text(statusLabel(status)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if status == .notInstalled {
                Text("Not installed").font(.caption).foregroundStyle(.tertiary)
            } else {
                Button("Test") {
                    Permissions.promptAutomationForBrowser(browser.bundleID)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { refresh() }
                }
            }
        }
    }

    private func statusLabel(_ s: PermissionStatus) -> String {
        switch s {
        case .granted: return "Allowed"
        case .denied: return "Denied — enable in Automation settings"
        case .unknown: return "Not yet prompted"
        case .notInstalled: return "Not installed"
        }
    }

    private func runAXSelfTest() {
        // Try to read the title of the frontmost window of any app — if it returns a
        // non-nil string we actually have the permission at runtime.
        guard let app = NSWorkspace.shared.frontmostApplication else {
            axSelfTest = "no frontmost app"
            return
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        switch result {
        case .success:
            if let w = windowRef {
                let win = w as! AXUIElement
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? "<untitled>"
                axSelfTest = "✓ read: \(title.prefix(40))"
            } else {
                axSelfTest = "✓ but no focused window"
            }
        case .apiDisabled, .notImplemented:
            axSelfTest = "✗ AX API disabled — grant & relaunch"
        case .cannotComplete:
            axSelfTest = "✗ cannot complete — grant & relaunch"
        default:
            axSelfTest = "✗ error \(result.rawValue)"
        }
    }

    private func color(for status: PermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .unknown: return .orange
        case .notInstalled: return .gray
        }
    }

    private func permissionRow(title: String, detail: String, status: PermissionStatus, action: @escaping () -> Void, actionLabel: String) -> some View {
        HStack(alignment: .top) {
            Circle()
                .fill(color(for: status))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionLabel, action: action)
        }
    }
}

struct DebugSettingsView: View {
    @State private var inspector = PromptInspector.shared
    @State private var kind: PromptInspector.Kind = .boundary

    var body: some View {
        Form {
            Section("Last prompt sent to the model") {
                Picker("Prompt", selection: $kind) {
                    ForEach(PromptInspector.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if let record = inspector.records[kind] {
                    LabeledContent("Sent", value: "\(record.at.formatted(date: .abbreviated, time: .standard)) · \(record.provider)")
                    promptText(record.user)
                    if let response = record.response {
                        LabeledContent("Response") { EmptyView() }
                        promptText(response)
                    }
                    if let error = record.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button("Copy prompt and response") {
                        let text = "SYSTEM:\n\(record.system)\n\nUSER:\n\(record.user)\n\nRESPONSE:\n\(record.response ?? record.error ?? "")"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                } else {
                    Text("Nothing sent since Hansel started.")
                        .foregroundStyle(.secondary)
                }
                Text("Kept in memory only, never written to disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Logs") {
                LabeledContent("Location") {
                    Text(FileLogSink.currentLogDirectory.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.open(FileLogSink.currentLogDirectory)
                }
                Text("JSONL, rotated after 14 days. Categories: timer, activity, calendar, ai, idle, persistence, ui.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func promptText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 180)
    }
}
