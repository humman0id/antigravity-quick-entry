import Foundation
import CoreGraphics

/// Pure coordinate and scaling helpers shared between `CaptureOverlayController` and unit tests.
public enum CoordinateGeometry {
    /// Converts a global AppKit rectangle (bottom-left origin on primary screen)
    /// to a global Quartz/ScreenCaptureKit rectangle (top-left origin on primary screen).
    public static func appKitToQuartz(rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a global Quartz/ScreenCaptureKit rectangle back to AppKit global coordinates.
    public static func quartzToAppKit(rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Translates a global Quartz selection rect into display-local coordinates for `SCStreamConfiguration.sourceRect`.
    public static func quartzToDisplayLocal(rect: CGRect, displayFrame: CGRect) -> CGRect {
        let clipped = rect.intersection(displayFrame)
        guard !clipped.isNull else { return .zero }
        return CGRect(
            x: clipped.minX - displayFrame.minX,
            y: clipped.minY - displayFrame.minY,
            width: clipped.width,
            height: clipped.height
        )
    }

    /// Computes output pixel dimensions capped at `maxLongEdge` while preserving aspect ratio.
    public static func scaledPixelSize(
        pointSize: CGSize,
        backingScaleFactor: CGFloat,
        maxLongEdge: Int = 2560
    ) -> (width: Int, height: Int) {
        let rawW = max(1.0, pointSize.width * backingScaleFactor)
        let rawH = max(1.0, pointSize.height * backingScaleFactor)
        let longEdge = max(rawW, rawH)
        let limit = CGFloat(max(64, maxLongEdge))

        if longEdge <= limit {
            return (Int(rawW.rounded()), Int(rawH.rounded()))
        }
        let scale = limit / longEdge
        return (
            max(1, Int((rawW * scale).rounded())),
            max(1, Int((rawH * scale).rounded()))
        )
    }
}
