import Foundation

/// Knowledge about video-call apps and URLs: which ones exist, how to tell an active
/// call from an app merely being open, and which apps hold the microphone without a
/// meeting being in progress.
///
/// Window titles vary enormously in usefulness. Zoom names its call window precisely;
/// the new Teams is a WebView whose title is almost always just "Microsoft Teams", and
/// Slack huddles and Discord voice channels do not change the title at all. Those apps
/// are marked `windowTitleIsReliable = false` and rely on the microphone alone.
enum ConferenceCatalog {

    struct App: Equatable, Sendable {
        let bundleId: String
        let displayName: String
        /// Regexes (case-insensitive) that indicate a call is actually in progress.
        let inCallTitlePatterns: [String]
        /// Regexes that indicate the app is open but idle — these veto the title signal.
        let idleTitlePatterns: [String]
        /// False when the window title carries no usable information at all.
        let windowTitleIsReliable: Bool
        /// True when merely running implies a call (single-purpose meeting apps).
        let runningImpliesCall: Bool

        init(
            bundleId: String,
            displayName: String,
            inCallTitlePatterns: [String] = [],
            idleTitlePatterns: [String] = [],
            windowTitleIsReliable: Bool = true,
            runningImpliesCall: Bool = false
        ) {
            self.bundleId = bundleId
            self.displayName = displayName
            self.inCallTitlePatterns = inCallTitlePatterns
            self.idleTitlePatterns = idleTitlePatterns
            self.windowTitleIsReliable = windowTitleIsReliable
            self.runningImpliesCall = runningImpliesCall
        }
    }

    static let apps: [App] = [
        App(
            bundleId: "us.zoom.xos",
            displayName: "Zoom",
            // The most informative title of any conferencing app.
            inCallTitlePatterns: [#"^zoom meeting"#, #"^zoom webinar"#, #"zoom meeting id"#],
            idleTitlePatterns: [#"^zoom$"#, #"^zoom workplace$"#, #"^settings$"#]
        ),
        App(
            bundleId: "com.microsoft.teams",
            displayName: "Microsoft Teams (classic)",
            inCallTitlePatterns: [#"meeting (in|with)"#, #"^meeting "#, #"\| microsoft teams call"#]
        ),
        App(
            bundleId: "com.microsoft.teams2",
            displayName: "Microsoft Teams",
            // WebView2: the title is almost always just the app name. Microphone only.
            windowTitleIsReliable: false
        ),
        App(
            bundleId: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            // Huddles do not alter the window title. Microphone only.
            windowTitleIsReliable: false
        ),
        App(
            bundleId: "com.hnc.Discord",
            displayName: "Discord",
            // Joining a voice channel does not alter the title. Microphone only.
            windowTitleIsReliable: false
        ),
        App(
            bundleId: "Cisco-Systems.Spark",
            displayName: "Webex",
            inCallTitlePatterns: [#"meeting"#, #"webex meeting"#]
        ),
        App(
            bundleId: "com.webex.meetingmanager",
            displayName: "Webex Meetings",
            runningImpliesCall: true
        ),
        App(bundleId: "com.apple.FaceTime", displayName: "FaceTime", runningImpliesCall: true),
        App(bundleId: "com.amazon.Amazon-Chime", displayName: "Chime", runningImpliesCall: true),
        App(bundleId: "com.logmein.GoToMeeting", displayName: "GoToMeeting", runningImpliesCall: true),
        App(bundleId: "com.bluejeansnet.Blue", displayName: "BlueJeans", runningImpliesCall: true),
        App(bundleId: "com.ringcentral.meetings", displayName: "RingCentral", runningImpliesCall: true),
    ]

    /// Apps that legitimately hold the microphone with no meeting in progress. Their
    /// presence subtracts confidence rather than adding it.
    static let vetoBundleIds: Set<String> = [
        "com.apple.VoiceMemos",
        "com.apple.QuickTimePlayerX",
        "com.obsproject.obs-studio",
        "com.loom.desktop",
        "com.apple.Music",
        "com.apple.GarageBand10",
        "com.apple.logic10",
        "com.apple.Siri",
        "com.apple.screencaptureui",
        "com.rogueamoeba.audiohijack",
        "com.descript.beachcube",
    ]

    /// Conference room URLs. Deliberately strict: `meet.google.com` alone is the
    /// landing page, not a call, so a room code is required.
    static let urlPatterns: [String] = [
        #"meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#,
        #"[a-z0-9.-]*zoom\.us/(j|wc|s|my)/"#,
        #"teams\.microsoft\.com/.*(meetup-join|meetingjoin)"#,
        #"teams\.live\.com/meet/"#,
        #"[a-z0-9.-]*webex\.com/(meet|join|wbxmjs)/"#,
        #"whereby\.com/."#,
        #"meet\.jit\.si/."#,
        #"app\.gather\.town/"#,
        #"app\.slack\.com/huddle/"#,
        #"chime\.aws/"#,
    ]

    // MARK: - Lookup

    static func app(forBundleId bundleId: String) -> App? {
        apps.first { $0.bundleId == bundleId }
            // Google Meet installed as a Chrome PWA gets a hash-suffixed bundle id, so
            // match the stable prefix rather than the exact string.
            ?? (bundleId.hasPrefix("com.google.Chrome.app.")
                ? App(bundleId: bundleId, displayName: "Google Meet (app)",
                      inCallTitlePatterns: [#"meet"#])
                : nil)
    }

    static func isConferenceApp(_ bundleId: String) -> Bool { app(forBundleId: bundleId) != nil }

    static func isVetoApp(_ bundleId: String) -> Bool { vetoBundleIds.contains(bundleId) }

    static func isConferenceURL(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return false }
        let target = url.lowercased()
        return urlPatterns.contains { matches(pattern: $0, in: target) }
    }

    /// Whether this app's window title indicates a call actually in progress.
    /// Returns nil when the title carries no usable signal for this app.
    static func titleIndicatesCall(bundleId: String, windowTitle: String?) -> Bool? {
        guard let app = app(forBundleId: bundleId), app.windowTitleIsReliable else { return nil }
        guard let title = windowTitle?.lowercased(), !title.isEmpty else { return nil }
        if app.idleTitlePatterns.contains(where: { matches(pattern: $0, in: title) }) {
            return false
        }
        guard !app.inCallTitlePatterns.isEmpty else { return nil }
        return app.inCallTitlePatterns.contains { matches(pattern: $0, in: title) }
    }

    private static func matches(pattern: String, in target: String) -> Bool {
        target.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
