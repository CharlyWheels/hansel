import SwiftUI
import SwiftData

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case todos = "Todos"
    case meetings = "Meetings"
    case entries = "Entries"
    case timeline = "Timeline"
    case analytics = "Analytics"
    case projects = "Projects"
    case customers = "Customers"
    case roles = "Roles"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard: return "rectangle.grid.2x2"
        case .entries: return "list.bullet.rectangle"
        case .timeline: return "clock.arrow.circlepath"
        case .todos: return "checklist"
        case .meetings: return "waveform"
        case .analytics: return "chart.bar"
        case .projects: return "folder"
        case .customers: return "person.2"
        case .roles: return "person.badge.key"
        }
    }

    var section: SidebarSection {
        switch self {
        case .dashboard, .entries, .timeline, .todos, .meetings: return .tracking
        case .analytics: return .reports
        case .projects, .customers, .roles: return .catalog
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case tracking = "Tracking"
    case reports = "Reports"
    case catalog = "Catalog"

    var id: String { rawValue }

    var items: [SidebarItem] {
        SidebarItem.allCases.filter { $0.section == self }
    }
}

struct ContentView: View {
    @Environment(MainWindowRouter.self) private var router
    @Environment(FocusPromptCenter.self) private var prompts
    @Query(TodoProposal.pendingDescriptor) private var pendingProposals: [TodoProposal]

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            List(selection: $router.selection) {
                ForEach(SidebarSection.allCases) { section in
                    Section(section.rawValue) {
                        ForEach(section.items) { item in
                            Label(item.rawValue, systemImage: item.systemImage)
                                .badge(badge(for: item))
                                .tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            // In the sidebar, not around the detail: wrapping the detail in a VStack
            // left the pages that own a NavigationStack (Todos, Projects, Customers,
            // Roles) rendering a blank window.
            .safeAreaInset(edge: .bottom) {
                PermissionBanner().padding(8)
            }
        } detail: {
            detailView
        }
        // hansel://open/<page> (e.g. hansel://open/todos) lands on that page.
        .onOpenURL { url in
            let page = url.pathComponents.dropFirst().first?.lowercased() ?? ""
            if let item = SidebarItem.allCases.first(where: { $0.rawValue.lowercased() == page }) {
                router.selection = item
            }
        }
        // "It's something else…" splits the entry and then lands here to be labelled.
        .sheet(item: Binding(
            get: { prompts.entryToEdit },
            set: { prompts.entryToEdit = $0 }
        )) { entry in
            EntryEditorView(entry: entry)
                .frame(minWidth: 480, minHeight: 520)
        }
    }

    /// What is waiting on each page: proposals to decide on Todos.
    private func badge(for item: SidebarItem) -> Int {
        item == .todos ? pendingProposals.count : 0
    }

    @ViewBuilder
    private var detailView: some View {
        switch router.selection {
        case .dashboard: DashboardView()
        case .entries:   EntryListView()
        case .timeline:  DayTimelineView()
        case .todos:     TodosView()
        case .meetings:  MeetingsView()
        case .analytics: AnalyticsView()
        case .projects:  ProjectsView()
        case .customers: CustomersView()
        case .roles:     RolesView()
        }
    }
}
