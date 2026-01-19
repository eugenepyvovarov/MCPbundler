//
//  BundlerSecrets.swift
//  MCP Bundler
//
//  Shared helpers for resolving env/header values, including Keychain refs.
//

import Foundation
import Security

let defaultKeychainService = "MCPBundler"

func buildEnvironment(for server: Server) -> [String: String] {
    var env: [String: String] = [:]
    if let project = server.project {
        for e in project.envVars {
            if let v = resolveEnvVar(e) { env[e.key] = v }
        }
    }
    for e in server.envOverrides {
        if let v = resolveEnvVar(e) { env[e.key] = v }
    }
    // Add PATH setup from shell
    if env["PATH"] == nil, let shellPath = getShellPath() {
        env["PATH"] = shellPath
    }
    return env
}

private func getShellPath() -> String? {
    // Try to get the PATH from the user's shell
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-c", "echo $PATH"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return path
        }
    } catch {
        return nil
    }
    return nil
}

func buildHeaders(for server: Server) -> [String: String] {
    var headers: [String: String] = [:]
    for h in server.headers {
        guard let value = resolveHeader(h) else { continue }
        if h.header.caseInsensitiveCompare("Authorization") == .orderedSame {
            if value.lowercased().hasPrefix("bearer ") {
                headers[h.header] = value
            } else {
                headers[h.header] = "Bearer \(value)"
            }
        } else {
            headers[h.header] = value
        }
    }
    if let cloudId = server.oauthState?.cloudId, !cloudId.isEmpty {
        headers["X-Atlassian-Cloud-Id"] = cloudId
    }
    for (key, value) in providerSpecificHeaders(for: server) where headers[key] == nil {
        headers[key] = value
    }
    return headers
}

private func providerSpecificHeaders(for server: Server) -> [String: String] {
    guard let metadata = server.oauthState?.providerMetadata, !metadata.isEmpty else { return [:] }

    let host: String? = {
        if let base = server.baseURL, let url = URL(string: base) { return url.host?.lowercased() }
        if let resource = server.oauthConfiguration?.resourceURI { return resource.host?.lowercased() }
        return nil
    }()

    if let host, host.contains("mcp.stripe.com") {
        if let account = metadata["stripe_account"] ?? metadata["stripe_user_id"] {
            return ["Stripe-Account": account]
        }
    }

    return [:]
}

func resolveEnvVar(_ env: EnvVar) -> String? {
    switch env.valueSource {
    case .plain:
        return env.plainValue
    case .keychainRef:
        guard let ref = env.keychainRef else { return nil }
        let (service, account) = parseKeychainRef(ref)
        return KeychainHelper.password(service: service, account: account)
    case .oauthAccessToken:
        guard let server = env.server else { return nil }
        return OAuthService.shared.resolveAccessToken(for: server)
    }
}

func resolveHeader(_ hb: HeaderBinding) -> String? {
    switch hb.valueSource {
    case .plain:
        return hb.plainValue
    case .keychainRef:
        guard let ref = hb.keychainRef else { return nil }
        let (service, account) = parseKeychainRef(ref)
        return KeychainHelper.password(service: service, account: account)
    case .oauthAccessToken:
        guard let server = hb.server else { return nil }
        return OAuthService.shared.resolveAccessToken(for: server)
    }
}

func parseKeychainRef(_ ref: String) -> (service: String, account: String) {
    if let sep = ref.firstIndex(of: ":") {
        let service = String(ref[..<sep])
        let account = String(ref[ref.index(after: sep)...])
        return (service.isEmpty ? defaultKeychainService : service, account)
    }
    return (defaultKeychainService, ref)
}

enum KeychainHelper {
    static func password(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
