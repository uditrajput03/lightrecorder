//
//  ContentSelectionMode.swift
//  LightRecorder
//
//  Created by Joshua Sattler on 28.03.26.
//

import Foundation

/// The mode for content selection: full screen, drawing an area, or picking a window
enum ContentSelectionMode: String, CaseIterable {
    /// The `UserDefaults` / `@AppStorage` key used to persist the selected mode.
    static let storageKey = "contentSelectionMode"

    /// The mode currently stored in `UserDefaults`, falling back to `.fullScreen`.
    static var current: ContentSelectionMode {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return .fullScreen }
        return ContentSelectionMode(rawValue: raw) ?? .fullScreen
    }

    case fullScreen
    case selectArea
    case pickContent

    var label: String {
        switch self {
        case .fullScreen: return "Full Screen"
        case .selectArea: return "Select Area"
        case .pickContent: return "Window / App"
        }
    }

    var shortTitle: String {
        switch self {
        case .fullScreen: return "Screen"
        case .selectArea: return "Area"
        case .pickContent: return "Window"
        }
    }

    var icon: String {
        switch self {
        case .fullScreen: return "display"
        case .selectArea: return "rectangle.dashed"
        case .pickContent: return "macwindow"
        }
    }
}
