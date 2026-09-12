import Foundation

/// One take, from reserving the recorder to handing over a finished file. Reservation and
/// stopping happen synchronously, before tasks can suspend. Every stop caller joins the same
/// task, including application termination. A new take gets a new lifecycle and recorder.
@MainActor
final class RecordingLifecycle {
    enum Phase { case idle, starting, recording, failed, stopping, finished }
    private(set) var phase: Phase = .idle
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<URL?, Never>?

    func start(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        precondition(phase == .idle, "A recording lifecycle belongs to exactly one take")
        phase = .starting
        let task = Task {
            do {
                try await operation()
                if phase == .starting { phase = .recording }
            } catch {
                if phase == .starting { phase = .failed }
                throw error
            }
        }
        startTask = task
        return task
    }

    func stop(_ operation: @escaping @MainActor () async -> URL?) -> Task<URL?, Never> {
        if let stopTask { return stopTask }
        phase = .stopping
        let startup = startTask
        let task = Task {
            // Even a failed start can own a writer or microphone that needs cleaning up.
            _ = try? await startup?.value
            let result = await operation()
            phase = .finished
            startTask = nil
            return result
        }
        stopTask = task
        return task
    }
}
