//
//  OAuthUserNotificationDispatcher.swift
//  MCP Bundler
//
//  Sends macOS notifications when OAuth encounters actionable issues.
//

import Foundation
import UserNotifications

enum OAuthUserNotificationDispatcher {
    static func deliverWarning(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    scheduleNotification(with: center, title: title, body: body)
                }
            case .authorized, .provisional, .ephemeral:
                scheduleNotification(with: center, title: title, body: body)
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private static func scheduleNotification(with center: UNUserNotificationCenter,
                                             title: String,
                                             body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let identifier = "oauth-\(UUID().uuidString)"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier,
                                            content: content,
                                            trigger: trigger)
        center.add(request)
    }
}
