//
//  DateFormatting.swift
//  MCP Bundler
//
//  Shared helpers for date/time formatting. Omits the year when the
//  date falls in the current calendar year, per app-wide UX guidance.
//

import Foundation

extension Date {
    /// Abbreviated date + short time. Omits year when it's the current year.
    func mcpShortDateTime() -> String {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: Date())
        let year = calendar.component(.year, from: self)

        var fmt = Date.FormatStyle.dateTime
            .month(.abbreviated)
            .day(.twoDigits)
            .hour(.defaultDigits(amPM: .abbreviated))
            .minute(.twoDigits)
        if year != thisYear {
            fmt = fmt.year(.defaultDigits)
        }
        return self.formatted(fmt)
    }

    /// Abbreviated date only. Omits year when it's the current year.
    func mcpShortDate() -> String {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: Date())
        let year = calendar.component(.year, from: self)

        var fmt = Date.FormatStyle.dateTime
            .month(.abbreviated)
            .day(.twoDigits)
        if year != thisYear {
            fmt = fmt.year(.defaultDigits)
        }
        return self.formatted(fmt)
    }
}

