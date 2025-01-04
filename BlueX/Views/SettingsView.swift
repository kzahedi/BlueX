//
//  Settings.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 25.12.24.
//

import Foundation
import SwiftUI

struct SettingsView: View {
    var body: some View {
        
        TabView {
            ProfileSettingsView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
        }
        .frame(minWidth:400, minHeight: 400)
    }
}

#Preview {
    SettingsView()
}
