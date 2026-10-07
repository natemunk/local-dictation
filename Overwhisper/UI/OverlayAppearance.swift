import AppKit

enum OverlayAppearance {
    static let defaultStrength = 0.65
    static let strengthRange = 0.35...1.0
    static func strength(_ value: Double) -> Double {
        value.isFinite ? min(strengthRange.upperBound, max(strengthRange.lowerBound, value)) : defaultStrength
    }
    static func size(compact: Bool, controls: Bool) -> NSSize {
        NSSize(width: 390, height: (compact ? 106 : 164) + (controls ? 108 : 0))
    }
}

enum OverlayGeometry {
    static func clamp(_ origin: NSPoint, size: NSSize, to bounds: NSRect) -> NSPoint {
        NSPoint(x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
    }
}
