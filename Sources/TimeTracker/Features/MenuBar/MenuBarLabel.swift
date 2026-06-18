import SwiftUI

struct MenuBarLabel: View {
    @Environment(TimerController.self) private var controller
    @Environment(EntryCompletionService.self) private var completion

    var body: some View {
        if completion.pendingPrompt != nil {
            // Attention icon draws the user to the open-menu action.
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: controller.isRunning ? "record.circle.fill" : "timer")
                .foregroundStyle(controller.isRunning ? .red : .primary)
        }
    }
}
