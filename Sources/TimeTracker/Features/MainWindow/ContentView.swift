import SwiftUI
import SwiftData

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case todos = "Todos"
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
        case .analytics: return "chart.bar"
        case .projects: return "folder"
        case .customers: return "person.2"
        case .roles: return "person.badge.key"
        }
    }

    var section: SidebarSection {
        switch self {
        case .dashboard, .entries, .timeline, .todos: return .tracking
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
    @State private var selection: SidebarItem = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarSection.allCases) { section in
                    Section(section.rawValue) {
                        ForEach(section.items) { item in
                            Label(item.rawValue, systemImage: item.systemImage).tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selection {
            case .dashboard: DashboardView()
            case .entries:   EntryListView()
            case .timeline:  DayTimelineView()
            case .todos:     TodosView()
            case .analytics: AnalyticsView()
            case .projects:  ProjectsView()
            case .customers: CustomersView()
            case .roles:     RolesView()
            }
        }
    }
}
