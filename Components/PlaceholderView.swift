import SwiftUI

struct PlaceholderView: View {

    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        ZStack {
            RBColor.background
                .ignoresSafeArea()

            VStack(spacing: 16) {

                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(RBColor.accent)

                Text(title)
                    .font(RBFont.title(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Text(subtitle)
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
            }
        }
    }
}
