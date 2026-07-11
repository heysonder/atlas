import Foundation

private struct PolicyTransportResult: @unchecked Sendable {
    let data: Data?
    let response: URLResponse
    let receivedByteCount: Int64
}

private enum PolicyRequestMode: Sendable {
    case buffered
    case stream(
        onResponse: @Sendable (URLResponse) throws -> Void,
        onData: @Sendable (Data) throws -> PolicyStreamDisposition)

    var isBuffered: Bool {
        if case .buffered = self { return true }
        return false
    }
}

private final class PolicyRequestState: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<PolicyTransportResult, any Error>

    private let redirectPolicy: NetworkRedirectPolicy
    private let maximumResponseBytes: Int64
    private let mode: PolicyRequestMode
    private let lock = NSLock()
    private var visited: Set<String>
    private var redirectCount = 0
    private var continuation: Continuation?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var data = Data()
    private var deniedError: NetworkPolicyError?
    private var receivedByteCount: Int64 = 0
    private var cancelled = false
    private var completed = false

    init(
        context: InstanceNetworkContext,
        initialURL: URL,
        maximumResponseBytes: Int64,
        mode: PolicyRequestMode
    ) {
        redirectPolicy = NetworkRedirectPolicy(context: context)
        self.maximumResponseBytes = maximumResponseBytes
        self.mode = mode
        visited = [Self.normalizedRedirectIdentity(initialURL)]
    }

    func install(task: URLSessionDataTask, continuation: Continuation) -> Bool {
        let shouldStart = lock.withLock {
            guard !cancelled else { return false }
            self.continuation = continuation
            self.task = task
            return true
        }
        guard shouldStart else {
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return false
        }
        return shouldStart
    }

    func cancel() {
        let completion: (Continuation, URLSessionDataTask?)? = lock.withLock {
            guard !completed else { return nil }
            cancelled = true
            guard let continuation else {
                return nil
            }
            completed = true
            self.continuation = nil
            let task = self.task
            self.task = nil
            data.removeAll(keepingCapacity: false)
            return (continuation, task)
        }
        completion?.1?.cancel()
        completion?.0.resume(throwing: CancellationError())
    }

    func receive(_ response: URLResponse) -> Bool {
        let declaredLength = response.expectedContentLength
        guard declaredLength < 0 || declaredLength <= Int64(maximumResponseBytes) else {
            finish(
                .failure(
                    NetworkPolicyError.responseTooLarge(
                        maximumBytes: maximumResponseBytes)))
            return false
        }
        do {
            if case .stream(let onResponse, _) = mode {
                try onResponse(response)
            }
        } catch {
            finish(.failure(error))
            return false
        }
        return lock.withLock {
            guard !completed else { return false }
            self.response = response
            return true
        }
    }

    func receive(_ incomingData: Data) -> Bool {
        let shouldProcess = lock.withLock {
            guard !completed,
                Int64(incomingData.count) <= maximumResponseBytes - receivedByteCount
            else { return false }
            receivedByteCount += Int64(incomingData.count)
            return true
        }
        guard shouldProcess else {
            finish(
                .failure(
                    NetworkPolicyError.responseTooLarge(
                        maximumBytes: maximumResponseBytes)))
            return false
        }
        do {
            switch mode {
            case .buffered:
                lock.withLock { data.append(incomingData) }
                return true
            case .stream(_, let onData):
                switch try onData(incomingData) {
                case .continueLoading:
                    return true
                case .stopLoading:
                    finishSuccess()
                    return false
                }
            }
        } catch {
            finish(.failure(error))
            return false
        }
    }

    func complete(error: (any Error)?) {
        let denied = lock.withLock { deniedError }
        if let denied {
            finish(.failure(denied))
        } else if let error {
            finish(.failure(error))
        } else {
            finishSuccess()
        }
    }

    func redirect(response: HTTPURLResponse, request: URLRequest) throws -> URLRequest {
        guard let destination = request.url else {
            throw NetworkPolicyError.invalidURL
        }
        do {
            let sanitized = try redirectPolicy.sanitizedRequest(
                responseURL: response.url,
                request: request)
            lock.lock()
            redirectCount += 1
            let tooMany = redirectCount > 10
            let identity = Self.normalizedRedirectIdentity(destination)
            let loop = visited.contains(identity)
            if !tooMany && !loop { visited.insert(identity) }
            lock.unlock()
            if tooMany {
                throw NetworkPolicyError.tooManyRedirects
            }
            if loop {
                throw NetworkPolicyError.redirectLoop
            }
            return sanitized
        } catch let error as NetworkPolicyError {
            lock.withLock { if deniedError == nil { deniedError = error } }
            throw error
        } catch {
            lock.withLock {
                if deniedError == nil { deniedError = .destinationNotAllowed }
            }
            throw NetworkPolicyError.destinationNotAllowed
        }
    }

    private func finishSuccess() {
        let snapshot = lock.withLock { (response, data, receivedByteCount) }
        guard let response = snapshot.0 else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        finish(
            .success(
                PolicyTransportResult(
                    data: mode.isBuffered ? snapshot.1 : nil,
                    response: response,
                    receivedByteCount: snapshot.2)))
    }

    private func finish(_ result: Result<PolicyTransportResult, any Error>) {
        let state: (Continuation, URLSessionDataTask?)? = lock.withLock {
            guard !completed, let continuation else { return nil }
            completed = true
            self.continuation = nil
            let task = self.task
            self.task = nil
            data.removeAll(keepingCapacity: false)
            return (continuation, task)
        }
        guard let state else { return }
        state.1?.cancel()
        state.0.resume(with: result)
    }

    private static func normalizedRedirectIdentity(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
}

final class PolicySessionTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Int: PolicyRequestState] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        let copied = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        session = URLSession(configuration: copied, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    var sessionIdentity: ObjectIdentifier { ObjectIdentifier(session) }

    func data(
        request: URLRequest,
        context: InstanceNetworkContext,
        maximumResponseBytes: Int64
    ) async throws -> (Data, URLResponse) {
        let result = try await perform(
            request: request,
            context: context,
            maximumResponseBytes: maximumResponseBytes,
            mode: .buffered)
        return (result.data ?? Data(), result.response)
    }

    func stream(
        request: URLRequest,
        context: InstanceNetworkContext,
        maximumResponseBytes: Int64,
        onResponse: @escaping @Sendable (URLResponse) throws -> Void,
        onData: @escaping @Sendable (Data) throws -> PolicyStreamDisposition
    ) async throws -> PolicyStreamResult {
        let result = try await perform(
            request: request,
            context: context,
            maximumResponseBytes: maximumResponseBytes,
            mode: .stream(onResponse: onResponse, onData: onData))
        return PolicyStreamResult(
            response: result.response,
            receivedByteCount: result.receivedByteCount)
    }

    private func perform(
        request: URLRequest,
        context: InstanceNetworkContext,
        maximumResponseBytes: Int64,
        mode: PolicyRequestMode
    ) async throws -> PolicyTransportResult {
        guard let url = request.url else { throw NetworkPolicyError.invalidURL }
        let state = PolicyRequestState(
            context: context,
            initialURL: url,
            maximumResponseBytes: maximumResponseBytes,
            mode: mode)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock { states[task.taskIdentifier] = state }
                guard state.install(task: task, continuation: continuation) else {
                    _ = lock.withLock { states.removeValue(forKey: task.taskIdentifier) }
                    return
                }
                task.resume()
            }
        } onCancel: {
            state.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let state = lock.withLock { states[dataTask.taskIdentifier] }
        completionHandler(state?.receive(response) == true ? .allow : .cancel)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let state = lock.withLock { states[dataTask.taskIdentifier] }
        if state?.receive(data) != true { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let state = lock.withLock { states.removeValue(forKey: task.taskIdentifier) }
        state?.complete(error: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let state = lock.withLock({ states[task.taskIdentifier] }) else {
            completionHandler(nil)
            return
        }
        do {
            completionHandler(try state.redirect(response: response, request: request))
        } catch {
            completionHandler(nil)
        }
    }
}
