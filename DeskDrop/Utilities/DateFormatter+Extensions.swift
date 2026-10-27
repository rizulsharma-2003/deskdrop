import Foundation

extension Date {
    /// "Today, 3:41 PM", "Yesterday, 9:02 AM" or "12 Oct, 4:15 PM".
    func historyDisplayString(relativeTo now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> String {
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDate(self, inSameDayAs: now) {
            return String(localized: "Today, \(time)")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(self, inSameDayAs: yesterday) {
            return String(localized: "Yesterday, \(time)")
        }
        return formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// Conversation list: "3:41 PM", "Yesterday", "Tuesday" or "12 Oct".
    func chatListString(relativeTo now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> String {
        if calendar.isDate(self, inSameDayAs: now) { return formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(self, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), self > weekAgo {
            return formatted(.dateTime.weekday(.wide))
        }
        return formatted(.dateTime.day().month(.abbreviated))
    }

    /// Day separators in a conversation: "Today", "Yesterday" or "Monday, 21 Oct".
    func chatDayString(relativeTo now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> String {
        if calendar.isDate(self, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(self, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        return formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}
