import Foundation
import EventKit
import ChatKit

// MARK: - Calendar Tool Handler (EventKit-backed)

/// Reads upcoming events from the user's default EventKit calendars.
/// Requires the app to declare `NSCalendarsFullAccessUsageDescription` in Info.plist.
public final class CalendarToolHandler: ToolHandler {
    public let schema = ToolSchema(
        name: "calendar_read",
        description: "Read upcoming events from the user's calendar within a time window.",
        parametersJSON: #"{"days_ahead":"integer (0-30, default 7)"}"#
    )

    private let eventStore = EKEventStore()

    public init() {}

    public func run(params: [String: String]) async throws -> String {
        let days = Int(params["days_ahead"] ?? "7") ?? 7
        let clamped = max(0, min(30, days))
        try await requestAccess()

        let calendar = Calendar.current
        let start = Date()
        guard let end = calendar.date(byAdding: .day, value: clamped, to: start) else {
            return "Unable to compute end date."
        }

        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)

        if events.isEmpty {
            return "No events in the next \(clamped) day\(clamped == 1 ? "" : "s")."
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        let lines = events.prefix(20).map { event -> String in
            let when = formatter.string(from: event.startDate)
            let title = event.title ?? "(untitled)"
            let loc = event.location.map { " @ \($0)" } ?? ""
            return "• \(when) — \(title)\(loc)"
        }

        return "Upcoming events (\(events.count) total):\n" + lines.joined(separator: "\n")
    }

    // MARK: - Permission

    private func requestAccess() async throws {
        if #available(macOS 14.0, iOS 17.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .fullAccess { return }
            let granted = try await eventStore.requestFullAccessToEvents()
            if !granted {
                throw CalendarError.accessDenied
            }
        } else {
            // Fallback for older OS versions (deployment targets are 14/17, but keep defensive).
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .authorized { return }
            let granted = try await eventStore.requestAccess(to: .event)
            if !granted {
                throw CalendarError.accessDenied
            }
        }
    }

    enum CalendarError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Calendar access was denied. Enable it in System Settings → Privacy & Security → Calendars."
            }
        }
    }
}
