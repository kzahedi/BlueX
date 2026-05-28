// BlueX/Views/Thread/SentimentIndicator.swift
import SwiftUI

// A compact horizontal sentiment bar: red for negative, green for positive, fill width
// proportional to |score|. Returns an empty view when there's no NLTagger score yet.
struct SentimentIndicator: View {
    let score: Double?

    var body: some View {
        if let score {
            let width: CGFloat = 28
            let height: CGFloat = 4
            let clamped = max(-1.0, min(1.0, score))
            let magnitude = CGFloat(abs(clamped))
            let color: Color = clamped >= 0 ? .counterBorder : .hateBorder
            HStack(spacing: 4) {
                ZStack(alignment: clamped >= 0 ? .leading : .trailing) {
                    Capsule()
                        .fill(Color.mutedText.opacity(0.25))
                        .frame(width: width, height: height)
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, width * magnitude), height: height)
                }
                Text(String(format: "%+.2f", clamped))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondaryText)
                    .monospacedDigit()
            }
            .help("Apple sentiment: \(String(format: "%+.2f", clamped))")
        }
    }
}
