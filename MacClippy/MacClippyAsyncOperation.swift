import Foundation

// OperationQueue understands asynchronous Operation subclasses, so the queue
// can enforce its concurrency limit without blocking a worker on an async OCR
// task. Cancellation is propagated to the task and completion always marks the
// operation finished for OperationQueue's accounting.
final class MacClippyAsyncOperation: Operation, @unchecked Sendable {
    private var body: (@Sendable () async -> Void)?
    private let onFinish: @Sendable () -> Void
    private let stateLock = NSLock()
    private var executingState = false
    private var finishedState = false
    private var completionCalled = false
    private var task: Task<Void, Never>?

    init(
        body: @escaping @Sendable () async -> Void,
        onFinish: @escaping @Sendable () -> Void = {}
    ) {
        self.body = body
        self.onFinish = onFinish
    }

    override var isAsynchronous: Bool { true }

    override var isExecuting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return executingState
    }

    override var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finishedState
    }

    override func start() {
        willChangeValue(forKey: "isExecuting")
        stateLock.lock()
        let cancelledBeforeStart = isCancelled || finishedState
        executingState = true
        stateLock.unlock()
        didChangeValue(forKey: "isExecuting")

        if cancelledBeforeStart {
            finish()
            return
        }

        let operationTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if Task.isCancelled {
                self.discardBody()
            } else {
                await self.runBody()
            }
            self.finish()
        }

        // Keep task installation and cancellation under the same lock. A
        // cancellation can race with OperationQueue starting this operation;
        // the second cancellation check closes the window where cancel() saw
        // a nil task before start() assigned the newly created one.
        stateLock.lock()
        let cancelTask = isCancelled || finishedState
        if !cancelTask {
            task = operationTask
        }
        stateLock.unlock()
        if cancelTask {
            operationTask.cancel()
        }
    }

    override func cancel() {
        super.cancel()
        stateLock.lock()
        let task = self.task
        stateLock.unlock()
        task?.cancel()
    }

    private func finish() {
        stateLock.lock()
        guard !finishedState else {
            stateLock.unlock()
            return
        }
        let wasExecuting = executingState
        executingState = false
        finishedState = true
        task = nil
        body = nil
        let shouldCallCompletion = !completionCalled
        completionCalled = true
        stateLock.unlock()

        if wasExecuting {
            willChangeValue(forKey: "isExecuting")
            didChangeValue(forKey: "isExecuting")
        }
        willChangeValue(forKey: "isFinished")
        didChangeValue(forKey: "isFinished")
        if shouldCallCompletion {
            onFinish()
        }
    }

    private func runBody() async {
        let body = takeBody()
        await body?()
    }

    private func takeBody() -> (@Sendable () async -> Void)? {
        stateLock.lock()
        let body = self.body
        self.body = nil
        stateLock.unlock()
        return body
    }

    private func discardBody() {
        stateLock.lock()
        body = nil
        stateLock.unlock()
    }
}
