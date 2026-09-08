import AppKit

struct WindowInfo: Equatable {
    let id: CGWindowID
    /// Cocoa screen coordinates.
    let frame: CGRect
    let title: String
    let ownerName: String
    let ownerPID: pid_t

    var displayName: String {
        title.isEmpty ? ownerName : "\(ownerName) — \(title)"
    }
}

enum WindowEnumerator {
    /// On-screen, normal-layer windows, front-most first. Our own windows are excluded.
    static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier

        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != myPID,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 1, bounds.height > 1 else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01 else { return nil }
            return WindowInfo(
                id: number,
                frame: CGRect.cocoaRect(fromCG: bounds),
                title: info[kCGWindowName as String] as? String ?? "",
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                ownerPID: pid
            )
        }
    }
}
