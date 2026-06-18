import SwiftUI

/// In-app Hansel logo — same design as the app icon (rounded square with
/// amber-red gradient, breadcrumb trail, bold "H"). Scales to any size.
struct HanselLogoView: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.97, green: 0.67, blue: 0.36),
                        Color(red: 0.87, green: 0.33, blue: 0.23)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            // Breadcrumb trail
            HStack(spacing: size * 0.06) {
                ForEach(0..<4, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: size * 0.06, height: size * 0.06)
                }
            }
            .offset(y: size * 0.28)
            // H letter
            Text("H")
                .font(.system(size: size * 0.58, weight: .heavy))
                .foregroundStyle(.white)
                .offset(y: -size * 0.04)
                .shadow(color: .black.opacity(0.15), radius: size * 0.02, y: size * 0.01)
        }
        .frame(width: size, height: size)
    }
}

/// Inline branding row — logo + "Hansel" wordmark. Used in menu bar popover header.
struct HanselBrandRow: View {
    var iconSize: CGFloat = 22
    var body: some View {
        HStack(spacing: 6) {
            HanselLogoView(size: iconSize)
            Text("Hansel")
                .font(.system(size: iconSize * 0.72, weight: .semibold))
            Spacer()
        }
    }
}
