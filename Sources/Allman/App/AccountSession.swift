// One signed-in LinkedIn account: its sync engine (listen + periodic sync),
// its inbox over the store, and the CLI context every call for it uses.
// AppModel owns one of these per account so several people can be signed in
// at once; the inbox window shows one at a time, everything syncs always.

import Foundation
import Observation

@MainActor
@Observable
final class AccountSession: Identifiable {
    /// LinkedIn profile id (the store directory name).
    let id: String
    private(set) var account: Account
    let engine = SyncEngine()
    let inbox: InboxModel
    let context: AllmanRunner.Context

    init(account: Account, reader: StoreReader, storeURL: URL) {
        id = account.profileId
        self.account = account
        inbox = InboxModel(reader: reader, readState: ReadState.load(accountId: account.profileId), organizer: Organizer.load(accountId: account.profileId))
        context = AllmanRunner.Context(storeURL: storeURL, account: account.slug)
    }

    func update(account: Account) { self.account = account }

    var slug: String { account.slug }
    var headline: String? { account.auth.headline?.isEmpty == false ? account.auth.headline : nil }
    var avatarURL: URL? { account.auth.imageUrl.flatMap(URL.init(string:)) }
    var isAuthenticated: Bool { account.auth.isAuthenticated }

    /// AUTH.json may lack a name until `allman whoami` runs; our own sent messages carry it.
    var displayName: String {
        if let n = account.auth.name, !n.isEmpty { return n }
        if let mine = inbox.snapshots.lazy.compactMap({ $0.lastMessage }).first(where: { $0.isFromMe && !($0.fromName ?? "").isEmpty }) {
            return mine.fromName!
        }
        return account.slug
    }

    var unreadCount: Int { inbox.unreadCount }
}
