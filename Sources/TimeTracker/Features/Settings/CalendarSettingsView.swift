import SwiftUI
import EventKit

/// Chooses which calendars may drive tracking, and supplies the addresses needed to
/// recognise the user among an event's attendees.
struct CalendarSettingsView: View {
    @AppStorage("calendar.myEmails") private var myEmails: String = ""
    @State private var calendars: [(id: String, title: String)] = []
    @State private var allowed: Set<String> = []
    @State private var loaded = false

    private let provider = MeetingProvider()

    var body: some View {
        Form {
            Section("Calendars that may start tracking") {
                if calendars.isEmpty {
                    Text("No calendars found, or access has not been granted yet. Check the Permissions tab.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(calendars, id: \.id) { calendar in
                        Toggle(calendar.title, isOn: binding(for: calendar.id))
                    }
                }
                Text("With nothing selected, every calendar is used — including birthdays and subscribed calendars. Declined invitations, all-day events and blocks that show as 'free' are always ignored regardless of this setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Your email addresses") {
                TextField("you@example.com, you@work.com", text: $myEmails)
                    .textFieldStyle(.roundedBorder)
                Text("Used to find your own response to an invitation. macOS usually reports this itself, but on some Google accounts it does not — without a match here, an event's attendance is treated as unknown rather than declined.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            guard !loaded else { return }
            loaded = true
            calendars = provider.availableCalendars()
            allowed = provider.allowedCalendarIds ?? []
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { allowed.contains(id) },
            set: { isOn in
                if isOn { allowed.insert(id) } else { allowed.remove(id) }
                provider.allowedCalendarIds = allowed.isEmpty ? nil : allowed
            }
        )
    }
}
