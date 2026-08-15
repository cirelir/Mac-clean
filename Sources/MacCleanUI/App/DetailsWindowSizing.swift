import CoreGraphics
import Foundation

/// Pure sizing rules for the details window.
///
/// The AppKit controller measures the hosted SwiftUI content and asks this
/// helper to clamp the result, so an auto-sized window never drops below its
/// minimum size or extends past the visible screen frame. Keeping the math
/// here (instead of inside the controller) makes it unit-testable.
public enum DetailsWindowSizing {
    public static func fittedContentSize(
        fitting fittingSize: CGSize,
        minSize: CGSize,
        visibleFrame: CGRect
    ) -> CGSize {
        CGSize(
            width: min(max(fittingSize.width, minSize.width), visibleFrame.width),
            height: min(max(fittingSize.height, minSize.height), visibleFrame.height)
        )
    }
}
