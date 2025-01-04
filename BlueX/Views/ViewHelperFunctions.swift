//
//  HelperFunctions.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 03.01.25.
//

import Foundation
import CoreData
import SwiftUI

func createPreviewContext() -> NSManagedObjectContext {
    let container = NSPersistentContainer(name: "BlueX") // Replace "YourModelName" with your Core Data model name
    container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null") // In-memory store for previews
    
    container.loadPersistentStores { _, error in
        if let error = error as NSError? {
            fatalError("Unresolved error \(error), \(error.userInfo)")
        }
    }
    
    let context = container.viewContext
    
    // Add a sample Account object for previews
    let account = Account(context: context)
    account.displayName = "Sample Account" // Replace with your Account entity properties
    
    do {
        try context.save()
    } catch {
        print("Failed to save preview context: \(error)")
    }
    
    return context
}

struct SectionCard<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 5)
            
            content
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                )
        }
        .padding(.horizontal)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
