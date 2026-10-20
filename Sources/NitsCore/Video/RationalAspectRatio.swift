import Foundation

/// Rational Aspect Ratio representing horizontal-to-vertical pixel or display proportions
/// (e.g. Sample Aspect Ratio / Pixel Aspect Ratio 720:959 or 1:1).
public struct RationalAspectRatio: Sendable, Equatable, Hashable, Codable {
    public let numerator: Int
    public let denominator: Int

    public static let square = RationalAspectRatio(numerator: 1, denominator: 1)

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Whether this ratio represents a 1:1 square pixel layout.
    public var isSquare: Bool {
        numerator == denominator || numerator <= 0 || denominator <= 0
    }

    /// The floating-point multiplier (numerator / denominator).
    public var multiplier: Double {
        guard numerator > 0, denominator > 0 else { return 1.0 }
        return Double(numerator) / Double(denominator)
    }

    /// Calculates the effective Display Aspect Ratio (DAR) given coded video width, height, and SAR.
    public static func computeDisplayAspectRatio(width: Int, height: Int, sar: RationalAspectRatio) -> Double {
        guard width > 0, height > 0 else { return 16.0 / 9.0 }
        return (Double(width) * sar.multiplier) / Double(height)
    }
}
