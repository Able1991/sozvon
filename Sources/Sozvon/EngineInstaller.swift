// Единственный владелец setup.sh: фоновое обновление движка после обновления приложения
// и установка из мастера («Установить», «Переустановить…», «Скачать модель…») не идут одновременно.

import Combine
import SozvonCore

@MainActor
final class EngineInstaller: ObservableObject {
    static let shared = EngineInstaller()

    enum Owner: Equatable {
        /// Обновление окружения в фоне (ProcessingController).
        case background
        /// Мастер настройки.
        case setup
    }

    /// Кто сейчас запустил setup.sh; nil: установка не идёт.
    @Published private(set) var owner: Owner?
    var isRunning: Bool { owner != nil }

    /// Установка началась и закончилась (очередь расшифровок ждёт и продолжает).
    var willStart: () -> Void = {}
    var didFinish: (Owner, Bool) -> Void = { _, _ in }

    private var process: RunningProcess?

    /// Запустить setup.sh. Уже идёт: false, второй запуск не делается.
    @discardableResult
    func run(_ owner: Owner, onLine: ProcessRunner.LineHandler? = nil,
             done: @escaping @MainActor (Bool) -> Void = { _ in }) -> Bool {
        guard self.owner == nil else { return false }
        self.owner = owner
        willStart()
        process = Engine.setup(onLine: onLine) { [weak self] ok in
            guard let self else { return }
            self.owner = nil
            self.process = nil
            done(ok)
            self.didFinish(owner, ok)
        }
        return true
    }

    /// Остановить установку со всеми дочерними процессами, если её запустил `owner`.
    func cancel(_ owner: Owner) {
        guard self.owner == owner else { return }
        process?.terminate()
    }
}
