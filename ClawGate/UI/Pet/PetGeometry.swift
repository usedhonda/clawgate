import Foundation

/// Pure coordinate-geometry helpers for the desktop pet, extracted verbatim
/// from PetModel (TD-11) so the frame-comparison and the NSScreen y-flip math
/// can be unit-tested without AppKit.
///
/// The NSScreen lookup that produces `desktopMaxY` stays in PetModel; only the
/// pure flip is here (parameterized on `desktopMaxY`). `roughlySameFrame` moved
/// verbatim.
enum PetGeometry {
    static func roughlySameFrame(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 20) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < tolerance
            && abs(lhs.origin.y - rhs.origin.y) < tolerance
            && abs(lhs.width - rhs.width) < tolerance
            && abs(lhs.height - rhs.height) < tolerance
    }

    static func appKitRect(forTrackedFrame frame: CGRect, desktopMaxY: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: desktopMaxY - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}
