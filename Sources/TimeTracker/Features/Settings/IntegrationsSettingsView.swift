import SwiftUI
import AppKit

/// Lets AI assistants on this Mac (Claude, Codex, Cursor…) read and edit Hansel's data
/// through MCP, and gives the exact setup for each.
struct IntegrationsSettingsView: View {
    @Environment(MCPServer.self) private var server
    @AppStorage(MCPServer.enabledKey) private var enabled = false
    @State private var copied: String?

    /// The binary assistants launch; the installed app's own, wherever it lives.
    private var command: String {
        Bundle.main.executablePath ?? "/Applications/Hansel.app/Contents/MacOS/Hansel"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI assistants on this Mac", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in server.applySetting() }
                LabeledContent("Status") { statusLabel }
            } header: {
                Text("MCP")
            } footer: {
                Text("Assistants can read your entries, todos, projects, customers, roles and meetings, start and stop the timer, and create or edit those items. They cannot delete anything. Only apps you set up on this Mac can connect, and only while Hansel is open; what an assistant reads goes to its own AI provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                snippet(
                    "Claude Code",
                    hint: "Run in Terminal:",
                    text: "claude mcp add --scope user hansel -- \"\(command)\" \(MCPStdioBridge.flag)"
                )
                snippet(
                    "Claude Desktop",
                    hint: "Add to Settings → Developer → Edit Config (claude_desktop_config.json), then restart Claude:",
                    text: """
                    {
                      "mcpServers": {
                        "hansel": {
                          "command": "\(command)",
                          "args": ["\(MCPStdioBridge.flag)"]
                        }
                      }
                    }
                    """
                )
                snippet(
                    "Codex",
                    hint: "Add to ~/.codex/config.toml:",
                    text: """
                    [mcp_servers.hansel]
                    command = "\(command)"
                    args = ["\(MCPStdioBridge.flag)"]
                    """
                )
            } header: {
                Text("Connect an assistant")
            } footer: {
                Text("Any other MCP client works the same way: it runs Hansel with \(MCPStdioBridge.flag).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch server.status {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .listening:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    private func snippet(_ name: String, hint: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Button(copied == name ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = name
                }
                .controlSize(.small)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
        }
        .padding(.vertical, 2)
    }
}
