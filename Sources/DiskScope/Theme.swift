import SwiftUI
import DiskScopeCore

enum Theme {
    static let background = Color(red: 0.055, green: 0.071, blue: 0.10)
    static let sidebar = Color(red: 0.07, green: 0.09, blue: 0.12)
    static let panel = Color(red: 0.09, green: 0.11, blue: 0.15)
    static let line = Color.white.opacity(0.075)
    static let muted = Color(red: 0.51, green: 0.57, blue: 0.65)
    static let accent = Color(red: 0.43, green: 0.88, blue: 0.77)

    static func color(_ category: FileCategory) -> Color {
        switch category {
        case .folder: return Color(red: 0.22, green: 0.51, blue: 0.54)
        case .video: return Color(red: 0.43, green: 0.39, blue: 0.72)
        case .image: return Color(red: 0.70, green: 0.40, blue: 0.53)
        case .audio: return Color(red: 0.34, green: 0.57, blue: 0.74)
        case .archive: return Color(red: 0.68, green: 0.52, blue: 0.28)
        case .code: return Color(red: 0.25, green: 0.58, blue: 0.45)
        case .document: return Color(red: 0.34, green: 0.48, blue: 0.70)
        case .link, .other: return Color(red: 0.37, green: 0.42, blue: 0.50)
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 17).padding(.vertical, 11)
            .foregroundStyle(Theme.background)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}
