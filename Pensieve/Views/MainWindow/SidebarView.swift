import os
import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var section: SidebarSection?
    let showsMachines: Bool

    var body: some View {
        SidebarOutline(items: SidebarRows.items(showsMachines: showsMachines), selection: $section)
            .navigationTitle("Pensieve")
    }
}
