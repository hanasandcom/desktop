import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum WindowFrameRestorationLayout {
    private static let minimumVisibleWidth: CGFloat = 80
    private static let minimumVisibleHeight: CGFloat = 44

    static func restoredFrame(
        for savedFrame: CGRect,
        on screens: [CGRect],
        fallbackScreen: CGRect?
    ) -> CGRect? {
        guard savedFrame.width > 0, savedFrame.height > 0,
              savedFrame.origin.x.isFinite, savedFrame.origin.y.isFinite,
              savedFrame.width.isFinite, savedFrame.height.isFinite else {
            return nil
        }

        let screen = screens
            .filter { !$0.isEmpty }
            .max { intersectionArea(of: savedFrame, and: $0) < intersectionArea(of: savedFrame, and: $1) }
            .flatMap { intersectionArea(of: savedFrame, and: $0) > 0 ? $0 : nil }
            ?? fallbackScreen.flatMap { $0.isEmpty ? nil : $0 }

        guard let screen else { return nil }

        let visibleWidth = min(minimumVisibleWidth, screen.width)
        let visibleHeight = min(minimumVisibleHeight, screen.height)
        let minimumX = savedFrame.width <= screen.width
            ? screen.minX
            : screen.minX - savedFrame.width + visibleWidth
        let maximumX = savedFrame.width <= screen.width
            ? screen.maxX - savedFrame.width
            : screen.maxX - visibleWidth
        let minimumY = savedFrame.height <= screen.height
            ? screen.minY
            : screen.minY + visibleHeight - savedFrame.height
        let maximumY = screen.maxY - savedFrame.height

        var restoredFrame = savedFrame
        restoredFrame.origin.x = min(max(savedFrame.minX, minimumX), maximumX)
        restoredFrame.origin.y = min(max(savedFrame.minY, minimumY), maximumY)
        return restoredFrame
    }

    private static func intersectionArea(of lhs: CGRect, and rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

struct WindowFrameRestorer: NSViewRepresentable {
    let storageKey: String

    func makeCoordinator() -> Coordinator {
        Coordinator(storageKey: storageKey)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator {
        let storageKey: String
        weak var window: NSWindow?
        var observers: [NSObjectProtocol] = []

        init(storageKey: String) {
            self.storageKey = storageKey
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            self.window = window

            if let saved = UserDefaults.standard.string(forKey: storageKey) {
                let frame = NSRectFromString(saved)
                let screenFrames = NSScreen.screens.map(\.visibleFrame)
                if let restoredFrame = WindowFrameRestorationLayout.restoredFrame(
                    for: frame,
                    on: screenFrames,
                    fallbackScreen: window.screen?.visibleFrame
                ) {
                    window.setFrame(restoredFrame, display: true)
                }
            }

            let save: (Notification) -> Void = { [weak self, weak window] _ in
                guard let self, let window else { return }
                UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: self.storageKey)
            }

            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main,
                using: save
            ))
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main,
                using: save
            ))
        }
    }
}
