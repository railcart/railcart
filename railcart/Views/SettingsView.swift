//
//  SettingsView.swift
//  railcart
//
//  Custom RPC provider configuration per chain.
//

import SwiftUI

struct SettingsView: View {
    @Environment(NetworkState.self) private var network
    @Environment(\.walletService) private var service

    @State private var rpcURLs: [Chain: String] = [:]
    @State private var savedChains: Set<Chain> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(.title2.bold())
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                VStack(spacing: 20) {
                    BalanceCard {
                        HStack {
                            Label("Custom RPC Providers", systemImage: "network")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Spacer()
                            if !network.customRPCURLs.isEmpty {
                                Button("Clear All", role: .destructive) {
                                    network.clearCustomRPCURLs()
                                    for chain in Chain.allCases {
                                        rpcURLs[chain] = ""
                                    }
                                    savedChains = []
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }

                        ForEach(Chain.allCases) { chain in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(chain.displayName)
                                        .font(.subheadline.weight(.medium))
                                    if savedChains.contains(chain) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                            .transition(.opacity)
                                    }
                                    Spacer()
                                    Button("Save") {
                                        Task { await saveProvider(for: chain) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(!isValid(for: chain))
                                }
                                TextField("", text: binding(for: chain), prompt: Text("https://rpc.example.com"))
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .labelsHidden()
                            }

                            if chain != Chain.allCases.last {
                                Divider()
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            for chain in Chain.allCases {
                rpcURLs[chain] = network.customRPCURLs[chain] ?? ""
            }
        }
    }

    private func binding(for chain: Chain) -> Binding<String> {
        Binding(
            get: { rpcURLs[chain, default: ""] },
            set: { rpcURLs[chain] = $0; savedChains.remove(chain) }
        )
    }

    private func isValid(for chain: Chain) -> Bool {
        let text = rpcURLs[chain, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return network.customRPCURLs[chain] != nil }
        guard let url = URL(string: text), let scheme = url.scheme else { return false }
        return scheme == "https" || scheme == "http"
    }

    private func saveProvider(for chain: Chain) async {
        let text = rpcURLs[chain, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            network.removeCustomRPCURL(for: chain)
        } else {
            network.setCustomRPCURL(text, for: chain)
        }
        network.invalidateProvider(for: chain)
        try? await network.ensureProviderLoaded(for: chain, using: service)
        withAnimation { savedChains.insert(chain) }
    }
}
