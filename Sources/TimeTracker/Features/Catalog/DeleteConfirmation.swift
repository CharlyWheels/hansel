import SwiftUI

extension View {
    /// Asks before deleting catalog rows, saying how many time entries lose the link.
    ///
    /// A swipe used to delete a customer with no confirmation at all, along with the
    /// attribution of every past entry for it.
    func confirmingDelete(
        _ pending: Binding<IndexSet?>,
        noun: String,
        affectedEntries: @escaping (IndexSet) -> Int,
        perform: @escaping (IndexSet) -> Void
    ) -> some View {
        confirmationDialog(
            "Delete \(noun)?",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { offsets in
            Button("Delete", role: .destructive) {
                perform(offsets)
                pending.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
        } message: { offsets in
            let count = affectedEntries(offsets)
            if count == 0 {
                Text("No time entries use it. This can't be undone.")
            } else {
                Text(count == 1
                     ? "1 time entry keeps its time but loses this link. This can't be undone."
                     : "\(count) time entries keep their time but lose this link. This can't be undone.")
            }
        }
    }
}
