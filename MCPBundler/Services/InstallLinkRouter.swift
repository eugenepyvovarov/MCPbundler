import Foundation

struct InstallLinkRequest: Hashable {
    enum Kind: String {
        case server
        case bundle
    }

    let kind: Kind
    let name: String
    let base64Config: String
}

enum InstallLinkRouterError: LocalizedError, Equatable {
    case unsupportedPath(String)
    case invalidURL
    case missingName
    case missingConfig

    var errorDescription: String? {
        switch self {
        case .unsupportedPath(let path):
            return "Unsupported install path: \(path)"
        case .invalidURL:
            return "Unable to parse install link."
        case .missingName:
            return "Install link missing ?name=<serverName> parameter."
        case .missingConfig:
            return "Install link missing ?config=<base64_json> parameter."
        }
    }
}

extension Notification.Name {
    static let installLinkRequest = Notification.Name("installLinkRequest")
    static let installLinkFailure = Notification.Name("installLinkFailure")
}

struct InstallLinkNotificationPayload {
    let request: InstallLinkRequest

    init?(notification: Notification) {
        guard let request = notification.userInfo?["request"] as? InstallLinkRequest else {
            return nil
        }
        self.request = request
    }
}

struct InstallLinkFailurePayload {
    let message: String

    init?(notification: Notification) {
        guard let message = notification.userInfo?["message"] as? String else { return nil }
        self.message = message
    }
}

final class InstallLinkRequestStore {
    static let shared = InstallLinkRequestStore()

    private var requestBuffer: [InstallLinkRequest] = []
    private var failureBuffer: [String] = []
    private(set) var isWorkspaceReady = false
    private var claimedURLExpirations: [String: Date] = [:]
    private let claimInterval: TimeInterval = 1.0

    private init() { }

    func claimURL(_ url: URL) -> Bool {
        cleanupExpiredClaims()
        let token = url.absoluteString
        if let expiry = claimedURLExpirations[token], expiry > Date() {
            return false
        }
        claimedURLExpirations[token] = Date().addingTimeInterval(claimInterval)
        return true
    }

    private func cleanupExpiredClaims() {
        let now = Date()
        claimedURLExpirations = claimedURLExpirations.filter { $0.value > now }
    }

    func enqueueRequest(_ request: InstallLinkRequest) {
        if isWorkspaceReady {
            AppDelegate.writeToStderr("deeplink.store.enqueue.immediate name=\(request.name)\n")
            postRequest(request)
        } else {
            AppDelegate.writeToStderr("deeplink.store.enqueue.buffered name=\(request.name)\n")
            requestBuffer.append(request)
        }
    }

    func enqueueFailure(_ message: String) {
        if isWorkspaceReady {
            AppDelegate.writeToStderr("deeplink.store.failure.immediate message=\(message)\n")
            postFailure(message)
        } else {
            AppDelegate.writeToStderr("deeplink.store.failure.buffered message=\(message)\n")
            failureBuffer.append(message)
        }
    }

    func markWorkspaceReady() {
        isWorkspaceReady = true
        let pendingRequests = requestBuffer
        let pendingFailures = failureBuffer
        AppDelegate.writeToStderr("deeplink.store.ready bufferedRequests=\(pendingRequests.count) bufferedFailures=\(pendingFailures.count)\n")
        requestBuffer.removeAll()
        failureBuffer.removeAll()
        guard !pendingRequests.isEmpty || !pendingFailures.isEmpty else { return }
        DispatchQueue.main.async {
            for request in pendingRequests {
                self.postRequest(request)
            }
            for message in pendingFailures {
                self.postFailure(message)
            }
        }
    }

    func markWorkspaceNotReady() {
        isWorkspaceReady = false
    }

    private func postRequest(_ request: InstallLinkRequest) {
        NotificationCenter.default.post(name: .installLinkRequest,
                                        object: nil,
                                        userInfo: ["request": request])
    }

    private func postFailure(_ message: String) {
        NotificationCenter.default.post(name: .installLinkFailure,
                                        object: nil,
                                        userInfo: ["message": message])
    }
}

enum InstallLinkRouter {
    static func parse(_ url: URL) throws -> InstallLinkRequest? {
        guard url.scheme?.lowercased() == "mcpbundler" else { return nil }
        guard url.host?.lowercased() == "install" else { return nil }

        let kind: InstallLinkRequest.Kind
        switch url.path.lowercased() {
        case "/server":
            kind = .server
        case "/bundle":
            kind = .bundle
        default:
            throw InstallLinkRouterError.unsupportedPath(url.path)
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw InstallLinkRouterError.invalidURL
        }

        guard let name = components.queryItems?.first(where: { $0.name == "name" })?.value,
              !name.isEmpty else {
            throw InstallLinkRouterError.missingName
        }

        guard let config = components.queryItems?.first(where: { $0.name == "config" })?.value,
              !config.isEmpty else {
            throw InstallLinkRouterError.missingConfig
        }

        return InstallLinkRequest(kind: kind, name: name, base64Config: config)
    }
}
