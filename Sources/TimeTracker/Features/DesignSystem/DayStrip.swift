import SwiftUI

/// The day as one horizontal strip of coloured blocks, one per entry.
struct DayStripModel: Equatable {
    struct Block: Equatable, Identifiable {
        let id: UUID
        /// Fractions of the strip's width, 0...1.
        let from: Double
        let to: Double
        let colorKey: String
        let isRunning: Bool
    }

    let rangeStart: Date
    let rangeEnd: Date
    let blocks: [Block]
    /// Hours to label under the strip.
    let hourMarks: [(hour: Int, fraction: Double)]
    let trackedSeconds: TimeInterval

    static func == (a: DayStripModel, b: DayStripModel) -> Bool {
        a.rangeStart == b.rangeStart && a.rangeEnd == b.rangeEnd && a.blocks == b.blocks
            && a.trackedSeconds == b.trackedSeconds
    }

    struct Item {
        let id: UUID
        let start: Date
        let end: Date?
        let colorKey: String
    }

    /// The working day shown is 08:00–19:00, widened to fit anything tracked outside it.
    static func make(items: [Item], day: Date, now: Date, calendar: Calendar = .current) -> DayStripModel {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let clipped = items.compactMap { item -> (Item, Date, Date)? in
            let end = min(item.end ?? now, dayEnd)
            let start = max(item.start, dayStart)
            return end > start ? (item, start, end) : nil
        }
        var startHour = 8, endHour = 19
        for (_, s, e) in clipped {
            startHour = min(startHour, calendar.component(.hour, from: s))
            let endComponents = calendar.dateComponents([.hour, .minute], from: e)
            endHour = max(endHour, (endComponents.hour ?? 0) + ((endComponents.minute ?? 0) > 0 ? 1 : 0))
        }
        if calendar.isDate(now, inSameDayAs: dayStart) {
            endHour = max(endHour, calendar.component(.hour, from: now) + 1)
        }
        endHour = min(endHour, 24)
        let rangeStart = dayStart.addingTimeInterval(Double(startHour) * 3600)
        let rangeEnd = dayStart.addingTimeInterval(Double(endHour) * 3600)
        let length = rangeEnd.timeIntervalSince(rangeStart)

        func fraction(_ date: Date) -> Double {
            min(1, max(0, date.timeIntervalSince(rangeStart) / length))
        }
        let blocks = clipped.map { item, s, e in
            Block(id: item.id, from: fraction(s), to: fraction(e), colorKey: item.colorKey, isRunning: item.end == nil)
        }
        let step = (endHour - startHour) > 12 ? 4 : 2
        let marks = stride(from: startHour, through: endHour, by: step).map {
            (hour: $0, fraction: Double($0 - startHour) / Double(endHour - startHour))
        }
        let tracked = clipped.reduce(0) { $0 + $1.2.timeIntervalSince($1.1) }
        return DayStripModel(rangeStart: rangeStart, rangeEnd: rangeEnd, blocks: blocks,
                             hourMarks: marks, trackedSeconds: tracked)
    }
}

/// Draws a `DayStripModel`; `color` maps a block's key to its project colour.
struct DayStrip: View {
    let model: DayStripModel
    var height: CGFloat = 14
    var showsHours = true
    var color: (String) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    ForEach(model.blocks) { block in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(block.colorKey).gradient)
                            .opacity(block.isRunning ? 0.75 : 1)
                            .frame(width: max(2, (block.to - block.from) * geo.size.width))
                            .offset(x: block.from * geo.size.width)
                    }
                }
            }
            .frame(height: height)
            .clipShape(Capsule())
            if showsHours {
                GeometryReader { geo in
                    ForEach(model.hourMarks, id: \.hour) { mark in
                        Text("\(mark.hour)")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .position(x: min(max(8, mark.fraction * geo.size.width), geo.size.width - 8), y: 5)
                    }
                }
                .frame(height: 10)
            }
        }
        .accessibilityLabel("Today's tracked time")
    }
}
