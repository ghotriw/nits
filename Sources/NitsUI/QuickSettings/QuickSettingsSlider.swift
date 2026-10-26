import SwiftUI

struct QuickSettingsSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    @Binding var value: Value
    let bounds: ClosedRange<Value>
    let step: Value?

    init(
        value: Binding<Value>,
        in bounds: ClosedRange<Value>,
        step: Value? = nil
    ) {
        self._value = value
        self.bounds = bounds
        self.step = step
    }

    private var normalizedValue: CGFloat {
        let span = Double(bounds.upperBound - bounds.lowerBound)
        guard span > 0, value.isFinite else { return 0 }
        let clamped = min(max(Double(value), Double(bounds.lowerBound)), Double(bounds.upperBound))
        return CGFloat((clamped - Double(bounds.lowerBound)) / span)
    }

    var body: some View {
        GeometryReader { geometry in
            let thumbSize: CGFloat = 14
            let trackHeight: CGFloat = 5
            let usableWidth = max(geometry.size.width - thumbSize, 1)
            let thumbOffset = normalizedValue * usableWidth

            ZStack(alignment: .leading) {
                // Unfilled track
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .frame(height: trackHeight)

                // Filled track
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: thumbOffset + thumbSize / 2, height: trackHeight)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .offset(x: thumbOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = min(max((gesture.location.x - thumbSize / 2) / usableWidth, 0), 1)
                        let span = Double(bounds.upperBound - bounds.lowerBound)
                        let lower = Double(bounds.lowerBound)
                        var raw = lower + Double(fraction) * span
                        if let step, step > 0 {
                            let s = Double(step)
                            raw = lower + ((raw - lower) / s).rounded() * s
                        }
                        let clamped = min(max(raw, lower), Double(bounds.upperBound))
                        value = Value(clamped)
                    }
            )
        }
        .frame(height: 18)
        .accessibilityRepresentation {
            if let step, step > 0 {
                Slider(value: $value, in: bounds, step: Value.Stride(step))
            } else {
                Slider(value: $value, in: bounds)
            }
        }
    }
}
