import SwiftUI
import SwiftData
import EventKit

/// Toggl-inspired vertical day timeline. Time flows top to bottom, hour grid on the
/// left, a narrow apps lane, then entry blocks. A red line marks the current time when
/// viewing today. Entries are clickable to edit and show rich tooltips on hover.
struct DayTimelineView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var editingEntry: TimeEntry?
    @State private var popoverSessionID: Date?
    @State private var calendarPlaceholders: [CalendarPlaceholder] = []
    @State private var dragStartY: CGFloat?
    @State private var dragCurrentY: CGFloat?

    @Query(
        filter: #Predicate<TimeEntry> { $0.endAt != nil },
        sort: [SortDescriptor(\TimeEntry.startAt)]
    ) private var allEntries: [TimeEntry]

    @Query(
        filter: #Predicate<TimeEntry> { $0.endAt == nil }
    ) private var runningEntries: [TimeEntry]

    @Query(sort: [SortDescriptor(\ActivitySample.timestamp)])
    private var allSamples: [ActivitySample]

    @Query(sort: [SortDescriptor(\IdleInterval.start)])
    private var allIdles: [IdleInterval]

    // Visual tuning
    private let hourHeight: CGFloat = 64
    private let timeColumnWidth: CGFloat = 56
    private let appsColumnWidth: CGFloat = 22
    private let calendarColumnWidth: CGFloat = 220
    private let columnGap: CGFloat = 8
    private let topInset: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    canvas.padding(.vertical, 8)
                }
                .onAppear { scrollToFocus(proxy) }
                .onChange(of: selectedDate) { _, _ in scrollToFocus(proxy) }
            }
        }
        .navigationTitle("Timeline")
        .task(id: selectedDate) { loadCalendarPlaceholders() }
        .sheet(item: $editingEntry) { entry in
            EntryEditorView(entry: entry)
                .frame(minWidth: 480, minHeight: 360)
        }
    }

    // MARK: - Calendar placeholders

    private func loadCalendarPlaceholders() {
        var status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            Task {
                _ = await Permissions.requestCalendarAccess()
                loadCalendarPlaceholders()
            }
            return
        }
        guard status == .fullAccess else {
            AppLogger.calendar.info("placeholder load skipped — auth=\(String(describing: status), privacy: .public)")
            AppLogger.log("calendar", level: .info, "placeholder_skip auth=\(status.rawValue)")
            calendarPlaceholders = []
            return
        }
        _ = status
        let store = EKEventStore()
        // Use every calendar the user has. Subscribed / Birthday calendars are fine —
        // they just rarely have timed events, so they won't clutter the view.
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else {
            AppLogger.calendar.info("no calendars found")
            calendarPlaceholders = []
            return
        }
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: calendars)
        let all = store.events(matching: predicate)
        let timed = all.filter { !$0.isAllDay && $0.startDate != nil && $0.endDate != nil }
        AppLogger.calendar.info(
            "placeholders loaded calendars=\(calendars.count, privacy: .public) events=\(all.count, privacy: .public) timed=\(timed.count, privacy: .public) day=\(dayStart.formatted(date: .numeric, time: .omitted), privacy: .public)"
        )
        AppLogger.log("calendar", level: .info, "placeholders calendars=\(calendars.count) events=\(all.count) timed=\(timed.count)")
        calendarPlaceholders = timed.map { event in
            CalendarPlaceholder(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Untitled",
                start: event.startDate,
                end: event.endDate,
                calendarTitle: event.calendar?.title ?? "",
                tintHex: hexColor(from: event.calendar?.cgColor)
            )
        }
    }

    private func hexColor(from cg: CGColor?) -> String? {
        guard let cg, let comps = cg.components, cg.numberOfComponents >= 3 else { return nil }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(Calendar.current.isDateInToday(selectedDate))
            Text(selectedDate.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.headline)
            Spacer()
            Button("Today") {
                selectedDate = Calendar.current.startOfDay(for: Date())
            }
            .disabled(Calendar.current.isDateInToday(selectedDate))
            DatePicker("", selection: $selectedDate, displayedComponents: [.date])
                .labelsHidden()
            Button {
                loadCalendarPlaceholders()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload calendar events")
            .buttonStyle(.borderless)
        }
        .padding()
    }

    private func shiftDay(_ delta: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate) ?? selectedDate
    }

    // MARK: - Data

    private var dayStart: Date { Calendar.current.startOfDay(for: selectedDate) }
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

    private var entries: [TimeEntry] {
        allEntries.filter { entry in
            guard let end = entry.endAt else { return false }
            return entry.startAt < dayEnd && end > dayStart
        }
    }

    private var runningEntryOnDay: TimeEntry? {
        runningEntries.first { $0.startAt < dayEnd && Date() > dayStart }
    }

    private var samples: [ActivitySample] {
        let dayIdles = allIdles.filter { idle in
            let end = idle.end ?? Date()
            return idle.start < dayEnd && end > dayStart
        }
        return allSamples.filter { sample in
            guard sample.timestamp >= dayStart && sample.timestamp < dayEnd else { return false }
            // Exclude samples that fall inside any idle interval — Carlos wants
            // "open and in use" only, not background apps during idle time.
            return !dayIdles.contains { idle in
                let end = idle.end ?? Date()
                return sample.timestamp >= idle.start && sample.timestamp <= end
            }
        }
    }

    private var isToday: Bool {
        Calendar.current.isDate(selectedDate, inSameDayAs: Date())
    }

    // MARK: - Canvas

    private var canvas: some View {
        let totalHeight = hourHeight * 24 + topInset * 2
        return ZStack(alignment: .topLeading) {
            gridLines
            HStack(alignment: .top, spacing: columnGap) {
                timeColumn.frame(width: timeColumnWidth)
                appsColumn.frame(width: appsColumnWidth)
                entriesColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
                calendarColumn.frame(width: calendarColumnWidth)
            }
            .padding(.horizontal, 12)
            if isToday {
                nowLine
            }
        }
        .frame(height: totalHeight, alignment: .topLeading)
    }

    private var gridLines: some View {
        ForEach(0...24, id: \.self) { h in
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1)
                .offset(y: CGFloat(h) * hourHeight + topInset)
                .id("hour-\(h)")
        }
    }

    private var timeColumn: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(0..<24, id: \.self) { h in
                Text(String(format: "%02d:00", h))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(y: CGFloat(h) * hourHeight + topInset - 6)
            }
            Color.clear.frame(height: hourHeight * 24 + topInset * 2)
        }
    }

    private var appsColumn: some View {
        ZStack(alignment: .topLeading) {
            ForEach(appSessions) { session in
                SessionBlock(
                    session: session,
                    width: appsColumnWidth,
                    height: sessionHeight(for: session),
                    color: colorFor(bundleId: session.dominantBundleId),
                    isPopoverOpen: popoverSessionID == session.id,
                    togglePopover: {
                        popoverSessionID = (popoverSessionID == session.id) ? nil : session.id
                    }
                )
                .offset(y: yOffset(for: session.start) + topInset)
            }
            Color.clear.frame(width: appsColumnWidth, height: hourHeight * 24 + topInset * 2)
        }
    }

    private func sessionHeight(for session: AppSession) -> CGFloat {
        let rawHeight = CGFloat(session.end.timeIntervalSince(session.start) / 3600) * hourHeight
        return max(4, rawHeight)
    }

    // MARK: - Bucketing & merging

    private static let bucketSeconds: TimeInterval = 5 * 60

    /// All 5-minute buckets for the day that contain at least one in-use sample.
    private var appBuckets: [AppBucket] {
        let buckets = Dictionary(grouping: samples) { sample in
            bucketStart(for: sample.timestamp)
        }
        return buckets
            .map { (start, bucketSamples) in AppBucket(start: start, samples: bucketSamples) }
            .sorted { $0.start < $1.start }
    }

    /// Contiguous runs of non-empty 5-minute buckets merged into a single visual block.
    /// Two buckets are contiguous when the next bucket starts exactly where the previous ended.
    private var appSessions: [AppSession] {
        var sessions: [AppSession] = []
        var current: [AppBucket] = []
        for bucket in appBuckets {
            if let last = current.last, abs(bucket.start.timeIntervalSince(last.end)) < 1 {
                current.append(bucket)
            } else {
                if !current.isEmpty { sessions.append(AppSession(buckets: current)) }
                current = [bucket]
            }
        }
        if !current.isEmpty { sessions.append(AppSession(buckets: current)) }
        return sessions
    }

    private func bucketStart(for date: Date) -> Date {
        let elapsed = date.timeIntervalSince(dayStart)
        let bucketIndex = floor(elapsed / Self.bucketSeconds)
        return dayStart.addingTimeInterval(bucketIndex * Self.bucketSeconds)
    }


    private var calendarColumn: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: calendarColumnWidth, height: hourHeight * 24 + topInset * 2)
            ForEach(calendarPlaceholders) { placeholder in
                CalendarPlaceholderView(placeholder: placeholder, hourHeight: hourHeight)
                    .offset(y: yOffset(for: max(placeholder.start, dayStart)) + topInset)
            }
        }
    }

    private var entriesColumn: some View {
        ZStack(alignment: .topLeading) {
            // Invisible drag catcher spanning the full column — captures drag-to-create
            // gestures. Entries rendered on top still receive taps.
            Color.clear
                .frame(height: hourHeight * 24 + topInset * 2)
                .contentShape(Rectangle())
                .gesture(createDragGesture())

            // Real tracked entries on top.
            ForEach(entries) { entry in
                EntryBlockView(entry: entry, hourHeight: hourHeight)
                    .offset(y: yOffset(for: max(entry.startAt, dayStart)) + topInset)
                    .onTapGesture { editingEntry = entry }
                    .contextMenu {
                        Button("Edit") { editingEntry = entry }
                        Divider()
                        Button("Delete", role: .destructive) {
                            modelContext.delete(entry)
                            try? modelContext.save()
                        }
                    }
            }
            // Live-updating running entry (endAt == nil). Ticks every 30 s so the block
            // grows visibly.
            if let running = runningEntryOnDay {
                TimelineView(.periodic(from: Date.distantPast, by: 30)) { ctx in
                    EntryBlockView(entry: running, hourHeight: hourHeight, liveEnd: ctx.date)
                        .offset(y: yOffset(for: max(running.startAt, dayStart)) + topInset)
                        .onTapGesture { editingEntry = running }
                        .contextMenu {
                            Button("Edit") { editingEntry = running }
                        }
                }
            }
            // Drag preview (ghost rectangle while dragging).
            currentDragGhost
        }
    }

    // MARK: - Drag-to-create

    private func createDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                dragStartY = value.startLocation.y
                dragCurrentY = value.location.y
            }
            .onEnded { _ in
                defer {
                    dragStartY = nil
                    dragCurrentY = nil
                }
                guard let s = dragStartY, let c = dragCurrentY else { return }
                let startTime = timeFor(y: min(s, c) - topInset)
                let endTime = timeFor(y: max(s, c) - topInset)
                guard endTime.timeIntervalSince(startTime) >= 60 else { return }  // ignore flicks < 1 min
                let snapped = snap(start: startTime, end: endTime)
                let entry = TimeEntry(
                    title: "",
                    startAt: snapped.start,
                    endAt: snapped.end,
                    isConfirmed: true,
                    source: .manual
                )
                modelContext.insert(entry)
                try? modelContext.save()
                editingEntry = entry
            }
    }

    @ViewBuilder
    private var currentDragGhost: some View {
        if let s = dragStartY, let c = dragCurrentY {
            let top = min(s, c)
            let bottom = max(s, c)
            let height = max(4, bottom - top)
            let startTime = timeFor(y: top - topInset)
            let endTime = timeFor(y: bottom - topInset)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.25))
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New entry")
                        .font(.caption.weight(.medium))
                    Text("\(hhmm(startTime)) – \(hhmm(endTime)) · \(DurationFormat.hoursMinutes(endTime.timeIntervalSince(startTime)))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: height)
            .offset(y: top)
            .allowsHitTesting(false)
        }
    }

    /// Inverse of `yOffset(for:)` — converts a Y offset inside the canvas back to a Date.
    private func timeFor(y: CGFloat) -> Date {
        let clamped = max(0, min(y, hourHeight * 24))
        let seconds = Double(clamped / hourHeight) * 3600
        return dayStart.addingTimeInterval(seconds)
    }

    /// Snap both endpoints to the nearest 5-minute mark so quick drags produce clean times.
    private func snap(start: Date, end: Date) -> (start: Date, end: Date) {
        let step: TimeInterval = 5 * 60
        let s = round(start.timeIntervalSince(dayStart) / step) * step
        let e = round(end.timeIntervalSince(dayStart) / step) * step
        let snappedStart = dayStart.addingTimeInterval(s)
        let snappedEnd = dayStart.addingTimeInterval(max(s + step, e))
        return (snappedStart, snappedEnd)
    }

    private func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private var nowLine: some View {
        TimelineView(.periodic(from: Date.distantPast, by: 30)) { ctx in
            let y = yOffset(for: ctx.date) + topInset
            HStack(spacing: 0) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Rectangle().fill(Color.red).frame(height: 1)
            }
            .offset(x: timeColumnWidth + columnGap + 6, y: y - 4)
            .padding(.trailing, 12)
        }
    }

    private func yOffset(for date: Date) -> CGFloat {
        let seconds = max(0, date.timeIntervalSince(dayStart))
        return CGFloat(min(seconds, 86_400) / 3600) * hourHeight
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        let hour: Int
        if isToday {
            let h = Calendar.current.component(.hour, from: Date())
            hour = max(0, min(23, h - 2))
        } else if let firstEntry = entries.first {
            hour = max(0, Calendar.current.component(.hour, from: firstEntry.startAt) - 1)
        } else {
            hour = 7
        }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo("hour-\(hour)", anchor: .top) }
        }
    }

    // MARK: - Helpers

    private func colorFor(bundleId: String) -> Color {
        let hue = Double(abs(bundleId.hashValue) % 360) / 360
        return Color(hue: hue, saturation: 0.5, brightness: 0.72)
    }

}

// MARK: - Bucket types

/// Per-bundleId aggregation inside a session. Only counts the app while it was
/// the frontmost (non-idle) app — i.e. "open and in use", not just running in the background.
private struct AppUsage {
    let bundleId: String
    let appName: String
    let seconds: TimeInterval
    let percentage: Double
}

private struct AppBucket {
    let start: Date
    let samples: [ActivitySample]
    var end: Date { start.addingTimeInterval(5 * 60) }
}

/// A contiguous run of 5-minute buckets. Rendered as a single block in the apps lane,
/// with a merged tooltip showing aggregated apps, timeframe, total, and active %.
private struct AppSession: Identifiable {
    let buckets: [AppBucket]
    var id: Date { start }
    var start: Date { buckets.first!.start }
    var end: Date { buckets.last!.end }
    var allSamples: [ActivitySample] { buckets.flatMap { $0.samples } }

    /// Each sample represents one 30-second poll.
    var totalSeconds: TimeInterval { TimeInterval(allSamples.count) * 30 }
    var timeframeSeconds: TimeInterval { end.timeIntervalSince(start) }
    var activePercent: Double {
        timeframeSeconds > 0 ? min(1.0, totalSeconds / timeframeSeconds) : 0
    }

    var apps: [AppUsage] {
        let samples = allSamples
        let total = TimeInterval(samples.count) * 30
        let groups = Dictionary(grouping: samples) { $0.bundleId }
        return groups.map { (bundleId, group) -> AppUsage in
            let secs = TimeInterval(group.count) * 30
            return AppUsage(
                bundleId: bundleId,
                appName: group.first?.appName ?? bundleId,
                seconds: secs,
                percentage: total > 0 ? secs / total : 0
            )
        }
        .sorted { $0.seconds > $1.seconds }
    }

    var dominantBundleId: String {
        apps.first?.bundleId ?? allSamples.first?.bundleId ?? ""
    }
}

// MARK: - Entry block

private struct EntryBlockView: View {
    let entry: TimeEntry
    let hourHeight: CGFloat
    /// When the entry is running (endAt == nil) the parent passes the current tick here
    /// so the block height grows live. nil for finished entries.
    var liveEnd: Date? = nil

    var body: some View {
        let end = liveEnd ?? entry.endAt ?? entry.startAt
        let duration = max(0, end.timeIntervalSince(entry.startAt))
        let isRunning = entry.endAt == nil
        let height = max(22, CGFloat(duration / 3600) * hourHeight)
        let theme = EntryTheme(for: entry)

        HStack(spacing: 0) {
            Rectangle().fill(theme.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                        .font(.body.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let project = entry.project {
                        Text(project.name)
                            .font(.caption)
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                    }
                    if isRunning {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption2)
                    }
                    Spacer(minLength: 6)
                    Text(DurationFormat.clock(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.85))
                }
                if height >= 48 {
                    HStack(spacing: 6) {
                        if let role = entry.role {
                            Text(role.name).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let customer = entry.customer {
                            Text("· \(customer.name)").font(.caption2).foregroundStyle(.secondary)
                        }
                        if entry.billableCached {
                            Image(systemName: "dollarsign.circle.fill")
                                .foregroundStyle(.green.opacity(0.8))
                                .font(.caption2)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, height >= 48 ? 6 : 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: height, alignment: .topLeading)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            // Extra red tint around running entries
            isRunning
                ? RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.red.opacity(0.7), lineWidth: 1)
                : nil
        )
        .help(tooltip(liveEnd: liveEnd))
    }

    private func tooltip(liveEnd: Date?) -> String {
        let startStr = entry.startAt.formatted(date: .omitted, time: .standard)
        let endStr: String
        if entry.endAt != nil {
            endStr = entry.endAt!.formatted(date: .omitted, time: .standard)
        } else if let liveEnd {
            endStr = "Running (\(liveEnd.formatted(date: .omitted, time: .standard)))"
        } else {
            endStr = "Running"
        }
        let duration = (liveEnd ?? entry.endAt).map { $0.timeIntervalSince(entry.startAt) } ?? 0
        let lines = [
            entry.title.isEmpty ? "(untitled)" : entry.title,
            "Role:     \(entry.role?.name ?? "—")",
            "Project:  \(entry.project?.name ?? "—")",
            "Customer: \(entry.customer?.name ?? "—")",
            "Billable: \(entry.billableCached ? "Yes" : "No")",
            "Start:    \(startStr)",
            "End:      \(endStr)",
            "Duration: \(DurationFormat.hoursMinutes(duration))"
        ]
        return lines.joined(separator: "\n")
    }
}

// MARK: - Calendar placeholder

private struct CalendarPlaceholder: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendarTitle: String
    let tintHex: String?
}

private struct CalendarPlaceholderView: View {
    let placeholder: CalendarPlaceholder
    let hourHeight: CGFloat

    var body: some View {
        let duration = placeholder.end.timeIntervalSince(placeholder.start)
        let height = max(20, CGFloat(duration / 3600) * hourHeight)
        let tint = Color(hex: placeholder.tintHex) ?? Color.blue

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.caption2)
                    .foregroundStyle(tint.opacity(0.9))
                Text(placeholder.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint.opacity(0.9))
                    .lineLimit(1)
            }
            if height >= 34 {
                Text("\(timeStr(placeholder.start)) – \(timeStr(placeholder.end))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, height >= 34 ? 4 : 1)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    tint.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .help("""
        \(placeholder.title)
        Calendar: \(placeholder.calendarTitle)
        \(timeStr(placeholder.start)) – \(timeStr(placeholder.end))
        """)
    }

    private func timeStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Apps lane block + popover

private struct SessionBlock: View {
    let session: AppSession
    let width: CGFloat
    let height: CGFloat
    let color: Color
    let isPopoverOpen: Bool
    let togglePopover: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onTapGesture { togglePopover() }
            .popover(
                isPresented: Binding(get: { isPopoverOpen }, set: { if !$0 { togglePopover() } }),
                arrowEdge: .leading
            ) {
                ActivityPopoverView(session: session)
            }
    }
}

private struct ActivityPopoverView: View {
    let session: AppSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACTIVITY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
            VStack(spacing: 6) {
                ForEach(Array(session.apps.enumerated()), id: \.offset) { _, usage in
                    appRow(usage)
                }
            }
            Divider()
            HStack {
                Text("Timeframe")
                Spacer()
                Text("\(time(session.start)) – \(time(session.end))").monospacedDigit()
            }
            .foregroundStyle(.pink)
            HStack {
                Text("Total Time")
                Spacer()
                Text(DurationFormat.clock(session.totalSeconds)).monospacedDigit()
            }
            HStack {
                Text("Active time")
                Spacer()
                Text("\(Int((session.activePercent * 100).rounded()))%").monospacedDigit()
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func appRow(_ usage: AppUsage) -> some View {
        HStack(spacing: 12) {
            Text(DurationFormat.clock(usage.seconds))
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)
            Text(usage.appName)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text("\(Int((usage.percentage * 100).rounded()))%")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

private struct EntryTheme {
    let background: Color
    let accent: Color

    init(for entry: TimeEntry) {
        let base: Color
        if let project = entry.project {
            base = project.displayColor
        } else {
            let seed = entry.customer?.name ?? entry.title
            let hue = Double(abs(seed.hashValue) % 360) / 360
            base = Color(hue: hue, saturation: 0.72, brightness: 0.78)
        }
        self.accent = base
        self.background = base.opacity(entry.billableCached ? 0.22 : 0.12)
    }
}
