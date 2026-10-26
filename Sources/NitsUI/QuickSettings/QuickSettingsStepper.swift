import SwiftUI

struct QuickSettingsStepper<F: ParseableFormatStyle>: View where F.FormatOutput == String {
    let title: String
    @Binding var value: F.FormatInput
    let format: F
    let unit: String
    var canDecrement: Bool = true
    var canIncrement: Bool = true
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    init(
        _ title: String,
        value: Binding<F.FormatInput>,
        format: F,
        unit: String,
        canDecrement: Bool = true,
        canIncrement: Bool = true,
        onDecrement: @escaping () -> Void,
        onIncrement: @escaping () -> Void
    ) {
        self.title = title
        self._value = value
        self.format = format
        self.unit = unit
        self.canDecrement = canDecrement
        self.canIncrement = canIncrement
        self.onDecrement = onDecrement
        self.onIncrement = onIncrement
    }

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            stepButton("Decrease", systemImage: "minus", isEnabled: canDecrement, action: onDecrement)

            HStack(spacing: 3) {
                TextField(title, value: $value, format: format)
                    .labelsHidden()
                    .focused($isFieldFocused)
                    // Hand the keyboard back to the player: its unmodified shortcuts
                    // don't work while a text field has focus.
                    .onSubmit { isFieldFocused = false }
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 56)

                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .quickSettingsFieldBackground()
            .fixedSize()

            stepButton("Increase", systemImage: "plus", isEnabled: canIncrement, action: onIncrement)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment where canIncrement: onIncrement()
            case .decrement where canDecrement: onDecrement()
            default: break
            }
        }
    }

    private func stepButton(
        _ label: String, systemImage: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        RepeatingStepButton(label: label, systemImage: systemImage, isEnabled: isEnabled, action: action)
    }
}

/// A step button that fires on press and, while held, repeats after a short delay.
private struct RepeatingStepButton: View {
    let label: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    private static let initialDelay: Duration = .milliseconds(400)
    private static let repeatInterval: Duration = .milliseconds(90)

    private static let size: CGFloat = 24

    @State private var repeatTask: Task<Void, Never>?
    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: Self.size, height: Self.size)
            .background(Circle().fill(Color.white.opacity(isEnabled ? (isPressed ? 0.22 : 0.1) : 0.04)))
            .foregroundStyle(.white.opacity(isEnabled ? 0.9 : 0.3))
            .contentShape(Circle())
            .allowsHitTesting(isEnabled)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        // Like a button: dragging off cancels, dragging back re-arms.
                        let center = Self.size / 2
                        let dx = drag.location.x - center
                        let dy = drag.location.y - center
                        if dx * dx + dy * dy <= center * center {
                            startRepeating()
                        } else {
                            stopRepeating()
                        }
                    }
                    .onEnded { _ in stopRepeating() }
            )
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { stopRepeating() }
            }
            .onDisappear { stopRepeating() }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if isEnabled { action() } }
    }

    private func startRepeating() {
        guard repeatTask == nil, isEnabled else { return }
        isPressed = true
        action()
        repeatTask = Task {
            try? await Task.sleep(for: Self.initialDelay)
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
        isPressed = false
    }
}
