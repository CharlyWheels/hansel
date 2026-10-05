import SwiftUI

struct MenuBarLabel: View {
    @Environment(TimerController.self) private var controller
    @Environment(EntryCompletionService.self) private var completion
    @Environment(FocusPromptCenter.self) private var prompts

    var body: some View {
        // Kept to a plain SF Symbol: a MenuBarExtra label that re-evaluates rapidly
        // sends updateButton into an infinite loop on macOS 26.
        if prompts.pending != nil || completion.pendingPrompt != nil {
            // Attention icon draws the user to the open-menu action.
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: controller.isRunning ? "record.circle.fill" : "timer")
                .foregroundStyle(controller.isRunning ? .red : .primary)
        }
    }
}
