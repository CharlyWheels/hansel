import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            TrackingSettingsView()
                .tabItem { Label("Tracking", systemImage: "timer") }
            CalendarSettingsView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            MeetingsSettingsView()
                .tabItem { Label("Meetings", systemImage: "waveform") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            IntegrationsSettingsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
            DebugSettingsView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .padding()
    }
}

/// A stepper with its label on the left and the value on the right, like System Settings.
private struct ValueStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var unit: String = "min"

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            LabeledContent(title) {
                Text("\(value) \(unit)").monospacedDigit()
            }
        }
    }
}

/// How Hansel starts, keeps and questions the timer.
struct TrackingSettingsView: View {
    @AppStorage("idleThresholdMinutes") private var idleThresholdMinutes: Int = 5
    @AppStorage("autoStartActivityMinutes") private var autoStartActivityMinutes: Int = 10
    @AppStorage("promptIdleMinutes") private var promptIdleMinutes: Int = 2
    @AppStorage("periodicCheckMinutes") private var periodicCheckMinutes: Int = 90
    @AppStorage("switchPromptTimeoutMinutes") private var switchPromptTimeoutMinutes: Int = 10
    @AppStorage("autoSwitchOnMeetingJoin") private var autoSwitchOnMeetingJoin: Bool = true
    @AppStorage("autoStopOnMeetingEnd") private var autoStopOnMeetingEnd: Bool = true
    @AppStorage("longAwayMinutes") private var longAwayMinutes: Int = 60
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                ValueStepper(title: "Start after continuous activity of", value: $autoStartActivityMinutes, range: 5...60)
                ValueStepper(title: "Consider me away after no input for", value: $idleThresholdMinutes, range: 1...30)
            } header: {
                Text("Starting automatically")
            } footer: {
                Text("With nothing running, Hansel drafts an entry with AI after this much activity and starts it. Calendar meetings you attend start on their own too.")
            }

            Section {
                Toggle("Switch to a calendar meeting when I join it", isOn: $autoSwitchOnMeetingJoin)
                Toggle("Stop the meeting's entry when the call ends", isOn: $autoStopOnMeetingEnd)
                    .disabled(!autoSwitchOnMeetingJoin)
            } header: {
                Text("Meetings")
            } footer: {
                Text("When you are in a call during a calendar meeting — microphone on, with Teams, Zoom or another call app, or the camera — the entry takes the meeting's name from your calendar, starting when the call did, and back-to-back meetings each get their own entry. Hanging up closes the entry at that moment. Both can be undone from the menu bar for 15 minutes.")
            }

            Section {
                ValueStepper(title: "Remove away time longer than", value: $promptIdleMinutes, range: 1...120)
                ValueStepper(title: "Stop the timer after being away", value: $longAwayMinutes, range: 15...480, step: 15)
            } header: {
                Text("When you step away")
            } footer: {
                Text("Time away from the Mac is not tracked. After locking the screen or sleep, a short absence is cut out and the task carries on; a long one (or a night) closes the entry when you left. Keep the time from the notice if it was work. With the screen unlocked, nothing is cut: Hansel asks whether you were away. A call with the screen unlocked counts as present.")
            }

            Section {
                ValueStepper(title: "Check in on long entries every", value: $periodicCheckMinutes, range: 15...480, step: 15)
                ValueStepper(title: "Unanswered switch questions expire after", value: $switchPromptTimeoutMinutes, range: 2...60)
            } header: {
                Text("Questions")
            } footer: {
                Text("The check-in catches a timer left running by mistake.")
            }

            Section {
                Toggle("Open Hansel at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, new in LaunchAtLogin.setEnabled(new) }
            } header: {
                Text("Startup")
            } footer: {
                Text("Status: \(LaunchAtLogin.statusDescription). The app must be in /Applications.")
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
