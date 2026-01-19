import Foundation
import SwiftData
import AppKit
import Combine

@MainActor
final class IntegrityRepairCoordinator: ObservableObject {
    struct PromptState: Identifiable {
        let id = UUID()
        let summary: IntegrityReportSummary
        let report: DataIntegrityService.ScanReport
    }

    @Published var promptState: PromptState?
    @Published var isProcessing = false

    private let container: ModelContainer
    private var hasScanned = false

    init(container: ModelContainer) {
        self.container = container
    }

    func scheduleInitialScan() {
        guard !hasScanned else { return }
        hasScanned = true
        Task { @MainActor in
            let service = DataIntegrityService(context: container.mainContext)
            let report = service.scan()
            if report.isClean {
                await ProjectSnapshotCache.ensureSnapshots(in: container)
            } else {
                promptState = PromptState(summary: report.summary, report: report)
            }
        }
    }

    func repairAndRelaunch() {
        guard !isProcessing, let state = promptState else { return }
        isProcessing = true
        Task { @MainActor in
            let service = DataIntegrityService(context: container.mainContext)
            _ = service.repair(report: state.report, storeURL: persistentStoreURL())
            relaunchApp()
        }
    }

    func continueWithoutRepair() {
        guard let state = promptState else { return }
        promptState = nil
        Task { @MainActor in
            let service = DataIntegrityService(context: container.mainContext)
            service.logUserDecisionContinue(report: state.report)
            await ProjectSnapshotCache.ensureSnapshots(in: container)
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration, completionHandler: nil)
        NSApp.terminate(nil)
    }
}
