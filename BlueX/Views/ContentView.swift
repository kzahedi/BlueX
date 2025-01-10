//
//  ContentView.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 03.01.25.
//

import SwiftUI
import CoreData

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @EnvironmentObject private var taskManager: TaskManager
    @State private var selectedView: ContentViewType = .configuration

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.id, ascending: true)],
        animation: .default)

    private var accounts: FetchedResults<Account>

    var body: some View {
        NavigationView {
            List {
                ForEach(accounts) { account in
                    NavigationLink(destination: destinationView(for: account)) {
                        accountLabel(for: account)
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .navigationTitle("Configuration")
            .toolbar {
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
            Text("Select an item")
        }
        .background(
            KeyEventHandlingView { keyEvent in
                if keyEvent.keyCode == 49 { // Spacebar key code is 49
                    switchView()
                }
            }
        )
    }
    
    private func accountLabel(for account: Account) -> some View {
        if account.displayName == nil && account.handle == nil {
            return Text("New Account")
        } else if let displayName = account.displayName {
            return Text("\(displayName)")
        } else if let handle = account.handle {
            return Text("\(handle)")
        } else {
            return Text("Unknown Account")
        }
    }
    
    private func destinationView(for account: Account) -> some View {
        if selectedView == .configuration {
            return AnyView(
                AccountSettingsView(
                    viewModel: AccountViewModel(account: account, context: viewContext)
                )
            )
        } else {
            return AnyView(
                AccountPlotView(
                    viewModel: StatisticsModel(account: account, context: viewContext)
                )
            )
        }
    }

    private func switchView() {
        if isTextFieldFocused() == false {
            selectedView = (selectedView == .configuration) ? .plots : .configuration
        }
    }
    
    private func isTextFieldFocused() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return false }
        return firstResponder is NSTextView
    }
    
    private func addItem() {
        withAnimation {
            let newAccount = Account(context: viewContext)
            newAccount.handle = "New Account"
            newAccount.id = UUID()

            do {
                try viewContext.save()
            } catch {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                let nsError = error as NSError
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { accounts[$0] }.forEach(viewContext.delete)

            do {
                try viewContext.save()
            } catch {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                let nsError = error as NSError
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }
    
    struct KeyEventHandlingView: NSViewRepresentable {
        var onKeyPress: (NSEvent) -> Void
        
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            let keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                onKeyPress(event)
                return event
            }
            context.coordinator.keyDownMonitor = keyDownMonitor
            return view
        }
        
        func updateNSView(_ nsView: NSView, context: Context) {}
        
        func makeCoordinator() -> Coordinator {
            Coordinator()
        }
        
        class Coordinator {
            var keyDownMonitor: Any?
            deinit {
                if let monitor = keyDownMonitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
        }
    }
}

enum ContentViewType {
    case configuration
    case plots
}

#Preview {
    ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
