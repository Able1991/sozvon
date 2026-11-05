// Состояние записи: одна машина состояний вместо набора флагов.
//
//   idle ──begin──▶ starting ──started──▶ recording ──stop──▶ stopping ──finalized──▶ saved ──dismiss──▶ idle
//                      │                                                                │
//                      └──failed──▶ idle                     saved ──begin──▶ starting ─┘ (новая запись, пока открыт вопрос)

import Foundation

/// Идущая запись: папка, время начала и то, что уже сказали о звонке («Проект и собеседники»).
public struct RecordingSession: Equatable, Sendable {
    public let dir: URL
    public let startedAt: Date
    public var info: CallInfo

    public init(dir: URL, startedAt: Date, info: CallInfo) {
        self.dir = dir
        self.startedAt = startedAt
        self.info = info
    }

    /// «12:34» или «1:02:03» от начала записи.
    public func elapsed(at now: Date = Date()) -> String {
        Call.clock(max(0, Int(now.timeIntervalSince(startedAt))), empty: "0:00")
    }
}

public enum RecordingState: Sendable {
    case idle
    /// Ждём разрешений и запуска захвата: второй старт не допускается.
    case starting(dir: URL)
    case recording(RecordingSession)
    /// Захват останавливается, файлы закрываются. Задачу ждут выход из приложения и сбой захвата.
    case stopping(RecordingSession, finalize: Task<Void, Never>)
    /// Запись сохранена, ждём ответа «о чём был звонок».
    case saved(dir: URL)

    public var isRecording: Bool { if case .recording = self { return true } else { return false } }
    public var isStarting: Bool { if case .starting = self { return true } else { return false } }
    public var isStopping: Bool { if case .stopping = self { return true } else { return false } }

    /// Можно начать новую запись (из idle и из saved, как `RecordingMachine.begin`).
    public var canBegin: Bool {
        switch self {
        case .idle, .saved: return true
        default: return false
        }
    }

    /// Запись идёт или ещё не дописана на диск.
    public var isCapturing: Bool { isRecording || isStopping }

    public var session: RecordingSession? {
        switch self {
        case .recording(let s), .stopping(let s, _): return s
        default: return nil
        }
    }

    public var dir: URL? {
        switch self {
        case .idle: return nil
        case .starting(let d), .saved(let d): return d
        case .recording(let s), .stopping(let s, _): return s.dir
        }
    }

    public var finalizeTask: Task<Void, Never>? {
        if case .stopping(_, let t) = self { return t }
        return nil
    }

    /// Короткое имя состояния (для журналов и тестов).
    public var name: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .stopping: return "stopping"
        case .saved: return "saved"
        }
    }
}

/// Переходы между состояниями. Каждый метод проверяет, что переход допустим, и возвращает false, если нет.
public struct RecordingMachine: Sendable {
    public private(set) var state: RecordingState = .idle

    public init() {}

    /// Начать запуск записи в папку. Можно из idle и из saved (вопрос о прошлом звонке ещё открыт).
    @discardableResult
    public mutating func begin(_ dir: URL) -> Bool {
        switch state {
        case .idle, .saved: state = .starting(dir: dir); return true
        default: return false
        }
    }

    /// Захват запустился.
    @discardableResult
    public mutating func started(_ session: RecordingSession) -> Bool {
        guard case .starting(let dir) = state, dir == session.dir else { return false }
        state = .recording(session)
        return true
    }

    /// Запуск не удался (нет разрешений, ошибка захвата).
    @discardableResult
    public mutating func startFailed() -> Bool {
        guard state.isStarting else { return false }
        state = .idle
        return true
    }

    /// Поменять ответы о звонке во время записи.
    @discardableResult
    public mutating func updateInfo(_ info: CallInfo) -> Bool {
        guard case .recording(var s) = state else { return false }
        s.info = info
        state = .recording(s)
        return true
    }

    /// Остановка: дальше файлы дописывает задача `finalize`. Возвращает сессию.
    @discardableResult
    public mutating func stop(finalize: Task<Void, Never>) -> RecordingSession? {
        guard case .recording(let s) = state else { return nil }
        state = .stopping(s, finalize: finalize)
        return s
    }

    /// Файлы закрыты, call.json записан.
    @discardableResult
    public mutating func finalized() -> Bool {
        guard case .stopping(let s, _) = state else { return false }
        state = .saved(dir: s.dir)
        return true
    }

    /// Ответили на вопрос о звонке (или отказались). Если уже началась новая запись, ничего не меняем.
    @discardableResult
    public mutating func dismissSaved(_ dir: URL) -> Bool {
        guard case .saved(let d) = state, d == dir else { return false }
        state = .idle
        return true
    }
}
