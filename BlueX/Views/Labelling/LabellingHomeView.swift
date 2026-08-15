import SwiftUI
import SwiftData

/// Content column for the labelling tab: builds a sampling frame, shows a live count of
/// how many posts currently match it, draws a batch, and lists every batch drawn so far
/// with its progress. `LabellingSessionView` (the detail column) is driven by the same
/// `viewModel` — tapping "Continue" here opens a batch there; this view never renders
/// post content itself.
struct LabellingHomeView: View {
    var viewModel: LabellingViewModel
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \LabelBatch.createdAt, order: .reverse) private var batches: [LabelBatch]
    @Query(sort: \TrackedAccount.displayName) private var accounts: [TrackedAccount]

    // MARK: - Pool builder draft state

    @State private var isUniformRandom = true
    @State private var selectedOutletDID: String?
    @State private var dateFromEnabled = false
    @State private var dateFrom = Date()
    @State private var dateToEnabled = false
    @State private var dateTo = Date()
    @State private var minThreadRepliesText = ""
    @State private var maxThreadRepliesText = ""
    @State private var batchSizeText = "100"

    /// The live preview count, kept separate from `viewModel.poolState` (which is only
    /// meaningful once a batch has actually been created/opened) — this is purely "how
    /// many posts match the frame I'm building right now", before anything is drawn.
    @State private var matchingCount: Int?
    @State private var matchingCountError: String?

    /// Snapshot of the outcome of the most recent "Create batch" tap, taken right after
    /// `viewModel.createBatch` returns. Deliberately NOT read live off
    /// `viewModel.loadState`/`poolState` on every render — those are shared with
    /// `LabellingSessionView` (same view model instance) and get overwritten by
    /// `openBatch`, so reading them live here would let a completely unrelated "Continue"
    /// action in the session view silently repaint this screen's create-outcome banner.
    private enum CreateOutcome: Equatable {
        case failed(String)
        case empty
        case exhausted
        case created
    }
    @State private var lastCreateOutcome: CreateOutcome?
    @State private var isCreating = false

    @State private var secondPassError: String?
    @State private var agreementBatch: LabelBatch?
    @State private var agreementReport: AgreementReport?
    @State private var agreementError: String?

    private var previewKey: String {
        [
            "\(isUniformRandom)",
            selectedOutletDID ?? "",
            "\(dateFromEnabled)", dateFromEnabled ? "\(dateFrom.timeIntervalSince1970)" : "",
            "\(dateToEnabled)", dateToEnabled ? "\(dateTo.timeIntervalSince1970)" : "",
            minThreadRepliesText, maxThreadRepliesText
        ].joined(separator: "|")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                poolBuilder
                if let outcome = lastCreateOutcome {
                    createOutcomeBanner(outcome)
                }
                Divider().background(Color.neutralBorder)
                batchListSection
            }
            .padding(.bottom, 16)
        }
        .background(Color.appBackground)
        .task(id: previewKey) { await updatePreview() }
        .sheet(item: $agreementBatch) { batch in
            agreementSheet(for: batch)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Labelling")
                .font(.title2)
                .foregroundStyle(Color.primaryText)
            Text("Draw a batch of replies for human labelling, or continue one already in progress")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - Pool builder

    private var poolBuilder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New batch")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)

            HStack(spacing: 8) {
                Button {
                    isUniformRandom = true
                } label: {
                    Text("Uniform random (Stage 0)")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(isUniformRandom ? Color.selectedBackground : Color.panelBackground)

                Button {
                    isUniformRandom = false
                } label: {
                    Text("Filtered")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(isUniformRandom ? Color.panelBackground : Color.selectedBackground)
            }

            if !isUniformRandom {
                filterFields
            }

            HStack(spacing: 12) {
                Text(previewText)
                    .font(.caption)
                    .foregroundStyle(matchingCountError != nil ? Color.hateBorder : Color.secondaryText)
                Spacer()
                Text("Batch size")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
                TextField("100", text: $batchSizeText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 50)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.appBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button {
                    Task { await createBatch() }
                } label: {
                    if isCreating {
                        ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                    } else {
                        Text("Create batch")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.counterBorder)
                .disabled(isCreating)
            }
        }
        .padding(12)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    private var previewText: String {
        if let matchingCountError { return "Could not count matches: \(matchingCountError)" }
        if let matchingCount { return "\(matchingCount) matching posts" }
        return "Counting matching posts…"
    }

    private var filterFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Outlet", selection: $selectedOutletDID) {
                Text("All outlets").tag(String?.none)
                ForEach(accounts) { account in
                    Text(account.handle).tag(String?.some(account.did))
                }
            }
            .frame(width: 220)

            HStack(spacing: 12) {
                Toggle("From", isOn: $dateFromEnabled)
                    .font(.system(size: 11))
                if dateFromEnabled {
                    DatePicker("", selection: $dateFrom, displayedComponents: .date)
                        .labelsHidden()
                }
                Toggle("To", isOn: $dateToEnabled)
                    .font(.system(size: 11))
                if dateToEnabled {
                    DatePicker("", selection: $dateTo, displayedComponents: .date)
                        .labelsHidden()
                }
            }

            HStack(spacing: 6) {
                Text("Thread size")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
                TextField("min", text: $minThreadRepliesText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 44)
                    .padding(4)
                    .background(Color.appBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text("–").foregroundStyle(Color.mutedText)
                TextField("max", text: $maxThreadRepliesText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 44)
                    .padding(4)
                    .background(Color.appBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Create outcome banners

    /// Three visually and textually distinct outcomes — conflating any two of these
    /// would misrepresent a different fact than what actually happened (see
    /// `LabellingViewModel.PoolState`'s own doc comment on why `.empty` and `.exhausted`
    /// must never be merged).
    @ViewBuilder
    private func createOutcomeBanner(_ outcome: CreateOutcome) -> some View {
        switch outcome {
        case .failed(let message):
            banner(icon: "exclamationmark.triangle", iconColor: Color.hateBorder,
                   title: "Could not open the store", detail: message,
                   background: Color.hateBackground)
        case .empty:
            banner(icon: "magnifyingglass", iconColor: Color.mutedText,
                   title: "No matching posts",
                   detail: "Nothing in the store matches this frame. Widen the filters and try again.",
                   background: Color.neutralBackground)
        case .exhausted:
            banner(icon: "checkmark.seal", iconColor: Color.counterBorder,
                   title: "Pool exhausted",
                   detail: "All matching posts have already been drawn into an earlier batch.",
                   background: Color.neutralBackground)
        case .created:
            EmptyView()
        }
    }

    private func banner(icon: String, iconColor: Color, title: String, detail: String,
                         background: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primaryText)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
        }
        .padding(12)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    // MARK: - Batch list

    private var batchListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Batches")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondaryText)
                .padding(.horizontal, 16)

            if batches.isEmpty {
                Text("No batches yet — create one above.")
                    .font(.caption)
                    .foregroundStyle(Color.mutedText)
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(batches) { batch in
                        batchRow(batch)
                    }
                }
                .padding(.horizontal, 16)
            }

            if let secondPassError {
                Text("Could not create second pass: \(secondPassError)")
                    .font(.caption)
                    .foregroundStyle(Color.hateBorder)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func batchRow(_ batch: LabelBatch) -> some View {
        let hasSecondPass = batches.contains { $0.sourceBatchID == batch.id }
        let completedSecondPass = batches.first { $0.sourceBatchID == batch.id && $0.completedAt != nil }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LabellingFormatting.frameSummary(batch.frame))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primaryText)
                    Text("\(LabellingFormatting.passLabel(batch.passNumber)) · " +
                         LabellingFormatting.batchProgressSummary(
                             labelled: batch.labelledURIs.count, drawn: batch.drawnURIs.count) +
                         " · created \(batch.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Button("Continue") {
                    Task {
                        guard let reader = try? AggregateReader() else { return }
                        await viewModel.openBatch(batch.id, reader: reader)
                    }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))

                if batch.passNumber == 1 && batch.completedAt != nil && !hasSecondPass {
                    Button("Create second pass") {
                        do {
                            secondPassError = nil
                            _ = try viewModel.createSecondPass(of: batch.id, context: modelContext)
                        } catch {
                            secondPassError = String(describing: error)
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                }

                if completedSecondPass != nil {
                    Button("Show agreement") {
                        agreementError = nil
                        agreementReport = nil
                        do {
                            agreementReport = try viewModel.agreement(batchID: batch.id, context: modelContext)
                        } catch {
                            agreementError = String(describing: error)
                        }
                        agreementBatch = batch
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(10)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Agreement sheet

    @ViewBuilder
    private func agreementSheet(for batch: LabelBatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Intra-rater agreement")
                .font(.headline)
                .foregroundStyle(Color.primaryText)
            if let agreementError {
                Text("Could not compute agreement: \(agreementError)")
                    .font(.caption)
                    .foregroundStyle(Color.hateBorder)
            } else if let agreementReport {
                Text(LabellingFormatting.agreementSummary(agreementReport))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primaryText)
            } else {
                Text("No overlapping labelled posts between the two passes yet.")
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
            Button("Close") { agreementBatch = nil }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(minWidth: 360)
        .background(Color.panelBackground)
    }

    // MARK: - Frame resolution + I/O

    private func draftFrame(outletPK: Int64?) -> SamplingFrame {
        LabellingFormatting.buildFrame(
            uniformRandom: isUniformRandom,
            outletPK: outletPK,
            dateFrom: dateFromEnabled ? dateFrom : nil,
            dateTo: dateToEnabled ? dateTo : nil,
            minThreadReplies: LabellingFormatting.parseOptionalInt(minThreadRepliesText),
            maxThreadReplies: LabellingFormatting.parseOptionalInt(maxThreadRepliesText))
    }

    /// Resolves the currently-selected outlet DID to its internal `Z_PK`, off-main —
    /// same reasoning as `AuthorListView.reload()`'s debounce: this always runs against
    /// the live store, never on the main actor.
    private func resolvedOutletPK(reader: AggregateReader) async -> Int64? {
        guard !isUniformRandom, let did = selectedOutletDID else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? reader.accountPK(did: did)
        }.value ?? nil
    }

    private func updatePreview() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        guard let reader = try? AggregateReader() else {
            matchingCount = nil
            matchingCountError = "Could not open the store."
            return
        }
        let outletPK = await resolvedOutletPK(reader: reader)
        guard !Task.isCancelled else { return }
        let frame = draftFrame(outletPK: outletPK)
        let result: (count: Int?, error: String?) = await Task.detached(priority: .userInitiated) {
            do { return (try reader.labellingPoolCount(frame: frame), nil) }
            catch { return (nil, String(describing: error)) }
        }.value
        guard !Task.isCancelled else { return }
        matchingCount = result.count
        matchingCountError = result.error
    }

    private func createBatch() async {
        isCreating = true
        lastCreateOutcome = nil
        defer { isCreating = false }

        guard let reader = try? AggregateReader() else {
            lastCreateOutcome = .failed("Could not open the store.")
            return
        }
        let outletPK = await resolvedOutletPK(reader: reader)
        let frame = draftFrame(outletPK: outletPK)
        let size = LabellingFormatting.parseBatchSize(batchSizeText)

        await viewModel.createBatch(frame: frame, size: size, reader: reader)

        switch viewModel.loadState {
        case .failed(let message):
            lastCreateOutcome = .failed(message)
        case .loaded:
            switch viewModel.poolState {
            case .empty: lastCreateOutcome = .empty
            case .exhausted: lastCreateOutcome = .exhausted
            case .available: lastCreateOutcome = .created
            case .unknown: lastCreateOutcome = nil
            }
        case .idle, .loading:
            break
        }
    }
}
