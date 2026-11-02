import SwiftUI
import UIKit

struct PosterImage: View {
    let imageURL: String?
    var cornerRadius: CGFloat = 10

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let imageURL, let url = URL(string: imageURL) {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            placeholder
                        default:
                            ProgressView()
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "film")
            .font(.title3)
            .foregroundStyle(.secondary)
    }
}

/// Series title in the selected catalog language. In the Japanese mode the
/// English name stays first and the Japanese title is shown underneath.
struct SeriesTitle: View {
    let title: String
    let titleJp: String?
    let language: TitleLanguage
    var font: Font = .headline
    var lineLimit = 2

    private var japanese: String? {
        guard language == .jp, let titleJp, !titleJp.isEmpty, titleJp != title else { return nil }
        return titleJp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(font)
                .lineLimit(lineLimit)
            if let japanese {
                Text(japanese)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
            }
        }
    }
}

/// Settings that belong to this device rather than to the bridge identity.
enum DeviceSettings {
    /// Translate synopses to the device language as soon as they load.
    static let translateSynopsisKey = "anksubbrd.translate-synopsis"
}

/// "+18" marker for R+ and Rx series.
struct AdultBadge: View {
    var body: some View {
        Text("+18")
            .font(.caption2.weight(.heavy))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.red, in: Capsule())
            .accessibilityLabel("Para mayores de 18 años")
    }
}

struct ErrorNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.footnote)
    }
}

struct LoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

/// On iPad the adaptable tab bar shares the navigation bar area while it
/// morphs to and from the sidebar; inline root titles avoid being covered.
struct AdaptableTabRootTitleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(UIDevice.current.userInterfaceIdiom == .pad ? .inline : .automatic)
    }
}

/// Circular Liquid Glass icon used by the player controls and menus.
struct GlassIcon: View {
    let systemName: String
    var size: CGFloat = 44
    var font: Font = .title3

    var body: some View {
        Image(systemName: systemName)
            .font(font.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
    }
}
