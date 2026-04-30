import SwiftUI

// Windows-companion visual language ported to SwiftUI.
// Keep color + typography values in lockstep with the shared desktop web app CSS.

enum TealeDesign {
    static let bgStart = Color(red: 0x06/255, green: 0x25/255, blue: 0x28/255)
    static let bgMid = Color(red: 0x01/255, green: 0x07/255, blue: 0x08/255)
    static let bgEnd = Color.black
    static let card = Color(red: 0x07/255, green: 0x12/255, blue: 0x14/255)
    static let cardStrong = Color(red: 0x0b/255, green: 0x1a/255, blue: 0x1d/255)
    static let border = Color(red: 0x0f/255, green: 0x3d/255, blue: 0x40/255)
    static let text = Color(red: 0xdf/255, green: 0xf7/255, blue: 0xf6/255)
    static let teale = Color(red: 0x00/255, green: 0xb3/255, blue: 0xb3/255)
    static let tealeDim = Color(red: 0x0d/255, green: 0x6f/255, blue: 0x72/255)
    static let muted = Color(red: 0x6a/255, green: 0xa6/255, blue: 0xa5/255)
    static let fail = Color(red: 0xff/255, green: 0x7a/255, blue: 0x7a/255)
    static let warn = Color(red: 0xff/255, green: 0xd4/255, blue: 0x47/255)

    static let mono: Font = .system(.body, design: .monospaced)
    static let monoSmall: Font = .system(.caption, design: .monospaced)
    static let monoTiny: Font = .system(.caption2, design: .monospaced)

    static var pageBackground: some View {
        RadialGradient(
            gradient: Gradient(colors: [bgStart, bgMid, bgEnd]),
            center: .top,
            startRadius: 0,
            endRadius: 900
        )
        .ignoresSafeArea()
    }
}

struct TealeCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        TealeDesign.card.opacity(0.94),
                        TealeDesign.bgMid.opacity(0.96),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Rectangle()
                    .stroke(TealeDesign.border, lineWidth: 1)
            )
    }
}

struct TealePromptHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(">")
                .foregroundStyle(TealeDesign.teale)
            Text(title.lowercased())
                .foregroundStyle(TealeDesign.muted)
                .tracking(0.6)
        }
        .font(TealeDesign.monoSmall)
        .padding(.vertical, 4)
    }
}

struct TealeSection<Content: View>: View {
    let prompt: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TealePromptHeader(title: prompt)
            TealeCard { content() }
        }
        .padding(.bottom, 8)
    }
}

struct TealeStatRow: View {
    let label: String
    let value: String
    var note: String? = nil
    var valueColor: Color = TealeDesign.text

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(label.uppercased())
                .font(TealeDesign.monoSmall)
                .tracking(0.9)
                .foregroundStyle(TealeDesign.muted)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(TealeDesign.mono)
                    .foregroundStyle(valueColor)
                if let note = note, !note.isEmpty {
                    Text(note)
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct TealeStats<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
    }
}

struct TealeActionButton: View {
    let title: String
    var primary: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.lowercased())
                .font(TealeDesign.monoSmall)
                .tracking(0.6)
                .foregroundStyle(disabled ? TealeDesign.muted : TealeDesign.teale)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    primary
                        ? TealeDesign.teale.opacity(disabled ? 0.02 : 0.08)
                        : Color.clear
                )
                .overlay(
                    Rectangle()
                        .stroke(primary ? TealeDesign.teale : TealeDesign.tealeDim, lineWidth: 1)
                        .opacity(disabled ? 0.45 : 1.0)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct TealeToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.lowercased())
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                Text(detail)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            }
        }
        .tint(TealeDesign.teale)
    }
}

struct TealeCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.text)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(red: 0x02/255, green: 0x08/255, blue: 0x09/255))
        .overlay(
            Rectangle().stroke(TealeDesign.border, lineWidth: 1)
        )
    }
}
