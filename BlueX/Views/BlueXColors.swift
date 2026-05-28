// BlueX/Views/BlueXColors.swift
import SwiftUI

extension Color {
    static let appBackground    = Color(red: 0.102, green: 0.102, blue: 0.180)
    static let panelBackground  = Color(red: 0.086, green: 0.129, blue: 0.243)
    static let selectedBackground = Color(red: 0.059, green: 0.204, blue: 0.376)
    static let hateBorder       = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let hateBackground   = Color(red: 0.498, green: 0.114, blue: 0.114)
    static let hateBadgeText    = Color(red: 0.984, green: 0.643, blue: 0.643)
    static let counterBorder    = Color(red: 0.133, green: 0.773, blue: 0.369)
    static let counterBackground = Color(red: 0.078, green: 0.325, blue: 0.173)
    static let counterBadgeText = Color(red: 0.525, green: 0.937, blue: 0.675)
    static let neutralBorder    = Color(red: 0.278, green: 0.341, blue: 0.412)
    static let neutralBackground = Color(red: 0.118, green: 0.161, blue: 0.224)
    static let neutralBadgeText = Color(red: 0.580, green: 0.635, blue: 0.722)
    static let primaryText      = Color(red: 0.886, green: 0.910, blue: 0.941)
    static let secondaryText    = Color(red: 0.580, green: 0.635, blue: 0.722)
    static let mutedText        = Color(red: 0.278, green: 0.341, blue: 0.412)
    static let pendingBackground = Color(red: 0.278, green: 0.341, blue: 0.412).opacity(0.45)
}

extension Color {
    static func speechClassBorder(_ speechClass: String) -> Color {
        switch speechClass {
        case "hate":    return .hateBorder
        case "counter": return .counterBorder
        default:        return .neutralBorder
        }
    }
    static func speechClassBackground(_ speechClass: String) -> Color {
        switch speechClass {
        case "hate":    return .hateBackground
        case "counter": return .counterBackground
        default:        return .neutralBackground
        }
    }
    static func speechClassBadgeText(_ speechClass: String) -> Color {
        switch speechClass {
        case "hate":    return .hateBadgeText
        case "counter": return .counterBadgeText
        default:        return .neutralBadgeText
        }
    }
}
