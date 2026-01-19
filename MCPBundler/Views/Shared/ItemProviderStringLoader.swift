//
//  ItemProviderStringLoader.swift
//  MCP Bundler
//
//  Shared helpers for extracting string payloads from NSItemProvider drops.
//

import Foundation
import UniformTypeIdentifiers

enum ItemProviderStringLoader {
    static func loadString(from provider: NSItemProvider,
                           typeIdentifier: String?,
                           completion: @escaping (String?) -> Void) {
        var didComplete = false

        func finish(_ value: String?) {
            guard !didComplete else { return }
            didComplete = true
            completion(value?.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        func decodeString(from data: Data) -> String? {
            String(data: data, encoding: .utf8)
        }

        func decodeString(from url: URL) -> String? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decodeString(from: data)
        }

        func fallbackToTextObject() {
            guard provider.canLoadObject(ofClass: NSString.self) else {
                finish(nil)
                return
            }

            _ = provider.loadObject(ofClass: NSString.self) { object, error in
                guard let raw = object as? NSString else {
                    finish(nil)
                    return
                }
                finish(raw as String)
            }
        }

        func loadItemFallback(typeIdentifier: String) {
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                fallbackToTextObject()
                return
            }

            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                let string: String?
                if let nsString = item as? NSString {
                    string = nsString as String
                } else if let raw = item as? String {
                    string = raw
                } else if let data = item as? Data {
                    string = decodeString(from: data)
                } else if let url = item as? URL {
                    string = decodeString(from: url)
                } else if let nsURL = item as? NSURL {
                    string = decodeString(from: nsURL as URL)
                } else {
                    string = nil
                }

                if let string {
                    finish(string)
                    return
                }

                fallbackToTextObject()
            }
        }

        guard let typeIdentifier else {
            fallbackToTextObject()
            return
        }

        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
            fallbackToTextObject()
            return
        }

        if #available(macOS 11.0, *) {
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data, let string = decodeString(from: data) {
                    finish(string)
                    return
                }
                loadItemFallback(typeIdentifier: typeIdentifier)
            }
        } else {
            loadItemFallback(typeIdentifier: typeIdentifier)
        }
    }
}

