import SwiftUI

enum Theme: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "Glass"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The solid themes; `nil` keeps the system glass look.
    var palette: Palette? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Paper's design tokens (from app.paper.design's stylesheet) for the solid themes.
struct Palette {
    struct Drop {
        let color: Color
        let radius: CGFloat  // half the CSS blur
        var y: CGFloat = 0
    }

    let scheme: ColorScheme
    let panel: Color
    let separator: Color
    let control: Color
    let controlPressed: Color
    let text: Color
    let toggleTrack: Color
    let toggleSelected: Color
    let strong: Color  // high-contrast primary button
    let strongPressed: Color
    let onStrong: Color
    // --shadow-control: instead of a border, a 1px inner top highlight, a faint inner ring and tight drop shadows.
    let highlight: Color
    let ring: Color
    let drops: [Drop]

    /// Corner radius for controls: round, not continuous (which curves much further along the edge).
    static let radius: CGFloat = 4

    static let light = Palette(
        scheme: .light,
        panel: Color(white: 0.949),  // #f2f2f2
        separator: Color(white: 0.886),  // #e2e2e2
        control: Color(white: 0.976),  // #f9f9f9
        controlPressed: Color(white: 0.988),  // #fcfcfc
        text: .black.opacity(0.8),
        toggleTrack: .black.opacity(0.05),
        toggleSelected: Color(white: 0.976),
        strong: Color(white: 0.118),  // #1e1e1e
        strongPressed: Color(white: 0.2),  // #333
        onStrong: Color(white: 0.976),
        highlight: .white.opacity(0.53),
        ring: .white.opacity(0.53),
        drops: [
            Drop(color: .black.opacity(0.094), radius: 0.5, y: 0.5),  // 0 .5px 1px #00000018
            Drop(color: .black.opacity(0.067), radius: 0.5),  // 0 0 1px #0001
            Drop(color: .black.opacity(0.067), radius: 1.5),  // 0 0 4px -1px #0001
        ]
    )

    static let dark = Palette(
        scheme: .dark,
        panel: Color(white: 0.165),  // #2a2a2a
        separator: Color(white: 0.216),  // #373737
        control: Color(white: 0.216),  // #373737
        controlPressed: Color(white: 0.235),  // #3c3c3c
        text: .white.opacity(0.9),
        toggleTrack: .white.opacity(0.05),
        toggleSelected: .white.opacity(0.05),
        strong: Color(white: 0.949),  // #f2f2f2
        strongPressed: Color(white: 0.831),  // #d4d4d4
        onStrong: Color(white: 0.216),
        highlight: .white.opacity(0.03),
        ring: .white.opacity(0.067),
        drops: [
            Drop(color: .black.opacity(0.094), radius: 0.25, y: 1),  // 0 1px .5px #00000018
            Drop(color: .black.opacity(0.5), radius: 1),  // 0 0 3px -1px #000a
        ]
    )
}

extension EnvironmentValues {
    @Entry var palette: Palette? = nil
}

/// Paper's raised control surface.
struct ControlSurface: View {
    let palette: Palette
    var fill: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Palette.radius)
        let base = AnyShapeStyle((fill ?? palette.control).shadow(.inner(color: palette.highlight, radius: 0, y: 1)))
        let style = palette.drops.reduce(base) { style, drop in
            AnyShapeStyle(style.shadow(.drop(color: drop.color, radius: drop.radius, y: drop.y)))
        }
        shape.fill(style)
            .overlay(shape.strokeBorder(palette.ring, lineWidth: 1))
    }
}

/// A full-width 1px divider in the palette's color.
struct Hairline: View {
    @Environment(\.palette) private var palette

    var body: some View {
        if let palette {
            Rectangle().fill(palette.separator).frame(height: 1)
        } else {
            Divider()
        }
    }
}

/// Paper's `.button` (raised) and `.button-high-contrast` (primary).
struct PaperButtonStyle: ButtonStyle {
    let palette: Palette
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PaperButton(configuration: configuration, palette: palette, prominent: prominent)
    }

    private struct PaperButton: View {
        let configuration: Configuration
        let palette: Palette
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? palette.onStrong : palette.text)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background {
                    if prominent {
                        RoundedRectangle(cornerRadius: Palette.radius)
                            .fill(configuration.isPressed ? palette.strongPressed : palette.strong)
                    } else {
                        ControlSurface(palette: palette, fill: configuration.isPressed ? palette.controlPressed : nil)
                    }
                }
                .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

extension View {
    /// Fields and editors: a Paper control surface in the solid themes, a plain outlined box on glass.
    @ViewBuilder
    func raised(_ palette: Palette?) -> some View {
        if let palette {
            background(ControlSurface(palette: palette))
        } else {
            background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }

    @ViewBuilder
    func themedButton(_ palette: Palette?, prominent: Bool = false) -> some View {
        if let palette {
            buttonStyle(PaperButtonStyle(palette: palette, prominent: prominent))
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.automatic)
        }
    }
}

/// Paper's toggle group, in every theme so it keeps the same width when switching.
struct ThemePicker: View {
    @Binding var selection: Theme
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Theme.allCases, id: \.self) { theme in
                Text(theme.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selection == theme ? AnyShapeStyle(palette?.text ?? .primary) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { if selection == theme { selected } }
                    .padding(1)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = theme }
            }
        }
        .frame(height: 24)
        .background(palette?.toggleTrack ?? Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Palette.radius + 1))
    }

    @ViewBuilder
    private var selected: some View {
        if let palette {
            ControlSurface(palette: palette, fill: palette.toggleSelected)
        } else {
            RoundedRectangle(cornerRadius: Palette.radius)
                .fill(.background)
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
        }
    }
}
