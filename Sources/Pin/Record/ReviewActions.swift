import Foundation

/// Buttons, keys and automation enter through the same gate. Closing lets an already requested
/// export finish, and only then releases its source file. No later action can join a closed review.
@MainActor
final class ReviewActions {
    private var task: Task<Void, Never>?
    private(set) var isClosed = false
    private var cleanup: (() -> Void)?

    @discardableResult
    func run(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        guard !isClosed, task == nil else { return false }
        task = Task {
            await operation()
            task = nil
            if isClosed { drain() }
        }
        return true
    }

    func close(cleanup: @escaping () -> Void) {
        guard !isClosed else { return }
        isClosed = true
        self.cleanup = cleanup
        if task == nil { drain() }
    }

    private func drain() {
        let action = cleanup
        cleanup = nil
        action?()
    }
}
