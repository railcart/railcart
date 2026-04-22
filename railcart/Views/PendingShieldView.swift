//
//  PendingShieldView.swift
//  railcart
//
//  Middle section between public and private balance cards. Surfaces every
//  owned UTXO that isn't yet spendable so users can see "why isn't my money
//  there yet?" answers — freshly submitted shields (1-hour PPOI window),
//  received transacts that need a POI proof, and imported/legacy wallet
//  UTXOs with no local transaction record.
//

import SwiftUI

/// Unified row model. Driven by either a local shield transaction (countdown)
/// or a scanner-derived pending UTXO group (bucket status text).
struct PendingPOIRow: Identifiable {
    enum Indicator {
        /// Freshly submitted shield — show a 1-hour countdown from submit time.
        case countdown(since: Date)
        /// Scanner has seen the UTXO but POI hasn't cleared — show bucket label.
        case status(String, systemImage: String)
    }

    let id: String
    let token: Token?
    let tokenDisplay: String  // used when `token` is nil
    let amountRaw: String     // smallest-unit string
    let actionLabel: String   // "Shield" / "Received" / "Transfer"
    let actionColor: Color
    let txHash: String
    let indicator: Indicator
}

struct PendingShieldView: View {
    let rows: [PendingPOIRow]
    /// Current POI node query state for this chain. Drives the header label
    /// and retry button.
    var poiStatus: NativeScannerService.POIFetchStatus = .idle
    /// User-initiated retry. Nil hides the retry button (e.g. for previews).
    var onRetry: (() -> Void)? = nil
    /// Whether any row is a "Missing POI proof" bucket we can submit for.
    var canGenerateProofs: Bool = false
    /// Current proof-generation state.
    var proofGen: NativeScannerService.POIProofGenStatus = .idle
    /// User-initiated "Submit POI proofs" trigger. Nil hides the button.
    var onGenerateProofs: (() -> Void)? = nil

    /// Flips true the instant the user taps Submit/Retry, so the button
    /// disables immediately instead of waiting for the async `proofGen`
    /// transition to `.running` to catch up.
    @State private var isSubmitting: Bool = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                header(now: context.date)

                if proofGenVisible {
                    proofGenRow(now: context.date)
                }

                ForEach(rows) { row in
                    rowView(row, now: context.date)
                }
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.yellow.opacity(0.06))
                    .strokeBorder(.yellow.opacity(0.2), lineWidth: 1)
            }
            .onChange(of: proofGen) { _, _ in
                isSubmitting = false
            }
        }
    }

    private var proofGenVisible: Bool {
        if onGenerateProofs == nil { return false }
        switch proofGen {
        case .idle: return canGenerateProofs
        case .running, .succeeded, .failed: return true
        }
    }

    /// Expected clearing window for transact POI proofs on the aggregator.
    /// See `POI_SHIELD_PENDING_SEC` in shared-models for the shield equivalent.
    private static let proofClearWindowMin: TimeInterval = 20 * 60
    private static let proofClearWindowMax: TimeInterval = 30 * 60

    @ViewBuilder
    private func proofGenRow(now: Date) -> some View {
        HStack(spacing: 10) {
            switch proofGen {
            case .idle:
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generate POI proofs")
                        .font(.caption.bold())
                    Text("Unlock receive notes by submitting a Proof of Innocence for them.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let onGenerateProofs {
                    submitButton(label: "Submit", action: onGenerateProofs)
                }
            case .running(let progress, let message):
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.isEmpty ? "Generating POI proofs…" : message)
                        .font(.caption.bold())
                    ProgressView(value: progress)
                        .controlSize(.small)
                }
            case .succeeded(let at):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("POI proofs submitted")
                        .font(.caption.bold())
                    Text(clearingHint(submittedAt: at, now: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            case .failed(let message, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("POI proof submission failed")
                        .font(.caption.bold())
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if let onGenerateProofs {
                    submitButton(label: "Retry", action: onGenerateProofs)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func submitButton(label: String, action: @escaping () -> Void) -> some View {
        Button {
            isSubmitting = true
            action()
        } label: {
            if isSubmitting {
                ProgressView().controlSize(.mini)
            } else {
                Text(label)
            }
        }
        .controlSize(.small)
        .disabled(isSubmitting)
    }

    /// Hint shown under "POI proofs submitted" so users know roughly when to
    /// expect proofs to clear on the aggregator. The elapsed-since-submit
    /// prefix is always present so the row stays informative from the moment
    /// of submission through the full validation window.
    private func clearingHint(submittedAt: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(submittedAt)
        let prefix: String
        if elapsed < 60 {
            prefix = "Submitted just now"
        } else {
            prefix = "Submitted \(Int(elapsed / 60))m ago"
        }
        if elapsed < Self.proofClearWindowMin {
            return "\(prefix) · clears in ~20–30 min"
        }
        if elapsed < Self.proofClearWindowMax {
            return "\(prefix) · ready to re-check"
        }
        return "\(prefix) · taking longer than usual"
    }

    @ViewBuilder
    private func header(now: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(.yellow)
                .symbolEffect(.pulse)
            Text("Waiting for Proof of Innocence")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()

            switch poiStatus {
            case .querying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .succeeded(let at):
                HStack(spacing: 6) {
                    Text("Checked \(relative(at, now: now))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    retryButton
                }
            case .failed(let message, _):
                HStack(spacing: 6) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(message)
                    retryButton
                }
            case .idle:
                retryButton
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var retryButton: some View {
        if let onRetry {
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Re-check POI status")
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let m = seconds / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        return "\(h)h ago"
    }

    private func rowView(_ row: PendingPOIRow, now: Date) -> some View {
        HStack(spacing: 12) {
            TokenIconView(assetName: row.token?.iconAsset ?? Token.eth.iconAsset)
                .opacity(0.6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.actionLabel)
                        .font(.caption.bold())
                        .foregroundStyle(row.actionColor)
                    Text(formattedAmount(for: row))
                        .font(.caption.monospaced().bold())
                }
                HStack(spacing: 4) {
                    Text(shortHash(row.txHash))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.txHash, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy transaction hash")
                }
            }

            Spacer()

            indicatorView(row.indicator, now: now)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func indicatorView(_ indicator: PendingPOIRow.Indicator, now: Date) -> some View {
        switch indicator {
        case .countdown(let since):
            Text(remaining(since: since, now: now))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .status(let label, let systemImage):
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2)
                Text(label)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func formattedAmount(for row: PendingPOIRow) -> String {
        if let token = row.token {
            return "\(token.formatBalance(row.amountRaw)) \(token.symbol)"
        }
        // Unknown token — show short hash + raw amount.
        let shortToken = shortHash(row.tokenDisplay)
        return "\(row.amountRaw) (\(shortToken))"
    }

    /// PPOI verification typically completes within 60 minutes.
    private static let verificationDuration: TimeInterval = 3600

    private func remaining(since date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        let seconds = max(0, Int(Self.verificationDuration - elapsed))
        let m = seconds / 60
        let s = seconds % 60
        if m >= 60 {
            let h = m / 60
            return String(format: "%d:%02d:%02d", h, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func shortHash(_ hash: String) -> String {
        if hash.count > 14 {
            return String(hash.prefix(8)) + "..." + String(hash.suffix(4))
        }
        return hash
    }
}
