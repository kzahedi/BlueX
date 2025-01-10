//
//  LoggerWindow.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 10.01.25.
//

import Foundation
import SwiftUI
import AppKit

class LoggerWindowController: NSWindowController {
    static let shared = LoggerWindowController()
    
    private init() {
        let contentView = NSHostingView(rootView: LoggerView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.title = "Logger"
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
