import Foundation

import MacClippyCore
import MacClippyPlatform

struct MacClippyDeferredOCRJob {
    let data: Data
    let recordID: RecordID
    let lifecycleToken: MacClippyRuntimeLifecycleToken
}

// OperationQueue understands asynchronous Operation subclasses, so the queue
// can enforce its concurrency limit without blocking a worker on an async OCR
// task. Cancellation is propagated to the task and completion always marks the
// operation finished for OperationQueue's accounting.
private final class MacClippyAsyncOperation: Operation, @unchecked Sendable {
    private let body: @Sendable () async -> Void
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

        let body = self.body
        let operationTask = Task.detached(priority: .utility) { [weak self] in
            await body()
            self?.finish()
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
}

extension MacClippyRuntime {
    func scheduleOCR(for data: Data, recordID: RecordID) {
        guard let lifecycleToken = activeLifecycleToken() else { return }
        scheduleOCR(for: data, recordID: recordID, lifecycleToken: lifecycleToken)
    }

    func scheduleOCR(
        for data: Data,
        recordID: RecordID,
        lifecycleToken: MacClippyRuntimeLifecycleToken,
        forceStart: Bool = false
    ) {
        guard isCurrentLifecycleToken(lifecycleToken) else { return }
        guard pendingOCRJobs < maxPendingOCRJobs else {
            MacClippyLog.record(
                category: .capture,
                code: .ocrFailed,
                operation: "ocr_enqueue",
                recoveryAction: "retry_ocr_from_record",
                impact: "ocr_queue_full"
            )
            return
        }
        guard data.count <= maxPendingOCRBytes,
              pendingOCRBytes <= maxPendingOCRBytes - data.count else {
            MacClippyLog.record(
                category: .capture,
                code: .ocrFailed,
                operation: "ocr_enqueue",
                recoveryAction: "retry_ocr_from_record",
                impact: "ocr_byte_budget_exceeded"
            )
            return
        }

        pendingOCRJobs += 1
        pendingOCRBytes += data.count
        pendingOCRJobsByGeneration[lifecycleToken.generation, default: 0] += 1
        pendingOCRBytesByGeneration[lifecycleToken.generation, default: 0] += data.count
        if forceStart || shouldStartOCRNow() {
            enqueueOCROperation(
                data: data,
                recordID: recordID,
                lifecycleToken: lifecycleToken
            )
        } else {
            deferredOCRJobs.append(
                MacClippyDeferredOCRJob(
                    data: data,
                    recordID: recordID,
                    lifecycleToken: lifecycleToken
                )
            )
            armOCRScheduleTimerIfNeeded()
        }
    }

    func shouldStartOCRNow() -> Bool {
        let conditions = ocrScheduleConditionsProvider()
        return MacClippyOCRSchedulePolicy.shouldStartRecognition(
            secondsSinceLastInput: conditions.secondsSinceLastInput,
            isLowPowerMode: conditions.isLowPowerMode
        )
    }

    func startDeferredOCRIfReady() {
        guard shouldStartOCRNow() else { return }
        let jobs = deferredOCRJobs
        deferredOCRJobs.removeAll()
        if jobs.isEmpty {
            cancelOCRScheduleTimer()
            return
        }
        cancelOCRScheduleTimer()
        for job in jobs {
            enqueueOCROperation(
                data: job.data,
                recordID: job.recordID,
                lifecycleToken: job.lifecycleToken
            )
        }
    }

    func armOCRScheduleTimerIfNeeded() {
        guard ocrScheduleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.startDeferredOCRIfReady()
        }
        ocrScheduleTimer = timer
        timer.resume()
    }

    func cancelOCRScheduleTimer() {
        ocrScheduleTimer?.setEventHandler {}
        ocrScheduleTimer?.cancel()
        ocrScheduleTimer = nil
    }

    private func enqueueOCROperation(
        data: Data,
        recordID: RecordID,
        lifecycleToken: MacClippyRuntimeLifecycleToken
    ) {
        let dataByteCount = data.count
        let operation = MacClippyAsyncOperation(
            body: { [weak self] in
                guard let self else { return }
                await self.performOCR(
                    data: data,
                    recordID: recordID,
                    lifecycleToken: lifecycleToken
                )
            },
            onFinish: { [weak self] in
                self?.captureQueue.async { [weak self] in
                    guard let self else { return }
                    let generation = lifecycleToken.generation
                    let remaining = max(0, (self.pendingOCRJobsByGeneration[generation] ?? 0) - 1)
                    let remainingBytes = max(
                        0,
                        (self.pendingOCRBytesByGeneration[generation] ?? 0) - dataByteCount
                    )
                    if remaining == 0 {
                        self.pendingOCRJobsByGeneration.removeValue(forKey: generation)
                    } else {
                        self.pendingOCRJobsByGeneration[generation] = remaining
                    }
                    if remainingBytes == 0 {
                        self.pendingOCRBytesByGeneration.removeValue(forKey: generation)
                    } else {
                        self.pendingOCRBytesByGeneration[generation] = remainingBytes
                    }
                    if self.activeLifecycleToken()?.generation == generation {
                        self.pendingOCRJobs = remaining
                        self.pendingOCRBytes = remainingBytes
                    }
                }
            }
        )
        ocrQueue.addOperation(operation)
    }

    private func performOCR(
        data: Data,
        recordID: RecordID,
        lifecycleToken: MacClippyRuntimeLifecycleToken
    ) async {
        do {
            try Task.checkCancellation()
            guard isCurrentLifecycleToken(lifecycleToken) else { return }
            let text = try await recognizeOCR(data)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !text.isEmpty else { return }

            _ = try withCurrentLifecycleStoreLock(lifecycleToken) {
                try persistOCRText(text, recordID: recordID)
            }
        } catch is CancellationError {
            return
        } catch {
            MacClippyLog.record(
                category: .capture,
                code: .ocrFailed,
                operation: "ocr_update",
                recoveryAction: "retry_ocr_from_record",
                impact: "ocr_search_text_unavailable"
            )
        }
    }

    private func persistOCRText(_ text: String, recordID: RecordID) throws {
        guard try !clipboardStore.metas(for: [recordID]).isEmpty else { return }
        do {
            try persistOCRSearchProjection(Self.limitedOCRText(text), recordID: recordID)
        } catch {
            try markOCRSearchRepairNeeded()
            throw error
        }
    }

    private func persistOCRSearchProjection(_ persistedOCRText: String, recordID: RecordID) throws {
        // Re-read the latest body and metadata while the store lock is held.
        // OCR must rebuild the complete projection rather than replacing the
        // FTS row with OCR text alone; otherwise a prior label or body update
        // would be silently removed from search.
        guard let updatedMeta = try clipboardStore.metas(for: [recordID]).first else {
            try searchStore.remove(id: recordID)
            return
        }
        let body = try clipboardStore.body(for: recordID)
        let indexText = Self.searchableIndexText(
            for: body,
            ocrText: persistedOCRText,
            label: updatedMeta.customLabel,
            representationUTIs: try clipboardStore.representationUTIs(for: recordID),
            sourceAppBundleID: updatedMeta.sourceAppBundleID
        )
        guard !indexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try searchStore.remove(id: recordID)
            return
        }
        try upsertOCRSearchIndex(id: recordID, text: indexText)
        try clipboardStore.setOCRText(id: recordID, text: persistedOCRText)

        if try clipboardStore.metas(for: [recordID]).isEmpty {
            try searchStore.remove(id: recordID)
        }
    }

    private func markOCRSearchRepairNeeded() throws {
        // Keep repair marking in the same lifecycle fence as the OCR
        // projection attempt so a failed FTS write cannot be mistaken for a
        // complete index.
        do {
            try searchStore.markRepairNeeded()
            storageDegradedReasons.insert("fts-repair-needed")
        } catch {
            storageDegradedReasons.insert("fts-repair-needed")
            MacClippyLog.record(
                category: .storage,
                code: .databaseHealthFailed,
                operation: "persist_ocr_fts_repair_marker",
                recoveryAction: "export_diagnostics_and_repair_storage",
                impact: "ocr_search_repair_state_not_persisted"
            )
        }
    }

    private static func limitedOCRText(_ text: String) -> String {
        let maxBytes = MacClippyCollectionLimits.maxOCRTextUTF8Bytes
        guard text.utf8.count > maxBytes else { return text }

        var endIndex = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
        while endIndex > text.utf8.startIndex {
            if let limitedText = String(bytes: text.utf8[..<endIndex], encoding: .utf8) {
                return limitedText
            }
            endIndex = text.utf8.index(before: endIndex)
        }
        return ""
    }

    private func upsertOCRSearchIndex(id: RecordID, text: String) throws {
        #if DEBUG
            if failNextOCRSearchUpsertForTesting {
                failNextOCRSearchUpsertForTesting = false
                throw MacClippyStoreError.invalidStoredRecord
            }
        #endif
        try searchStore.upsert(id: id, text: text)
    }
}
