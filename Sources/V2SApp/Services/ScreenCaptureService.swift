import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCaptureService {
    enum CaptureResult: Equatable {
        case captured(Data)
        case permissionNeeded
        case failed
    }

    static func captureCurrentDisplayPNG() async -> Data? {
        if case .captured(let data) = await captureCurrentDisplayPNGResult() {
            return data
        }
        return nil
    }

    static func captureCurrentDisplayPNGResult() async -> CaptureResult {
        // If not yet authorized, request permission (shows the system dialog on first call,
        // or opens System Settings > Screen Recording if previously denied).
        guard CGPreflightScreenCaptureAccess() else {
            guard CGRequestScreenCaptureAccess() else {
                return .permissionNeeded
            }
            return .failed
        }

        let displayID = displayIDForMouseLocation() ?? CGMainDisplayID()

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else {
            return .failed
        }

        let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        guard let display else {
            return .failed
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = true

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else {
            return .failed
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return .failed
        }
        return .captured(data)
    }

    private static func displayIDForMouseLocation() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: mouse.y)
        var matchingDisplays = [CGDirectDisplayID](repeating: 0, count: 8)
        var displayCount: UInt32 = 0

        let error = CGGetDisplaysWithPoint(
            point,
            UInt32(matchingDisplays.count),
            &matchingDisplays,
            &displayCount
        )

        guard error == .success, displayCount > 0 else {
            return nil
        }

        return matchingDisplays[0]
    }
}
