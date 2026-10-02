import SwiftUI

/// Interpolates the dot-matrix readout between measured activity values.
struct MotionVector: VectorArithmetic {
    var values: [Double]
    static let zero = MotionVector(values: [])
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }

    static func + (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs, +) }
    static func - (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs, -) }

    private static func combine(_ lhs: Self, _ rhs: Self,
                                _ operation: (Double, Double) -> Double) -> Self {
        Self(values: (0..<max(lhs.values.count, rhs.values.count)).map {
            operation($0 < lhs.values.count ? lhs.values[$0] : 0,
                      $0 < rhs.values.count ? rhs.values[$0] : 0)
        })
    }
}
