//
//  SkillMarketplaceSourceBackfill.swift
//  MCP Bundler
//
//  Ensures default skill marketplace sources exist.
//

import Foundation
import SwiftData

enum SkillMarketplaceSourceBackfill {
    static func perform(in container: ModelContainer) {
        let context = container.mainContext
        do {
            let sources = try context.fetch(FetchDescriptor<SkillMarketplaceSource>())
            var existing = Set(sources.map(\.normalizedKey))
            var didInsert = false

            for defaultSource in SkillMarketplaceSourceDefaults.sources {
                guard !existing.contains(defaultSource.normalizedKey) else { continue }
                let source = SkillMarketplaceSource(owner: defaultSource.owner,
                                                    repo: defaultSource.repo,
                                                    displayName: defaultSource.displayName)
                context.insert(source)
                existing.insert(defaultSource.normalizedKey)
                didInsert = true
            }

            if didInsert, context.hasChanges {
                try context.save()
            }
        } catch {
            AppDelegate.writeToStderr("mcp-bundler: marketplace source backfill failed: \(error)\n")
        }
    }
}
