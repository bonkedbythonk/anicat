#if os(macOS)
import AppKit
import SwiftUI
import AnicatUI

/// The status bar item and its popover, kept off SwiftUI's `MenuBarExtra`.
///
/// `MenuBarExtra(.window)` calls `NSApp.activate` before it shows its panel.
/// After Cmd-H that activation unhides every window the app has, so the
/// icon brought the whole app back instead of showing the menu (owner,
/// 2026-09-21; the log showed no reopen event, only an active app with its
/// main window visible). An `NSPopover` anchored to the item's button needs
/// no activation and shows while the app stays hidden [measured: "app
/// hidden true, popover window visible true"]. Unhiding without activation
/// and ordering the main window out first was tried before that: the
/// window then came back "from scratch" instead of unhiding.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// Clicks outside a transient popover only close it while the app is
    /// active; this app deliberately is not, so the close is done by hand.
    private var outsideClickMonitor: Any?

    func install(model: AppModel) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = BrandAssets.menuBarNSImage {
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Anicat")
            }
            button.target = self
            button.action = #selector(toggle(_:))
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ThemedRoot { MenuBarPopoverContent(model: model) }
        )
        self.popover = popover
        // "Open Anicat" and "Resume" activate the app; a transient popover
        // left open over the window it just raised is a second thing to
        // dismiss.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover?.performClose(nil) }
        }
    }

    @objc private func toggle(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // The popover's own window has to be key for its buttons to take
        // the first click; making it key does not activate the app.
        popover.contentViewController?.view.window?.makeKey()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover?.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
#endif
