import SwiftUI
import UNIDesign
import UNICore

public struct FolderSidebar: View {
    public static let width: CGFloat = 168

    @Environment(\.theme) private var theme
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public var body: some View {
        // ScrollView, não VStack fixa: o usuário pode ter dezenas de contas.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("Pastas")
                ForEach(TriageBucket.allCases, id: \.self) { bucket in
                    bucketRow(bucket)
                }

                if !store.accounts.isEmpty {
                    section("Caixas").padding(.top, 18)
                    ForEach(store.accounts) { account in
                        accountRow(account)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .frame(width: Self.width, alignment: .leading)
        .background(theme.surface2.color)
        .hairline(theme.line, edges: .trailing)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .capsLabel()
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
    }

    private func bucketRow(_ bucket: TriageBucket) -> some View {
        let active = bucket == store.bucket
        return Button { store.select(bucket: bucket) } label: {
            HStack(spacing: 6) {
                Text(bucket.label)
                    .font(theme.sans.font(size: 12.5, weight: active ? .semibold : .regular))
                    .foregroundStyle((active ? theme.ink : theme.ink2).color)
                Spacer(minLength: 4)
                Text("\(store.count(for: bucket))")
                    .font(theme.mono.font(size: 10))
                    .foregroundStyle(theme.ink4.color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                if active {
                    RoundedRectangle(cornerRadius: theme.radiusSmall)
                        .fill(theme.accentSoft.color)
                }
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(TokenColor(css: account.tintHex)?.color ?? theme.ink4.color)
                .frame(width: 7, height: 7)
            Text(account.address)
                .font(theme.sans.font(size: 11.5))
                .foregroundStyle(theme.ink2.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .help(account.address)
    }
}
