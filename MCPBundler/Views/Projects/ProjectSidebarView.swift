//
//  ProjectSidebarView.swift
//  MCP Bundler
//
//  Displays the list of projects in the navigation sidebar.
//

import SwiftUI
import SwiftData

struct ProjectSidebarView: View {
    let projects: [Project]
    @Binding var selection: Project?
    var onDelete: (IndexSet) -> Void
    var onMove: (IndexSet, Int) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(projects) { project in
                NavigationLink(value: project) {
                    HStack {
                        Text(project.name)
                        if project.isActive {
                            Text("Active")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .onDelete(perform: onDelete)
            .onMove(perform: onMove)
        }
        .listStyle(.sidebar)
    }
}
