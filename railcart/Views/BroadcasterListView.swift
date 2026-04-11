//
//  BroadcasterListView.swift
//  railcart
//
//  Displays discovered RAILGUN broadcasters and their fee rates.
//

import SwiftUI

struct BroadcasterListView: View {
    @Environment(NodeBridge.self) private var bridge
    @Environment(BroadcasterState.self) private var broadcasterState
    @Environment(NetworkState.self) private var network

    @State private var errorMessage: String?
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            if let errorMessage {
                errorBanner(errorMessage)
            }
            broadcasterListContent
        }
        .frame(minWidth: 500, minHeight: 400)
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Broadcasters")
                    .font(.title2.bold())
                Spacer()
                connectionBadge
            }

            HStack {
                Spacer()
                Button(broadcasterState.isSearching ? "Searching..." : "Search") {
                    Task { await startSearch() }
                }
                .disabled(!bridge.isReady || broadcasterState.isSearching)
            }

            if let stats = broadcasterState.peerStats, stats.started {
                HStack(spacing: 16) {
                    Label("\(stats.meshPeerCount ?? 0) mesh", systemImage: "network")
                    Label("\(stats.pubSubPeerCount ?? 0) pubsub", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    Text("\(broadcasterState.broadcasters.count) broadcaster\(broadcasterState.broadcasters.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(broadcasterState.connectionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: Capsule())
    }

    private var statusColor: Color {
        switch broadcasterState.connectionStatus {
        case "Connected": .green
        case "Searching": .yellow
        case "Error", "AllUnavailable": .red
        default: .gray
        }
    }

    // MARK: - List

    @ViewBuilder
    private var broadcasterListContent: some View {
        if broadcasterState.broadcasters.isEmpty && !broadcasterState.isSearching {
            ContentUnavailableView(
                "No Broadcasters Found",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Select a chain and tap Search to discover RAILGUN broadcasters on the Waku P2P network.")
            )
        } else if broadcasterState.broadcasters.isEmpty && broadcasterState.isSearching {
            VStack {
                ProgressView("Connecting to Waku network...")
                    .padding()
                Text("This may take a moment for peer discovery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else {
            List(groupedBroadcasters, id: \.address) { group in
                Section {
                    ForEach(group.fees, id: \.tokenAddress) { fee in
                        BroadcasterFeeRow(fee: fee)
                    }
                } header: {
                    BroadcasterSectionHeader(group: group)
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
            Spacer()
            Button("Dismiss") { self.errorMessage = nil }
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(8)
        .background(.red.opacity(0.1))
    }

    // MARK: - Grouped data

    private var groupedBroadcasters: [BroadcasterGroup] {
        let grouped = Dictionary(grouping: broadcasterState.broadcasters) { $0.railgunAddress }
        return grouped.map { (address, fees) in
            let shortAddress = String(address.prefix(16)) + "..." + String(address.suffix(8))
            let avgReliability = fees.map(\.reliability).reduce(0, +) / Double(max(fees.count, 1))
            return BroadcasterGroup(
                address: address,
                shortAddress: shortAddress,
                reliability: avgReliability,
                availableWallets: fees.first?.availableWallets ?? 0,
                fees: fees
            )
        }
        .sorted { $0.reliability > $1.reliability }
    }

    // MARK: - Actions

    private func startSearch() async {
        broadcasterState.isSearching = true
        errorMessage = nil
        broadcasterState.broadcasters = []

        bridge.onEvent("broadcasterStatus") { data in
            if let dict = data as? [String: Any],
               let status = dict["status"] as? String {
                broadcasterState.connectionStatus = status
            }
        }

        do {
            let _ = try await bridge.callRaw("startBroadcasterSearch", params: [
                "chainName": network.selectedChain.rawValue,
            ])

            startPolling()
        } catch {
            errorMessage = error.localizedDescription
            broadcasterState.isSearching = false
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                await refreshBroadcasters()
            }
        }
    }

    private func refreshBroadcasters() async {
        do {
            let result = try await bridge.call("getAllBroadcasters", as: BroadcasterListResponse.self)
            broadcasterState.broadcasters = result.broadcasters

            let stats = try await bridge.call("getBroadcasterPeerStats", as: PeerStats.self)
            broadcasterState.peerStats = stats
        } catch {
            // Silently ignore polling errors
        }
    }
}

// MARK: - Subviews

private struct BroadcasterSectionHeader: View {
    let group: BroadcasterGroup

    var body: some View {
        HStack {
            Text(group.shortAddress)
                .font(.caption.monospaced())
            Spacer()
            reliabilityBadge
            Text("\(group.availableWallets) wallet\(group.availableWallets == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var reliabilityBadge: some View {
        let pct = Int(group.reliability * 100)
        let color: Color = group.reliability >= 0.9 ? .green :
                           group.reliability >= 0.75 ? .yellow : .red
        return Text("\(pct)%")
            .font(.caption2.bold())
            .foregroundStyle(color)
    }
}

private struct BroadcasterFeeRow: View {
    let fee: BroadcasterInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(fee.shortTokenAddress)
                    .font(.body.monospaced())
                Text("Fee: \(fee.feePerUnitGas) per unit gas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if fee.isExpired {
                Text("Expired")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                Text(fee.expiresIn)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Models

struct BroadcasterInfo: Decodable, Sendable {
    let railgunAddress: String
    let tokenAddress: String
    let feePerUnitGas: String
    let expiration: Double
    let feesID: String
    let availableWallets: Int
    let relayAdapt: String
    let reliability: Double

    var shortRailgunAddress: String {
        if railgunAddress.count > 16 {
            return String(railgunAddress.prefix(8)) + "..." + String(railgunAddress.suffix(6))
        }
        return railgunAddress
    }

    var shortTokenAddress: String {
        if tokenAddress.count > 12 {
            return String(tokenAddress.prefix(6)) + "..." + String(tokenAddress.suffix(4))
        }
        return tokenAddress
    }

    var isExpired: Bool {
        Date(timeIntervalSince1970: expiration / 1000) < Date()
    }

    var expiresIn: String {
        let expDate = Date(timeIntervalSince1970: expiration / 1000)
        let remaining = expDate.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        let minutes = Int(remaining / 60)
        if minutes < 1 { return "<1m" }
        return "\(minutes)m"
    }
}

struct BroadcasterGroup {
    let address: String
    let shortAddress: String
    let reliability: Double
    let availableWallets: Int
    let fees: [BroadcasterInfo]
}

struct BroadcasterListResponse: Decodable, Sendable {
    let broadcasters: [BroadcasterInfo]
    let chainName: String?
}

struct PeerStats: Decodable, Sendable {
    let started: Bool
    let meshPeerCount: Int?
    let pubSubPeerCount: Int?
    let chainName: String?
}
