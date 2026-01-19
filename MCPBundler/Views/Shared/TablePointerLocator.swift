//
//  TablePointerLocator.swift
//  MCP Bundler
//
//  Shared pointer-to-table coordinate helper for drag-and-drop delegates.
//

import AppKit

enum TablePointerLocator {
    static func pointerLocation(in tableView: NSTableView) -> NSPoint? {
        guard let window = tableView.window else { return nil }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return tableView.convert(windowPoint, from: nil)
    }
}

