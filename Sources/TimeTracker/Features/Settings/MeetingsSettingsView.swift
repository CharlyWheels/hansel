import SwiftUI
import AppKit

struct MeetingsSettingsView: View {
    @Environment(MeetingImporter.self) private var importer
    @Environment(\.modelContext) private var modelContext
    @State private var decisionCount = 0
    @State private var confirmReset = false

    @AppStorage(MeetingImporter.enabledKey) private var importEnabled = true
    @AppStorage(MeetingNotesArchive.pathDefaultsKey) private var archivePath = ""
    @AppStorage(OwnerMatcher.namesDefaultsKey) private var myNames = ""
    @AppStorage(MeetingTaskEnricher.enabledKey) private var aiEnabled = false
    @AppStorage(MeetingTaskEnricher.includeTranscriptKey) private var aiTranscript = true
    @AppStorage(NamedSummaryWriter.enabledKey) private var namedSummary = false

    var body: some View {
        Form {
            Section("Meeting Notes archive") {
                Toggle("Import meetings recorded with Meeting Notes", isOn: $importEnabled)
                LabeledContent("Folder") {
                    HStack {
                        Text(MeetingNotesArchive.resolvedRoot().path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                        if !archivePath.isEmpty {
                            Button("Follow Meeting Notes") { archivePath = "" }
                        }
                    }
                }
                HStack {
                    Button("Scan now") { Task { await importer.scan() } }
                        .disabled(!importEnabled || importer.isScanning)
                    if let at = importer.lastScanAt {
                        Text("Last scan \(at.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = importer.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text("Hansel reads finished meetings from the folder Meeting Notes archives to (it follows that app's setting unless you choose one here). It only reads; nothing in the archive is changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VoicesSettingsSection()
            Section("Proposed todos") {
                TextField("Names you go by", text: $myNames, prompt: Text(NSFullUserName()))
                Text("Comma-separated, e.g. \"Carlos, Carlos Rueda\". When the summary assigns a task to someone whose name is not one of these, the proposal is marked as probably for someone else. Each proposal also shows who was speaking when it came up, once voices are identified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Learning from your decisions") {
                HStack {
                    Text("\(decisionCount) accepted or declined proposal(s) in the last 180 days")
                    Spacer()
                    Button("Forget…") { confirmReset = true }
                        .disabled(decisionCount == 0)
                }
                Text("When you move a task from a recurring meeting to another project, the next tasks from that meeting get that project. If you decline every proposal from a meeting, later ones say so. With AI refinement on, recent declines and title rewrites are shown to the model as examples.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Summaries with names") {
                Toggle("Rewrite meeting summaries with the speakers' names", isOn: $namedSummary)
                Text("Once voices have names, the AI provider rewrites Meeting Notes' summary so it says who said what (\"Carlos explained…\" instead of \"a speaker explained…\"). It sends the summary and the transcript labelled with names; never audio or voiceprints. One call per meeting, again only when the names change. The original stays available, and Meeting Notes' files are not changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Refine proposals with AI") {
                Toggle("Let the AI provider refine proposed todos", isOn: $aiEnabled)
                Toggle("Include what was said around each task", isOn: $aiTranscript)
                    .disabled(!aiEnabled)
                Text("One call per meeting to the default provider in Settings → AI: it rewrites titles, picks a project when your catalog rules found none, sets a due date only when one was said, and flags tasks that are someone else's. This sends the meeting title, participants, summary and action items\(aiTranscript ? ", plus short transcript excerpts (or the whole transcript when there is no action item list)" : ""). Check that your organisation allows sending meeting content to that provider. Proposals you already edited are never changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: countDecisions)
        .confirmationDialog("Forget what Hansel learned from your decisions?", isPresented: $confirmReset) {
            Button("Forget", role: .destructive) {
                ProposalLearning.reset(context: modelContext)
                countDecisions()
            }
        } message: {
            Text("Accepted and declined proposals are deleted. Todos you accepted stay, and undecided proposals are kept.")
        }
    }

    private func countDecisions() {
        decisionCount = ProposalLearning.decisions(context: modelContext).count
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = MeetingNotesArchive.resolvedRoot()
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url {
            archivePath = url.path
        }
    }
}
