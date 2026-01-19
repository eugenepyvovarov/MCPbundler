//
//  TableViewAccessor.swift
//  MCP Bundler
//
//  SwiftUI helper to locate the underlying NSTableView for a Table.
//

import AppKit
import SwiftUI

struct TableViewAccessor: NSViewRepresentable {
    @Binding var tableView: NSTableView?
    var onResolve: ((NSTableView) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            if let resolved = resolveTableView(from: view) {
                tableView = resolved
                onResolve?(resolved)
            } else if let tableView {
                onResolve?(tableView)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            if let resolved = resolveTableView(from: nsView) {
                if resolved !== tableView {
                    tableView = resolved
                }
                onResolve?(resolved)
            }
        }
    }

    private func resolveTableView(from view: NSView) -> NSTableView? {
        var cursor: NSView? = view
        while let current = cursor {
            if let table = findTableView(in: current) { return table }
            cursor = current.superview
        }
        return nil
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        if let scrollView = view as? NSScrollView, let table = scrollView.documentView as? NSTableView {
            return table
        }
        for subview in view.subviews {
            if let table = findTableView(in: subview) { return table }
        }
        return nil
    }
}
