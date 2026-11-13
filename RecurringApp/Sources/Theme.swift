import AppKit
import CoreText
import SwiftUI

/// Sentinel "Observatory" design system for Recurring v3.
/// Single source of truth across MenuBarView, DashboardView, InsightViews, VaultView, and SyncCenterView:
///   - Machined graphite surfaces (#0A0B0D canvas, #141619 card, #191C20 elevated, #21252B well, #2C3138 1px border)
///   - Signal-amber (#FFB020) primary accent, mint (#3DD4A7) live/healthy/savings, coral (#FF5C6C) critical/leaked
///   - Space Grotesk display & UI + JetBrains Mono tabular readouts
enum DS {
    // MARK: Surfaces & Hairlines
    static let canvas = Color(hex: 0x0A0B0D)
    static let surface = Color(hex: 0x141619)
    static let elevated = Color(hex: 0x191C20)
    static let well = Color(hex: 0x21252B)
    static let border = Color(hex: 0x2C3138)
    static let borderSubtle = Color(hex: 0x1F2329)
    static let rowHover = Color(hex: 0x1C2026)

    // MARK: Ink Hierarchy
    static let ink = Color(hex: 0xF4F6F8)
    static let ink2 = Color(hex: 0xA8B0BC)
    static let ink3 = Color(hex: 0x6B7380)

    // MARK: Observatory Signals
    static let amber = Color(hex: 0xFFB020)
    static let mint = Color(hex: 0x3DD4A7)
    static let coral = Color(hex: 0xFF5C6C)
    static let cyan = Color(hex: 0x4EA8FF)
    static let violet = Color(hex: 0x9B8AFB)

    // MARK: Radii
    static let radiusCard: CGFloat = 10
    static let radiusWell: CGFloat = 7
    static let radiusPill: CGFloat = 5

    // MARK: Categories (high-contrast on #0A0B0D)
    static let categoryOrder = [
        "AI & LLM",
        "Infra & dev tools",
        "Proxy & automation",
        "Consumer & personal",
        "Professional",
        "Unidentified",
    ]

    private static let categoryColors: [String: Color] = [
        "AI & LLM": Color(hex: 0x4EA8FF),
        "Infra & dev tools": Color(hex: 0xFFB020),
        "Consumer & personal": Color(hex: 0xF27D52),
        "Proxy & automation": Color(hex: 0x3DD4A7),
        "Professional": Color(hex: 0x9B8AFB),
    ]

    static func categoryColor(_ category: String) -> Color {
        categoryColors[category] ?? ink3
    }

    static func orderedCategories(_ categories: [String]) -> [String] {
        let known = categoryOrder.filter(categories.contains)
        return known + categories.filter { !categoryOrder.contains($0) }.sorted()
    }

    // MARK: Bundled Font Registration & Memoized Font Cache
    enum Weight: Int, Hashable {
        case light, regular, medium, semibold, bold
    }

    private struct FontKey: Hashable {
        let isMono: Bool
        let sizeBits: Int   // Int((size * 10).rounded())
        let weight: Weight
    }

    private static let fontLock = NSLock()
    nonisolated(unsafe) private static var didRegisterFonts = false
    nonisolated(unsafe) private static var hasSpaceGrotesk = false
    nonisolated(unsafe) private static var hasJetBrainsMono = false
    nonisolated(unsafe) private static var fontCache: [FontKey: Font] = [:]

    static func registerFontsOnce() {
        fontLock.lock()
        if didRegisterFonts {
            fontLock.unlock()
            return
        }
        didRegisterFonts = true
        fontLock.unlock()

        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("Fonts"))
            dirs.append(res)
        }
        let cwdFonts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("RecurringApp/Fonts")
        dirs.append(cwdFonts)

        let fm = FileManager.default
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension.lowercased() == "ttf" {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        let sg = NSFont(name: "SpaceGrotesk-Medium", size: 12) != nil
        let jbm = NSFont(name: "JetBrainsMono-Regular", size: 12) != nil
        fontLock.lock()
        hasSpaceGrotesk = sg
        hasJetBrainsMono = jbm
        fontLock.unlock()
    }

    static func display(_ size: CGFloat, weight: Weight = .medium) -> Font {
        registerFontsOnce()
        let key = FontKey(isMono: false, sizeBits: Int((size * 10).rounded()), weight: weight)
        fontLock.lock()
        if let hit = fontCache[key] {
            fontLock.unlock()
            return hit
        }
        let bundled = hasSpaceGrotesk
        fontLock.unlock()

        let built: Font
        if bundled {
            let name: String = switch weight {
            case .light: "SpaceGrotesk-Light"
            case .regular: "SpaceGrotesk-Regular"
            case .medium: "SpaceGrotesk-Medium"
            case .semibold: "SpaceGrotesk-SemiBold"
            case .bold: "SpaceGrotesk-Bold"
            }
            built = Font.custom(name, size: size).monospacedDigit()
        } else {
            let sysWeight: Font.Weight = switch weight {
            case .light: .light
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
            built = .system(size: size, weight: sysWeight).monospacedDigit()
        }

        fontLock.lock()
        fontCache[key] = built
        fontLock.unlock()
        return built
    }

    static func mono(_ size: CGFloat, weight: Weight = .regular) -> Font {
        registerFontsOnce()
        let key = FontKey(isMono: true, sizeBits: Int((size * 10).rounded()), weight: weight)
        fontLock.lock()
        if let hit = fontCache[key] {
            fontLock.unlock()
            return hit
        }
        let bundled = hasJetBrainsMono
        fontLock.unlock()

        let built: Font
        if bundled {
            let name: String = switch weight {
            case .light, .regular: "JetBrainsMono-Regular"
            case .medium: "JetBrainsMono-Medium"
            case .semibold: "JetBrainsMono-SemiBold"
            case .bold: "JetBrainsMono-Bold"
            }
            built = Font.custom(name, size: size).monospacedDigit()
        } else {
            let sysWeight: Font.Weight = switch weight {
            case .light, .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
            built = .system(size: size, weight: sysWeight, design: .monospaced).monospacedDigit()
        }

        fontLock.lock()
        fontCache[key] = built
        fontLock.unlock()
        return built
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

// MARK: - Shared Observatory Primitives

struct DSEyebrow: View {
    let text: String
    var color: Color = DS.ink3

    var body: some View {
        Text(text.uppercased())
            .font(DS.mono(9.5, weight: .semibold))
            .tracking(1.0)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct DSLiveDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.26))
                .frame(width: size + 5, height: size + 5)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }
}

struct DSStatusPill: View {
    let text: String
    let tint: Color
    var filled: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(DS.mono(9.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(filled ? DS.canvas : tint)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusPill)
                    .fill(filled ? tint : tint.opacity(0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusPill)
                    .strokeBorder(filled ? Color.clear : tint.opacity(0.32), lineWidth: 1)
            )
            .fixedSize()
    }
}

/// Canonical Helix ecosystem API-key tier badge ("Admin key" / "Org key").
struct DSKeyTierBadge: View {
    let tier: String  // "admin" | "org"

    private var isAdmin: Bool { tier.lowercased() == "admin" }

    var body: some View {
        let tint = isAdmin ? DS.amber : DS.cyan
        let label = isAdmin ? "Admin key" : "Org key"
        HStack(spacing: 4) {
            Image(systemName: isAdmin ? "crown.fill" : "key.fill")
                .font(.system(size: 8.5, weight: .bold))
            Text(label)
                .font(DS.mono(10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(RoundedRectangle(cornerRadius: DS.radiusPill).fill(tint.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusPill).strokeBorder(tint.opacity(0.32), lineWidth: 1))
        .fixedSize()
    }
}

struct DSProviderGlyph: View {
    let provider: String
    var size: CGFloat = 15

    private static let assetLock = NSLock()
    nonisolated(unsafe) private static var assetAvailability: [String: Bool] = [:]

    private static func hasAsset(_ name: String) -> Bool {
        assetLock.lock()
        if let cached = assetAvailability[name] {
            assetLock.unlock()
            return cached
        }
        assetLock.unlock()
        let exists = NSImage(named: name) != nil
        assetLock.lock()
        assetAvailability[name] = exists
        assetLock.unlock()
        return exists
    }

    private var assetName: String {
        let slug = provider.lowercased()
        switch slug {
        case "anthropic": return "provider-anthropic"
        case "openai": return "provider-openai"
        case "google": return "provider-google"
        case "openrouter": return "provider-openrouter"
        case "xai": return "provider-xai"
        case "groq": return "provider-groq"
        case "github": return "provider-github"
        case "stripe": return "provider-stripe"
        case "vercel": return "provider-vercel"
        case "cloudflare": return "provider-cloudflare"
        case "supabase": return "provider-supabase"
        case "flyio": return "provider-flyio"
        case "huggingface": return "provider-huggingface"
        case "perplexity": return "provider-perplexity"
        case "resend": return "provider-resend"
        default: return "provider-\(slug)"
        }
    }

    var body: some View {
        let name = assetName
        if Self.hasAsset(name) {
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(DS.ink)
        } else {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: size * 0.78, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(DS.ink2)
        }
    }
}

struct DSPanel<Content: View, Trailing: View>: View {
    var eyebrow: String? = nil
    let title: String
    var subtitle: String? = nil
    var accentBar: Color? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String? = nil,
        accentBar: Color? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.accentBar = accentBar
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let eyebrow {
                        DSEyebrow(text: eyebrow, color: accentBar ?? DS.ink3)
                    }
                    Text(title)
                        .font(DS.display(14.5, weight: .semibold))
                        .foregroundStyle(DS.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.display(11.5, weight: .regular))
                            .foregroundStyle(DS.ink3)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.radiusCard).fill(DS.surface))
        .overlay(alignment: .top) {
            if let accentBar {
                UnevenRoundedRectangle(
                    topLeadingRadius: DS.radiusCard,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: DS.radiusCard
                )
                .fill(accentBar.opacity(0.85))
                .frame(height: 2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .strokeBorder(DS.border, lineWidth: 1)
        )
    }
}

struct DSChipButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = DS.ink2
    var prominent: Bool = false
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(title)
                    .font(DS.display(11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(
                disabled ? DS.ink3 : (prominent ? DS.canvas : (hovering ? DS.ink : tint))
            )
            .background(
                RoundedRectangle(cornerRadius: DS.radiusWell)
                    .fill(disabled ? DS.well : (prominent ? DS.amber : (hovering ? DS.elevated : DS.well)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusWell)
                    .strokeBorder(disabled ? DS.border : (prominent ? DS.amber : DS.border), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusWell))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

private struct SnapshotRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshotRender: Bool {
        get { self[SnapshotRenderKey.self] }
        set { self[SnapshotRenderKey.self] = newValue }
    }
}

struct DSFilterChip: View {
    let title: String
    let selected: Bool
    var count: Int? = nil
    var dot: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(dot).frame(width: 6.5, height: 6.5)
                }
                Text(title)
                    .font(DS.display(11.5, weight: selected ? .semibold : .medium))
                if let count {
                    Text("\(count)")
                        .font(DS.mono(10, weight: .semibold))
                        .foregroundStyle(selected ? DS.canvas.opacity(0.75) : DS.ink3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? DS.canvas : (hovering ? DS.ink : DS.ink2))
            .background(
                RoundedRectangle(cornerRadius: DS.radiusPill)
                    .fill(selected ? DS.amber : (hovering ? DS.elevated : DS.well))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusPill)
                    .strokeBorder(selected ? DS.amber : DS.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusPill))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

// MARK: - Date & Service Presentation Helpers

enum DayText {
    private static let fmtLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    nonisolated(unsafe) private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func short(_ d: Date) -> String { format("MMM d", d) }
    static func withYear(_ d: Date) -> String { format("MMM d, yyyy", d) }
    static func month(_ d: Date) -> String { format("MMM yyyy", d) }
    static func relative(_ d: Date, from today: Date) -> String {
        switch Schedule.daysUntil(d, from: today) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2..<7: return format("EEE d", d)
        default:
            let sameYear = Schedule.calendar.component(.year, from: d) == Schedule.calendar.component(.year, from: today)
            return sameYear ? short(d) : format("MMM d ’yy", d)
        }
    }
    static func weekdayDate(_ d: Date) -> String { format("EEE MMM d", d) }
    static func cancelBy(_ d: Date, from today: Date) -> String {
        switch Schedule.daysUntil(d, from: today) {
        case ..<1: return "cancel today"
        case 1: return "cancel by tomorrow"
        default: return "cancel by \(weekdayDate(d))"
        }
    }

    static func parseISO(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        fmtLock.lock()
        defer { fmtLock.unlock() }
        return isoFractional.date(from: iso) ?? isoBasic.date(from: iso)
    }

    static func relativeISO(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "never" }
        if let dt = parseISO(iso) {
            let secs = Int(Date().timeIntervalSince(dt))
            if secs < 60 { return "just now" }
            if secs < 3600 { return "\(secs / 60)m ago" }
            if secs < 86400 { return "\(secs / 3600)h ago" }
            return short(dt)
        }
        if let d = Schedule.parseDay(iso) { return short(d) }
        return iso
    }

    private static func format(_ pattern: String, _ d: Date) -> String {
        fmtLock.lock()
        defer { fmtLock.unlock() }
        if let f = cache[pattern] { return f.string(from: d) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        cache[pattern] = f
        return f.string(from: d)
    }
}

extension Service {
    var typeLabel: String { cadence.label }

    var scheduleLabel: String {
        switch cadence {
        case .monthly:
            return billingDay.map(Self.ordinal) ?? "monthly"
        case .biweekly:
            return "every 2 wk"
        case .quarterly, .semiannual, .annual:
            let base = cadence == .annual ? "yearly" : cadence == .semiannual ? "6-mo" : "quarterly"
            if let d = Schedule.parseDay(termStart ?? lastCharged) { return "\(base) \(DayText.short(d))" }
            return base
        case .term:
            if let e = Schedule.parseDay(termEnd) {
                return "until \(DayText.short(e)) ’\(Schedule.calendar.component(.year, from: e) % 100)"
            }
            return "prepaid"
        case .usage: return billingDay.map { "usage · \(Self.ordinal($0))" } ?? "usage"
        case .topup: return "top-up"
        case .other: return ""
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
