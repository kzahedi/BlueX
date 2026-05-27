// BlueX/Views/Thread/AnnotationBadge.swift
import SwiftUI

struct AnnotationBadge: View {
    let annotation: Annotation

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.speechClassBorder(annotation.speechClass))
                .frame(width: 6, height: 6)
            Text(badgeLabelForTest)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.speechClassBadgeText(annotation.speechClass))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.speechClassBackground(annotation.speechClass))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // internal so tests can access directly
    var badgeLabelForTest: String {
        switch annotation.speechClass {
        case "hate":
            if let severity = annotation.severity {
                return "● hate · \(severity)"
            }
            return "● hate"
        case "counter":
            return "● counter"
        default:
            return "● neutral"
        }
    }
}
