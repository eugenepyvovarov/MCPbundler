//
//  CapabilitiesService.swift
//  MCP Bundler
//
//  Lightweight factory for capabilities providers
//

import Foundation
import MCP

enum CapabilitiesService {
    #if DEBUG
    static var overrideProviderResolver: ((Server) -> CapabilitiesProvider)?
    #endif

    static func provider(for server: Server) -> CapabilitiesProvider {
        #if DEBUG
        if let resolver = overrideProviderResolver {
            return resolver(server)
        }
        #endif
        switch server.kind {
        case .local_stdio:
            return SDKLocalSTDIOProvider()
        case .remote_http_sse:
            return SDKRemoteHTTPProvider()
        }
    }
}

// MARK: - Error description helper

func describeError(_ error: Error) -> String {
    if let mcpError = error as? MCPError {
        switch mcpError {
        case .transportError(let underlying):
            if let urlErr = underlying as? URLError {
                return "Test failed: URLError(\(urlErr.code.rawValue)) — \(urlErr.localizedDescription)"
            }
            return "Test failed: Transport — \(underlying.localizedDescription)"
        default:
            return "Test failed: \(mcpError.localizedDescription)"
        }
    }
    if let capError = error as? CapabilityError {
        switch capError {
        case .invalidConfiguration:
            return "Test failed: Invalid server configuration. Please check the executable path and arguments."
        case .executionFailed(let message):
            return "Test failed: Server execution failed — \(message)"
        }
    }
    if let urlErr = error as? URLError {
        return "Test failed: URLError(\(urlErr.code.rawValue)) — \(urlErr.localizedDescription)"
    }
    return "Test failed: \(error.localizedDescription)"
}
