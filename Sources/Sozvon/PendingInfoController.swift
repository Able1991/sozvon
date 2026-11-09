// Calls waiting for their description ("Later"): the menu count and a quiet reminder notification.
// Rules (idle 10 minutes, once an hour per call, never during a recording) are in SozvonCore.ReminderPlanner.

import AppKit
import SozvonCore

@MainActor
final class PendingInfoController {
    private(set) var pending: [PendingCall] = []
    private var planner = ReminderPlanner()
    private var timer: Timer?
    private var scan: Task<Void, Never>?
    private static let notificationID = "sozvon.describeCall"

    /// Recording (or starting, stopping), or the call prompt is open: never remind.
    var isBusy: () -> Bool = { false }
    /// The pending list changed (the menu count).
    var onChange: () -> Void = {}

    func start() {
        refresh()
        timer = Timer.repeatingOnMain(every: 60) { [weak self] in self?.refresh(remind: true) }
    }

    /// Sozvon's state changed: the idle clock restarts after a recording.
    func activity() {
        planner.activity(busy: isBusy(), now: Date())
    }

    /// Re-read the calls folder in the background (call.json only).
    func refresh(remind: Bool = false) {
        scan?.cancel()
        let root = Paths.calls
        scan = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { PendingInfo.all(in: root) }.value
            guard let self, !Task.isCancelled else { return }
            if found != self.pending {
                self.pending = found
                if found.isEmpty { Notifier.shared.remove(id: Self.notificationID) }
                self.onChange()
            }
            if remind { self.remindIfDue() }
        }
    }

    private func remindIfDue() {
        let due = planner.due(pending, now: Date(), busy: isBusy())
        guard let first = due.first else { return }
        let others = pending.count - 1
        Notifier.shared.post(Self.title(first), others > 0 ? L("Ещё ждут описания: %@", others) : "",
                             action: .describeCall, url: first.dir, id: Self.notificationID)
    }

    /// "The call at 15:04 is waiting for a description" (with the day if it was not today).
    static func title(_ p: PendingCall) -> String {
        guard let d = p.date else { return L("Звонок %@ ждёт описания", p.id) }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        if Calendar.current.isDateInToday(d) { return L("Звонок в %@ ждёт описания", time.string(from: d)) }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("dMMM")
        return L("Звонок %@ в %@ ждёт описания", day.string(from: d), time.string(from: d))
    }
}
