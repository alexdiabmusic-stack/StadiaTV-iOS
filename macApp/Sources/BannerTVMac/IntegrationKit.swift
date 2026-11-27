import BannerCore
import SwiftUI

// Building blocks shared by every integration's settings pages (Serializd, Letterboxd): grouped sections, switch and navigation rows,
// and the sheet frame. One set of components, so the pages look alike.

func toneColor(name: String) -> Color {
    switch name {
    case "Good": return Color(red: 0x3D / 255, green: 0xBE / 255, blue: 0x75 / 255)
    case "Warning": return Color(red: 0xE5 / 255, green: 0xA5 / 255, blue: 0x3A / 255)
    case "Problem": return Color(red: 0xD9 / 255, green: 0x53 / 255, blue: 0x4F / 255)
    default: return Theme.textMuted
    }
}

func toneColor(_ tone: SerializdTone) -> Color { toneColor(name: tone.name) }

func formatted(_ ms: Int64) -> String {
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
    return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

struct IntegrationSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.jb(13, .semibold)).foregroundStyle(Theme.textMuted).textCase(.uppercase).tracking(1.2).padding(.leading, 6)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let footer { Text(footer).font(.jb(12)).foregroundStyle(Theme.textMuted).padding(.horizontal, 6) }
        }
    }
}

struct RowDivider: View {
    var body: some View { Divider().overlay(Theme.hairline).padding(.leading, 64) }
}

struct IconSlot: View {
    let symbol: String
    var tint: Color = Theme.textPrimary
    var body: some View { Image(systemName: symbol).font(.system(size: 18, weight: .regular)).foregroundStyle(tint).frame(width: 30) }
}

struct SwitchRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isOn: Bool
    var enabled = true
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconSlot(symbol: symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.jb(16, .semibold))
                Text(detail).font(.jb(13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(get: { isOn }, set: onChange)).labelsHidden().toggleStyle(.switch).disabled(!enabled)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }
}

struct NavRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var tint: Color = Theme.textPrimary
    var chevron = true
    var enabled = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconSlot(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.jb(16, .semibold))
                    if let detail { Text(detail).font(.jb(13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading) }
                }
                Spacer(minLength: 12)
                if busy { ProgressView().controlSize(.small) }
                else if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textMuted) }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }
}

/// The Serializd icon, as supplied, in a rounded tile (bundled in Resources/Integrations).
struct SheetFrame<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.jb(24, .bold))
                    if let subtitle { Text(subtitle).font(.jb(14)).foregroundStyle(Theme.textSecondary) }
                }
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary, height: 36)).keyboardShortcut(.cancelAction)
            }
            content
        }
        .padding(24).frame(minWidth: 460, idealWidth: 520, minHeight: 380).background(Theme.background)
    }
}

struct DetailLine: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(label).font(.jb(15)); Spacer(); Text(value).font(.jb(15, .semibold)) }.padding(.vertical, 10)
            Divider().overlay(Theme.hairline)
        }
    }
}

