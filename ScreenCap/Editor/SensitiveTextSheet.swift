import AppKit
import SwiftUI

/// Sheet listing the redactions proposed by `SensitiveTextDetector`; the checked ones become
/// Pixelate annotations (one undo step) when the user clicks Apply.
struct SensitiveTextSheet: View {
    let proposals: [SensitiveTextDetector.Proposal]
    let onApply: ([SensitiveTextDetector.Proposal]) -> Void
    let onCancel: () -> Void

    @State private var checked: Set<UUID>

    init(proposals: [SensitiveTextDetector.Proposal],
         onApply: @escaping ([SensitiveTextDetector.Proposal]) -> Void, onCancel: @escaping () -> Void) {
        self.proposals = proposals
        self.onApply = onApply
        self.onCancel = onCancel
        _checked = State(initialValue: Set(proposals.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposals.isEmpty ? "No sensitive text found" : "Sensitive text found")
                        .font(.headline)
                    Text(proposals.isEmpty
                         ? "Nothing looked like an email, phone number, IP address or API key."
                         : "Choose what to pixelate. You can still move or delete each redaction afterwards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !proposals.isEmpty {
                List {
                    ForEach(proposals) { p in
                        Toggle(isOn: binding(for: p.id)) {
                            HStack(spacing: 8) {
                                Image(systemName: p.kind.symbol)
                                    .frame(width: 16)
                                    .foregroundStyle(.secondary)
                                Text(p.text)
                                    .font(.body.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(p.kind.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)

                HStack {
                    Button("Select All") { checked = Set(proposals.map(\.id)) }
                        .disabled(checked.count == proposals.count)
                    Button("Select None") { checked.removeAll() }
                        .disabled(checked.isEmpty)
                    Spacer()
                    Text("\(checked.count) of \(proposals.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                if !proposals.isEmpty {
                    Button("Apply") { onApply(proposals.filter { checked.contains($0.id) }) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(checked.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { checked.contains(id) },
                set: { on in if on { checked.insert(id) } else { checked.remove(id) } })
    }
}
