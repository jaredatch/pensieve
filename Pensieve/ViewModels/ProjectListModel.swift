import Foundation

struct ProjectListModel {
    struct Row: Identifiable {
        let selection: EntitySelection
        let presentation: ListRowModel
        let localProject: Project?

        var id: EntitySelection { selection }
    }

    let rows: [Row]
    let totalCount: Int

    var subtitle: String {
        ListSubtitle.text(total: totalCount, shown: rows.count, singular: "project", plural: "projects")
    }

    init(projects: [Project], remoteProjects: [RemoteProjectModel], deployIndex: DeployIndex,
         homeDirectory: String, searchText: String) {
        let local = projects.map { project in
            Row(selection: .project(project.id),
                presentation: ListRows.project(project, deployIndex: deployIndex, homeDirectory: homeDirectory),
                localProject: project)
        }
        let remote = remoteProjects.map { project in
            Row(selection: .remoteProject(project.identityKey), presentation: ListRows.remoteProject(project),
                localProject: nil)
        }
        let all = (local + remote).sorted {
            $0.presentation.title.localizedStandardCompare($1.presentation.title) == .orderedAscending
        }
        totalCount = all.count
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        rows = query.isEmpty ? all : all.filter { $0.presentation.title.lowercased().contains(query) }
    }
}
