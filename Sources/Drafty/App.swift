import AppKit
import SwiftUI
import UserNotifications

@main @MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let inbox = Inbox()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        popover.behavior = .transient
        let content = NSHostingController(rootView: ContentView(inbox: inbox))
        // Size the popover from the SwiftUI content before it's positioned, not after (which pushes it offscreen).
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading
        updateBadge()

        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let cancel = UNNotificationAction(identifier: "cancel", title: "Cancel auto-reply")
        notifications.setNotificationCategories([UNNotificationCategory(identifier: "autoReply", actions: [cancel], intentIdentifiers: [])])

        inbox.start()
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateBadge() {
        withObservationTracking {
            let count = inbox.items.count
            statusItem.button?.image = NSImage(systemSymbolName: count > 0 ? "tray.full.fill" : "tray", accessibilityDescription: "Drafty")
            statusItem.button?.title = count > 0 ? " \(count)" : ""
        } onChange: {
            Task { @MainActor in self.updateBadge() }
        }
    }

    /// Never shown for a menu bar app, but it's what makes ⌘C/⌘V/⌘A work in text fields.
    private static func mainMenu() -> NSMenu {
        let app = NSMenu()
        app.addItem(withTitle: "Quit Drafty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let menu = NSMenu()
        for submenu in [app, edit] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    // Show banners even while the popover is open, and open the popover when one is clicked.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let item = response.notification.request.content.userInfo["item"] as? String
        await handleNotification(action: action, item: item)
    }

    private func handleNotification(action: String, item: String?) {
        if action == "cancel", let item {
            inbox.cancelAutoReply(item)
        } else {
            showPopover()
        }
    }
}
