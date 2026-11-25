// How fast this Mac transcribes: processing seconds per call second, per model, from finished runs.
// Only long calls count (short ones are dominated by start-up cost); the last 10 samples per model are kept.

import Foundation

public struct SpeedBook: Codable, Equatable, Sendable {
    public static let defaultsKey = "speedBook"
    static let minCallSeconds = 600.0
    static let keep = 10

    private var samples: [String: [Double]] = [:]
    /// The model of the most recent accepted sample: a waiting call is estimated with it.
    public private(set) var lastModel: String?

    public init() {}

    public mutating func record(model: String, callSeconds: Double, processingSeconds: Double) {
        guard !model.isEmpty, callSeconds >= Self.minCallSeconds, processingSeconds > 0 else { return }
        var list = samples[model, default: []]
        list.append(processingSeconds / callSeconds)
        if list.count > Self.keep { list.removeFirst(list.count - Self.keep) }
        samples[model] = list
        lastModel = model
    }

    /// Processing seconds per call second: the mean of the last samples. Nil without samples.
    public func factor(model: String) -> Double? {
        guard let list = samples[model], !list.isEmpty else { return nil }
        return list.reduce(0, +) / Double(list.count)
    }

    public func estimate(model: String, callSeconds: Double) -> Double? {
        factor(model: model).map { $0 * callSeconds }
    }

    public static func load(_ defaults: UserDefaults = .standard) -> SpeedBook {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(SpeedBook.self, from: $0) } ?? SpeedBook()
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

public enum EstimateText {
    /// "≈ 1 мин" under two minutes, "≈ 12 мин", then "≈ 1 ч", "≈ 1 ч 10 мин" (whole minutes, rounded: 59.5 is 1 h).
    public static func duration(_ seconds: Double) -> String {
        let minutes = seconds < 120 ? 1 : Int((seconds / 60).rounded())
        if minutes < 60 { return L("≈ %@ мин", minutes) }
        if minutes % 60 == 0 { return L("≈ %@ ч", minutes / 60) }
        return L("≈ %@ ч %@ мин", minutes / 60, minutes % 60)
    }

    /// The running call: "осталось ≈ 12 мин", so it does not read as a second duration next to the call's own.
    public static func remaining(estimate: Double, elapsed: Double) -> String {
        elapsed >= estimate ? L("почти готово") : L("осталось %@", duration(estimate - elapsed))
    }
}
