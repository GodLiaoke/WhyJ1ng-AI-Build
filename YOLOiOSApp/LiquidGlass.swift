import SwiftUI
import UIKit

// MARK: - Enterprise Design System (light theme)
// Neutral, high-contrast, generous whitespace. Inspired by Apple's
// productivity apps and modern SaaS dashboards: white surfaces, hairline
// borders, one restrained accent, no decorative gradients behind content.

enum DS {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // NOTE: `SwiftUI.Font` is qualified explicitly because the enclosing enum is
    // itself named `Font`, and an unqualified `Font.system` would resolve to it.
    enum Font {
        static let display = SwiftUI.Font.system(size: 30, weight: .bold)
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 15, weight: .regular)
        static let callout = SwiftUI.Font.system(size: 14, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 12, weight: .regular)
        static let mono = SwiftUI.Font.system(size: 13, weight: .medium, design: .monospaced)
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let standard = Animation.easeInOut(duration: 0.28)
        static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    }
}

// MARK: - Palette

enum Palette {
    // Surfaces
    static let canvas = Color(red: 0.957, green: 0.961, blue: 0.969)   // #F4F5F7
    static let surface = Color.white
    static let surfaceAlt = Color(red: 0.976, green: 0.980, blue: 0.984)
    static let separator = Color(red: 0.878, green: 0.886, blue: 0.898) // #E0E2E5
    static let border = Color(red: 0.839, green: 0.851, blue: 0.867)

    // Text
    static let ink = Color(red: 0.106, green: 0.118, blue: 0.145)       // #1B1E25
    static let inkSecondary = Color(red: 0.365, green: 0.396, blue: 0.447)
    static let inkTertiary = Color(red: 0.573, green: 0.600, blue: 0.647)

    // Accents
    static let accent = Color(red: 0.106, green: 0.365, blue: 0.859)    // #1B5DDB
    static let accentSoft = Color(red: 0.910, green: 0.937, blue: 0.996)
    static let success = Color(red: 0.086, green: 0.639, blue: 0.290)
    static let successSoft = Color(red: 0.914, green: 0.965, blue: 0.933)
    static let warning = Color(red: 0.851, green: 0.522, blue: 0.055)
    static let warningSoft = Color(red: 0.996, green: 0.957, blue: 0.878)
    static let danger = Color(red: 0.796, green: 0.184, blue: 0.176)
    static let dangerSoft = Color(red: 0.996, green: 0.925, blue: 0.925)

    static let shadow = Color.black.opacity(0.06)
    static let shadowStrong = Color.black.opacity(0.10)
}

// MARK: - Liquid Glass support
//
// iOS 26 ships a real Liquid Glass material. Where it is available the app uses
// it instead of the hand-drawn approximations, which is both more accurate and
// cheaper to render. Older systems fall back to a layered approximation built
// from blur plus edge gradients.

extension View {
    /// Applies the system glass effect on iOS 26+, no-op earlier.
    ///
    /// Guarded by compiler version as well as availability: the CI runner may
    /// still be on the iOS 18 SDK, where glassEffect does not exist at all.
    @ViewBuilder
    func wjLiquidGlass(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// True when the real system glass material can be used at runtime.
var systemGlassAvailable: Bool {
    if #available(iOS 26.0, *) { return true }
    return false
}

// MARK: - Floating glass surface
//
// A self-contained glass panel: blurred backdrop, a bright top edge, a dark
// bottom edge, and a hairline border. On iOS 26 the system material replaces
// the whole stack.
//
// The fallback is deliberately layered rather than a single blur: `.ultraThinMaterial`
// on its own reads as flat grey, and the two gradients are what make it look like
// a lit pane of glass.

struct FloatingGlassModifier: ViewModifier {
    var cornerRadius: CGFloat
    /// Tint laid over the blur, for accented surfaces.
    var tint: Color = .clear
    /// Stronger blur and shadow, for panels that cover content.
    var elevated: Bool = true

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(elevated ? 0.16 : 0.08),
                        radius: elevated ? 20 : 10, y: elevated ? 10 : 5)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    if tint != .clear { Rectangle().fill(tint) }
                    // Bright at the top-left, fading out: reads as reflected light.
                    LinearGradient(
                        colors: [Color.white.opacity(0.55),
                                 Color.white.opacity(0.10),
                                 Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    // Slight darkening at the bottom so the pane has body.
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.70),
                                     Color.white.opacity(0.18),
                                     Color.white.opacity(0.32)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
            }
            .shadow(color: .black.opacity(elevated ? 0.16 : 0.08),
                    radius: elevated ? 20 : 10,
                    x: 0,
                    y: elevated ? 10 : 5)
    }
}

extension View {
    /// Wraps the receiver in a floating glass panel.
    func floatingGlass(cornerRadius: CGFloat,
                       tint: Color = .clear,
                       elevated: Bool = true) -> some View {
        modifier(FloatingGlassModifier(cornerRadius: cornerRadius,
                                       tint: tint,
                                       elevated: elevated))
    }
}

// MARK: - Surfaces

/// Flat white card with a hairline border and a whisper of elevation.
/// On iOS 26 the body is replaced by the system Liquid Glass material.
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = DS.Space.l
    var radius: CGFloat = DS.Radius.l
    var elevated: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            legacyCard
        }
        #else
        legacyCard
        #endif
    }

    /// The hand-drawn fallback used below iOS 26.
    private var legacyCard: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Palette.separator, lineWidth: 1)
            )
            .shadow(color: elevated ? Palette.shadowStrong : Palette.shadow,
                    radius: elevated ? 16 : 8,
                    x: 0,
                    y: elevated ? 6 : 3)
    }
}

/// Section header with an optional trailing control.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.inkTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.caption)
                    // Order matters. `Text.letterSpacing` (kerning, iOS 13) has
                    // to be applied while the receiver is still a `Text`; after
                    // `.textCase` it is a plain `View` and the only modifier
                    // available is the iOS 16 one, which silently does nothing
                    // on iOS 15.
                    .letterSpacing(0.6)
                    .fontWeight(.semibold)
                    .foregroundColor(Palette.inkTertiary)
                    .textCase(.uppercase)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var loading: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: { if enabled && !loading { action() } }) {
            HStack(spacing: DS.Space.s) {
                if loading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.85)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(DS.Font.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(enabled ? Palette.accent : Palette.inkTertiary.opacity(0.45))
            )
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(DS.Motion.quick, value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
        .disabled(!enabled || loading)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var loading: Bool = false
    var tint: Color = Palette.ink
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var pressed = false

    private var borderColor: Color {
        role == .destructive ? Palette.danger.opacity(0.35) : Palette.border
    }
    private var labelColor: Color {
        role == .destructive ? Palette.danger : tint
    }

    var body: some View {
        Button(action: { if !loading { action() } }) {
            HStack(spacing: DS.Space.s) {
                if loading {
                    ProgressView().scaleEffect(0.8)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(DS.Font.headline)
            }
            .foregroundColor(labelColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(pressed ? Palette.surfaceAlt : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .animation(DS.Motion.quick, value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
        .disabled(loading)
    }
}

/// Full-width list row that opens something, with a chevron.
struct ActionRow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String
    var iconTint: Color = Palette.accent
    var iconBackground: Color = Palette.accentSoft
    var badge: String? = nil
    var showsChevron: Bool = true
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(iconBackground)
                        .frame(width: 34, height: 34)
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(iconTint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Font.body)
                        .fontWeight(.medium)
                        .foregroundColor(Palette.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let badge {
                    Text(badge)
                        .font(DS.Font.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(Palette.inkSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.surfaceAlt))
                        .overlay(Capsule().stroke(Palette.separator, lineWidth: 1))
                }

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.inkTertiary.opacity(0.7))
                }
            }
            .padding(.vertical, DS.Space.s)
            .padding(.horizontal, DS.Space.m)
            .background(pressed ? Palette.surfaceAlt : Color.clear)
            .contentShape(Rectangle())
            .animation(DS.Motion.quick, value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
    }
}

// MARK: - Status chip

struct StatusChip: View {
    enum Level { case ready, idle, error, busy }
    let level: Level
    let text: String

    private var tint: Color {
        switch level {
        case .ready: return Palette.success
        case .idle: return Palette.warning
        case .error: return Palette.danger
        case .busy: return Palette.accent
        }
    }
    private var background: Color {
        switch level {
        case .ready: return Palette.successSoft
        case .idle: return Palette.warningSoft
        case .error: return Palette.dangerSoft
        case .busy: return Palette.accentSoft
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(DS.Font.caption)
                .fontWeight(.semibold)
                .foregroundColor(tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(background))
    }
}

// MARK: - Key/value row

struct InfoRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Text(label)
                .font(DS.Font.callout)
                .foregroundColor(Palette.inkTertiary)
            Spacer(minLength: DS.Space.s)
            Text(value)
                .font(mono ? DS.Font.mono : DS.Font.callout)
                .foregroundColor(Palette.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: 1)
    }
}

// MARK: - Text field

struct TextInputField: View {
    var label: String? = nil
    var placeholder: String
    @Binding var text: String
    var systemImage: String? = nil
    var isSecure: Bool = false
    var error: String? = nil
    var keyboard: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil

    @FocusState private var focused: Bool

    private var borderColor: Color {
        if error != nil { return Palette.danger }
        return focused ? Palette.accent : Palette.border
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let label {
                Text(label)
                    .font(DS.Font.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(Palette.inkSecondary)
            }

            HStack(spacing: DS.Space.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(error != nil ? Palette.danger : Palette.inkTertiary)
                        .frame(width: 20)
                }

                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(DS.Font.body)
                            .foregroundColor(Palette.inkTertiary)
                    }
                    Group {
                        if isSecure {
                            SecureField("", text: $text)
                        } else {
                            TextField("", text: $text)
                        }
                    }
                    .font(DS.Font.body)
                    .foregroundColor(Palette.ink)
                    .tint(Palette.accent)
                    .keyboardType(keyboard)
                    .textContentType(textContentType)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .stroke(borderColor, lineWidth: focused || error != nil ? 1.6 : 1)
            )
            .animation(DS.Motion.quick, value: focused)

            if let error {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(error).font(DS.Font.caption)
                }
                .foregroundColor(Palette.danger)
            }
        }
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.m) {
            ZStack {
                Circle().fill(Palette.surfaceAlt).frame(width: 56, height: 56)
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(Palette.inkTertiary)
            }
            VStack(spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Font.headline)
                    .foregroundColor(Palette.ink)
                Text(message)
                    .font(DS.Font.callout)
                    .foregroundColor(Palette.inkTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(DS.Font.callout)
                    .foregroundColor(Palette.accent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xl)
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(DS.Font.callout)
                .fontWeight(.medium)
        }
        .foregroundColor(.white)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(isError ? Palette.danger : Palette.ink)
        )
        .shadow(color: Palette.shadowStrong, radius: 18, y: 8)
    }
}

// MARK: - Slider row

struct SliderRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var valueText: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(DS.Font.body)
                    .fontWeight(.medium)
                    .foregroundColor(Palette.ink)
                Spacer(minLength: DS.Space.s)
                Text(valueText)
                    .font(DS.Font.mono)
                    .foregroundColor(Palette.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.accentSoft)
                    )
            }
            if let subtitle {
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundColor(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Palette.accent)
        }
    }
}

// MARK: - Chips

struct Chip: View {
    let text: String
    var selected: Bool = false
    var tint: Color = Palette.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(DS.Font.caption)
                .fontWeight(.semibold)
                .foregroundColor(selected ? .white : Palette.inkSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(selected ? tint : Palette.surfaceAlt)
                )
                .overlay(
                    Capsule()
                        .stroke(selected ? Color.clear : Palette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toggle row

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(DS.Font.body)
                    .fontWeight(.medium)
                    .foregroundColor(Palette.ink)
            }
            .tint(Palette.accent)

            if let subtitle {
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundColor(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Back-deployment helpers
//
// The app ships from iOS 15. A few SwiftUI conveniences arrived later than that,
// so each one gets an explicit fallback here rather than being deleted: newer
// systems keep the nicer API, iOS 15 keeps the behaviour.

extension View {
    /// `onChange` that reports the old and the new value on every supported OS.
    ///
    /// The two-parameter closure form is iOS 17; the one-parameter form exists
    /// from iOS 14 and is deprecated on 17. Picking per system keeps the
    /// deprecation confined to the fallback branch instead of every call site.
    /// On iOS 15-16 there is no old value to hand out, so both arguments are the
    /// new one - every call site in the app only reads the new value.
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V,
                                      _ action: @escaping (V, V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { old, new in action(old, new) }
        } else {
            self.onChange(of: value) { new in action(new, new) }
        }
    }
}

// MARK: - Multiline text input

/// A multiline field for iOS 15, which has neither `TextField(axis:)` nor a
/// `TextEditor` whose background can be hidden without mutating global UIKit
/// appearance.
///
/// A bare `UITextView` with zero insets is the only variant whose background
/// follows the enclosing card instead of painting an opaque system background
/// over it, so the same call renders identically on 15 and on 16+.
struct PlainTextEditor: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont = .systemFont(ofSize: 15)
    var textColor: UIColor = .label

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = font
        view.textColor = textColor
        view.text = text
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Assigning `text` unconditionally collapses the caret to the end while
        // the user is typing, so only sync when the binding really moved.
        if view.text != text { view.text = text }
        view.font = font
        view.textColor = textColor
    }

    func makeCoordinator() -> Coordinator { Coordinator($text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        init(_ text: Binding<String>) { self.text = text }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
        }
    }
}


// MARK: - Letter spacing
//
// Two different symbols, with two different floors. Getting this wrong is a
// launch crash on iOS 15, not a cosmetic regression, so the distinction is
// spelled out here rather than guessed at each call site:
//
//   * `Text.kerning(_:)`  -> iOS 13. Returns a `Text`, usable anywhere a `Text`
//     is, and works on 15. This is the one every call site wants.
//   * `View.kerning(_:)`  -> iOS 16. The environment-propagating variant; the
//     same spelling, a completely different symbol.
//
// `View.tracking(_:)` and `View.kerning(_:)` are BOTH iOS 16, which is what made
// an earlier revision of this file wrong: it dispatched from a `View` extension
// to `self.kerning(value)`, and on iOS 15 that resolves to a symbol the OS does
// not have. A missing SwiftUI symbol is not a soft failure - dyld fails the
// image and the app dies before `main()`.
//
// So the helper below does not call a View-level modifier on the old path at
// all. It applies kerning to the text it is given, before the view is built.

/// Letter spacing for a single `Text`, on every supported system.
///
/// This is the form to use: it returns a `Text`, so it composes with the rest of
/// the text pipeline and needs no availability branch at the call site.
extension Text {
    func letterSpacing(_ value: CGFloat) -> Text {
        // iOS 13 on every supported system: no `#available` needed, and no
        // `View.kerning` anywhere near the old path.
        self.kerning(value)
    }
}

/// Letter spacing for an arbitrary view.
///
/// Views cannot be inspected, so the only way to re-space the `Text` inside one
/// is the environment modifier - which is iOS 16. Below 16 this is a no-op:
/// losing 0.6pt of letter spacing on three uppercase labels is invisible, and it
/// is certainly preferable to dyld refusing to load the app.
extension View {
    @ViewBuilder
    func letterSpacing(_ value: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.kerning(value)
        } else {
            self
        }
    }
}
