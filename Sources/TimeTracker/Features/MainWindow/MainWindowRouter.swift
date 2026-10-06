import Foundation
import Observation

/// Which page the main window shows, settable from outside it: the menu bar's
/// "review proposals" and a proposal's meeting link both land on a specific page.
@Observable
@MainActor
final class MainWindowRouter {
    var selection: SidebarItem = .dashboard
    /// The meeting to open when the Meetings page appears.
    var meetingID: UUID?

    func openMeeting(_ id: UUID) {
        meetingID = id
        selection = .meetings
    }
}
