import Foundation
import SwiftData

@MainActor
struct BundlerEventService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func enqueue(projectToken: UUID, serverTokens: [UUID] = [], type: BundlerEvent.EventType, createdAt: Date = Date()) {
        let event = BundlerEvent(projectToken: projectToken, serverTokens: serverTokens, type: type, createdAt: createdAt)
        context.insert(event)
        saveIfNeeded()
    }

    func enqueue(for project: Project, serverTokens: [UUID] = [], type: BundlerEvent.EventType, createdAt: Date = Date()) {
        let projectToken = project.eventToken
        enqueue(projectToken: projectToken, serverTokens: serverTokens, type: type, createdAt: createdAt)
    }

    func enqueue(for project: Project, servers: [Server], type: BundlerEvent.EventType, createdAt: Date = Date()) {
        let serverTokens = servers.map { $0.eventToken }
        enqueue(for: project, serverTokens: serverTokens, type: type, createdAt: createdAt)
    }

    func fetchPendingEvents() -> [BundlerEvent] {
        let descriptor = FetchDescriptor<BundlerEvent>(
            predicate: #Predicate { !$0.handled },
            sortBy: [SortDescriptor(\BundlerEvent.createdAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func markEventsHandled(_ events: [BundlerEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            event.handled = true
        }
        saveIfNeeded()
    }

    func deleteEvents(_ events: [BundlerEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            context.delete(event)
        }
        saveIfNeeded()
    }

    func pruneEvents(olderThan cutoff: Date) {
        let descriptor = FetchDescriptor<BundlerEvent>(
            predicate: #Predicate { $0.createdAt < cutoff },
            sortBy: []
        )
        guard let candidates = try? context.fetch(descriptor), !candidates.isEmpty else { return }
        for event in candidates {
            context.delete(event)
        }
        saveIfNeeded()
    }

    private func saveIfNeeded() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            logError("Failed to save Bundler events: \(error)")
        }
    }

    private func logError(_ message: String) {
        let formatted = "mcp-bundler: \(message)\n"
        if let data = formatted.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    static func emit(in context: ModelContext,
                     project: Project,
                     servers: [Server] = [],
                     type: BundlerEvent.EventType,
                     createdAt: Date = Date()) {
        let service = BundlerEventService(context: context)
        service.enqueue(for: project, servers: servers, type: type, createdAt: createdAt)
    }

    static func emit(in context: ModelContext,
                     projectToken: UUID,
                     serverTokens: [UUID],
                     type: BundlerEvent.EventType,
                     createdAt: Date = Date()) {
        let service = BundlerEventService(context: context)
        service.enqueue(projectToken: projectToken, serverTokens: serverTokens, type: type, createdAt: createdAt)
    }
}
