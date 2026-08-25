import SwiftUI
import SwiftData

/// Detail column for the labelling tab: presents one item of the currently-open batch
/// at a time and records a decision per keypress.
///
/// **Blindness.** This view renders `AggregateReader.LabellingContext` fields only —
/// the reply's own text/author, the root, and the parent when it differs from the
/// root. There is no score, model label, or moderation field anywhere in that struct
/// (see its own doc comment), so there is nothing of that kind for this view to
/// accidentally surface; keep it that way in any future edit here.
struct LabellingSessionView: View {
    var viewModel: LabellingViewModel
    @Environment(\.modelContext) private var modelContext

    private enum FocusTarget: Hashable { case session, note }
    @FocusState private var focus: FocusTarget?

    /// Persisted so a labelling session resumed tomorrow keeps today's reading size.
    @AppStorage("labellingTextScale") private var storedTextScale: Double = 1.3
    private var textScale: Double { LabellingFormatting.clampedTextScale(storedTextScale) }

    /// Whether the canonical-definitions reference panel is shown. Defaults to `true`
    /// — an annotator who has never seen this app must not have to discover the
    /// panel's existence before they get the canonical wording; ⌘I (below) toggles it
    /// once they know it's there and want the extra width back.
    @AppStorage("labellingDefinitionsPanelExpanded") private var definitionsPanelExpanded: Bool = true

    @State private var noteText: String = ""
    @State private var sessionStartedAt: Date = Date()

    var body: some View {
        Group {
            if viewModel.currentBatchID == nil {
                placeholder
            } else if viewModel.isSessionComplete {
                completionState
            } else {
                session
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .onAppear { focus = .session }
        .onChange(of: viewModel.currentBatchID) { _, newValue in
            if newValue != nil {
                sessionStartedAt = Date()
                noteText = ""
                focus = .session
            }
        }
    }

    // MARK: - Empty / completion states

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "tag")
                .font(.system(size: 40))
                .foregroundStyle(Color.mutedText)
            Text("No batch open")
                .font(.title3)
                .foregroundStyle(Color.secondaryText)
            Text("Choose \"Continue\" on a batch to start labelling")
                .font(.caption)
                .foregroundStyle(Color.mutedText)
        }
    }

    private var completionState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.counterBorder)
            Text(viewModel.isRevisitingSkips ? "Revisit complete" : "Batch complete")
                .font(.title3)
                .foregroundStyle(Color.primaryText)
            Text(viewModel.isRevisitingSkips
                 ? "Every previously-skipped item offered this session has a decision recorded, or was left skipped."
                 : "Every item offered this session has a decision recorded or was set aside as skipped.")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
            Text(LabellingFormatting.batchProgressSummary(
                labelled: viewModel.batchLabelledCount, skipped: viewModel.batchSkippedCount,
                drawn: viewModel.batchDrawnCount))
                .font(.caption)
                .foregroundStyle(Color.mutedText)
        }
    }

    // MARK: - Session

    private var session: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                progressHeader

                if viewModel.isRevisitingSkips {
                    revisitBanner
                }

                if let error = viewModel.recordError {
                    recordErrorBanner(error)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let item = viewModel.currentItem {
                            rootCard(item)
                            if let parentURI = item.parentURI, parentURI != item.rootURI {
                                parentCard(item)
                            }
                            replyCard(item)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                noteField
                classButtons
                hintLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
            .focusable()
            .focused($focus, equals: .session)
            .onKeyPress(keys: ["1", "2", "3", "0"]) { press in
                handleKey(press.characters)
                return .handled
            }
            // ⌘I toggles the definitions panel — chosen because it does not collide
            // with the bare 1/2/3/0 label keys (the fast path), nor with ⌘N (note
            // field focus) or ⌘+/⌘−/⌘0 (text scale), all wired the same
            // "invisible button with a keyboardShortcut" way just below.
            Button("") { definitionsPanelExpanded.toggle() }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

            if definitionsPanelExpanded {
                Divider()
                definitionsPanel
            }
        }
    }

    private var progressHeader: some View {
        TimelineView(.periodic(from: sessionStartedAt, by: 1)) { context in
            HStack {
                Text(LabellingFormatting.sessionProgressSummary(
                    index: viewModel.currentIndex, total: viewModel.sessionItems.count))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                Spacer()
                Text(LabellingFormatting.elapsedSummary(context.date.timeIntervalSince(sessionStartedAt)))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
            .padding(.horizontal, 16)
        }
    }

    /// Shown for the whole duration of a revisit session — never let a previously
    /// set-aside item be presented as if it were fresh, ordinary work.
    private var revisitBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Color.neutralBorder)
            Text("Revisiting previously skipped items — these were deliberately set aside, not new")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Record errors

    /// Both cases the view model publishes must be surfaced, per the carry-forward
    /// requirement from Task 4's re-review: `.saveFailed` is a prominent, non-dismissed
    /// "your label was NOT saved" banner — the item stays current, and per
    /// `LabellingFormatting.keyIsPermitted` a bare "0" is inert while it's showing; the
    /// only ways past it are retrying a class key or the explicit "Skip anyway" button
    /// this banner offers. `.postNotFound` is a transient, non-blocking notice (the
    /// session has already advanced past that item) and does NOT gate any key.
    /// `.batchNotFound` means the whole session is broken — treated as seriously as
    /// `.saveFailed`, same gating, same explicit escape hatch.
    @ViewBuilder
    private func recordErrorBanner(_ error: LabellingViewModel.RecordFailure) -> some View {
        switch error {
        case .saveFailed(let message):
            errorBanner(icon: "exclamationmark.triangle.fill", iconColor: Color.hateBorder,
                        title: "Label NOT saved — retry",
                        detail: message, background: Color.hateBackground, blocking: true)
        case .batchNotFound:
            errorBanner(icon: "exclamationmark.triangle.fill", iconColor: Color.hateBorder,
                        title: "Session broken — label NOT saved",
                        detail: error.errorDescription ?? "Batch not found.",
                        background: Color.hateBackground, blocking: true)
        case .postNotFound(let uri):
            errorBanner(icon: "arrow.forward.circle", iconColor: Color.neutralBorder,
                        title: "Post no longer exists — skipped",
                        detail: uri, background: Color.neutralBackground, blocking: false)
        }
    }

    /// `blocking` adds the explicit, labelled "Skip anyway" affordance — a deliberate
    /// mouse click that abandons the unsaved label on purpose, distinct from the ordinary
    /// skip button/key (which `keyIsPermitted` makes inert while this banner is showing).
    private func errorBanner(icon: String, iconColor: Color, title: String, detail: String,
                              background: Color, blocking: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
            }
            Spacer()
            if blocking {
                Button("Skip anyway") {
                    viewModel.skip(context: modelContext)
                    noteText = ""
                    focus = .session
                }
                .buttonStyle(.bordered)
                .tint(Color.hateBorder)
                .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - Post cards

    private func rootCard(_ item: AggregateReader.LabellingContext) -> some View {
        postCard(label: "Root", handle: item.rootHandle, text: item.rootText,
                 background: Color.panelBackground, prominent: false)
    }

    private func parentCard(_ item: AggregateReader.LabellingContext) -> some View {
        postCard(label: "Parent", handle: item.parentHandle ?? "", text: item.parentText ?? "",
                 background: Color.panelBackground, prominent: false)
    }

    private func replyCard(_ item: AggregateReader.LabellingContext) -> some View {
        postCard(label: "Reply (label this)", handle: item.authorHandle, text: item.text,
                 background: Color.selectedBackground, prominent: true)
    }

    private func postCard(label: String, handle: String, text: String, background: Color,
                           prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondaryText)
            Text("@\(handle)")
                .font(.system(size: 11))
                .foregroundStyle(Color.mutedText)
            Text(text)
                .font(.system(size: (prominent ? 17.0 : 14.0) * textScale,
                              weight: prominent ? .medium : .regular))
                .foregroundStyle(Color.primaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(prominent ? Color.neutralBorder : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Definitions reference panel

    /// Compact, always-available reference to the canonical class definitions — a
    /// fixed-width sidebar so it can never grow to obscure the post cards, and
    /// independently scrollable so the annotator can consult it without losing their
    /// place in (or slowing down) the keyboard-driven labelling flow. Toggle with ⌘I;
    /// state persists via `definitionsPanelExpanded`.
    private var definitionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Definitions")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Spacer()
                    Text("⌘I")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
                ForEach(LabellingDefinitions.all, id: \.key) { definition in
                    definitionSection(definition)
                }
                if !LabellingDefinitions.applyingNotes.isEmpty {
                    Divider()
                    Text("Applying these")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                    ForEach(Array(LabellingDefinitions.applyingNotes.enumerated()), id: \.offset) { _, note in
                        Text("• \(note)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondaryText)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 280)
        .background(Color.panelBackground)
    }

    private func definitionSection(_ definition: LabellingDefinitions.ClassDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LabellingFormatting.definitionPanelKeyLabel(definition))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.primaryText)
            Text(definition.definition)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
            if !definition.notThis.isEmpty {
                Text("Not this:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.mutedText)
                ForEach(Array(definition.notThis.enumerated()), id: \.offset) { _, bullet in
                    Text("– \(bullet)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mutedText)
                }
            }
        }
    }

    // MARK: - Note field

    /// Starts unfocused — number keys must never be stolen by an idle text field.
    /// Focus is only ever moved here by the explicit ⌘N shortcut below.
    private var noteField: some View {
        HStack(spacing: 8) {
            TextField("Add a note (⌘N)", text: $noteText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(6)
                .background(Color.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .focused($focus, equals: .note)
                .onSubmit { focus = .session }
            Button("") { focus = .note }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            // Text size: ⌘+ / ⌘− / ⌘0. Command-modified so they can never shadow the
            // bare 1/2/3/0 label keys, which stay the fast path.
            Button("") { storedTextScale = LabellingFormatting.clampedTextScale(textScale + LabellingFormatting.textScaleStep) }
                .keyboardShortcut("+", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("") { storedTextScale = LabellingFormatting.clampedTextScale(textScale + LabellingFormatting.textScaleStep) }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("") { storedTextScale = LabellingFormatting.clampedTextScale(textScale - LabellingFormatting.textScaleStep) }
                .keyboardShortcut("-", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("") { storedTextScale = 1.0 }
                .keyboardShortcut("0", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Class buttons

    private var classButtons: some View {
        HStack(spacing: 8) {
            classButton(key: "1", label: "Hate", color: .hateBorder) { handleKey("1") }
            classButton(key: "2", label: "Counter", color: .counterBorder) { handleKey("2") }
            classButton(key: "3", label: "Neutral", color: .neutralBorder) { handleKey("3") }
            // Disabled (not just gated on keypress) while a blocking recordError is
            // active — a stray click on this button must be exactly as inert as a
            // stray "0" keypress. The one intentional way to abandon a stuck item is
            // the banner's explicit "Skip anyway" button, never this one.
            classButton(key: "0", label: "Skip", color: .mutedText) { handleKey("0") }
                .disabled(!LabellingFormatting.keyIsPermitted("0", recordError: viewModel.recordError))
        }
        .padding(.horizontal, 16)
    }

    private func classButton(key: String, label: String, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(key)
                    .font(.system(size: 14, weight: .bold))
                Text(label)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(color)
    }

    private var hintLine: some View {
        Text("labels are recorded immediately — you can stop at any time")
            .font(.caption)
            .foregroundStyle(Color.mutedText)
            .padding(.horizontal, 16)
    }

    // MARK: - Key handling

    private func handleKey(_ characters: String) {
        // Typing in the note field must never be interpreted as a class/skip key —
        // this guards the mouse-click path (`classButton`), which can fire regardless
        // of focus; the keyboard path is already excluded from receiving these events
        // while the note field holds focus (see `noteField`'s doc comment).
        guard focus != .note else { return }
        // Single choke point for every class/skip action, keyboard or mouse (every
        // `classButton` action closure routes through here) — see
        // `LabellingFormatting.keyIsPermitted` for why "0" is inert while a blocking
        // recordError is showing. The one deliberate bypass is the banner's own
        // "Skip anyway" button, which calls `viewModel.skip()` directly rather than
        // going through this function.
        guard LabellingFormatting.keyIsPermitted(characters, recordError: viewModel.recordError) else { return }
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch characters {
        case "1": viewModel.record("hate", note: note.isEmpty ? nil : note, context: modelContext)
        case "2": viewModel.record("counter", note: note.isEmpty ? nil : note, context: modelContext)
        case "3": viewModel.record("neutral", note: note.isEmpty ? nil : note, context: modelContext)
        case "0": viewModel.skip(context: modelContext)
        default: return
        }
        // Only clear the typed note once the session has actually advanced past this
        // item. `skip()` and a clean `record()` both advance; `.postNotFound` also
        // advances (the post is gone, so there's nothing left to retry against) — but
        // `.saveFailed`/`.batchNotFound` leave the item current, and the annotator's
        // note must survive so they don't lose it on retry.
        let advanced: Bool
        switch viewModel.recordError {
        case nil, .postNotFound: advanced = true
        case .saveFailed, .batchNotFound: advanced = false
        }
        if characters == "0" || advanced {
            noteText = ""
        }
        focus = .session
    }
}
