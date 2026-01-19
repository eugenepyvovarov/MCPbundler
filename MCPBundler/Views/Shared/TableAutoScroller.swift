//
//  TableAutoScroller.swift
//  MCP Bundler
//
//  Shared NSTableView edge auto-scrolling during drag-and-drop.
//

import AppKit

final class TableAutoScroller {
    private weak var tableView: NSTableView?
    private var timer: Timer?
    private var deltaPerTick: CGFloat = 0

    deinit {
        timer?.invalidate()
    }

    func update(tableView: NSTableView?, pointerLocation: NSPoint) {
        guard let tableView else {
            stop()
            return
        }
        self.tableView = tableView

        let visibleRect = tableView.visibleRect
        let threshold: CGFloat = 34
        let maxDelta: CGFloat = 14

        let distanceToTop = pointerLocation.y - visibleRect.minY
        let distanceToBottom = visibleRect.maxY - pointerLocation.y

        var nextDelta: CGFloat = 0
        if distanceToTop < threshold {
            let factor = max(0, 1 - (distanceToTop / threshold))
            nextDelta = -maxDelta * factor
        } else if distanceToBottom < threshold {
            let factor = max(0, 1 - (distanceToBottom / threshold))
            nextDelta = maxDelta * factor
        }

        if abs(nextDelta) < 0.25 {
            stopScrolling()
        } else {
            deltaPerTick = nextDelta
            startIfNeeded()
        }
    }

    func stop() {
        stopScrolling()
        tableView = nil
    }

    private func stopScrolling() {
        deltaPerTick = 0
        timer?.invalidate()
        timer = nil
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 1.0 / 120.0
    }

    private func tick() {
        guard deltaPerTick != 0,
              let tableView,
              let scrollView = tableView.enclosingScrollView else {
            stop()
            return
        }

        let clipView = scrollView.contentView
        let maxScrollY = max(0, tableView.bounds.height - clipView.bounds.height)
        let currentOrigin = clipView.bounds.origin
        let nextY = min(max(0, currentOrigin.y + deltaPerTick), maxScrollY)
        guard nextY != currentOrigin.y else {
            stopScrolling()
            return
        }

        clipView.scroll(to: NSPoint(x: currentOrigin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
    }
}

