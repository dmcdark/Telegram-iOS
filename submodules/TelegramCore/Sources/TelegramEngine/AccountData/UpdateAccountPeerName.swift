import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

// Development-only profile color preview. The selected colors are written to
// the local account cache but are never submitted to Telegram's servers.
private let locallyPreviewProfileColors = true

// This is deliberately account-local: the development preview must survive
// ordinary peer updates, but must never be uploaded or used for other peers.
enum LocalPeerColor: Codable {
    case preset(Int32)
    case collectible(PeerCollectibleColor)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case collectible
    }

    private enum Kind: String, Codable {
        case preset
        case collectible
    }

    init(_ color: PeerColor) {
        switch color {
        case let .preset(color):
            self = .preset(color.rawValue)
        case let .collectible(color):
            self = .collectible(color)
        }
    }

    var peerColor: PeerColor {
        switch self {
        case let .preset(value):
            return .preset(PeerNameColor(rawValue: value))
        case let .collectible(color):
            return .collectible(color)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .preset:
            self = .preset(try container.decode(Int32.self, forKey: .value))
        case .collectible:
            self = .collectible(try container.decode(PeerCollectibleColor.self, forKey: .collectible))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .preset(value):
            try container.encode(Kind.preset, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .collectible(color):
            try container.encode(Kind.collectible, forKey: .kind)
            try container.encode(color, forKey: .collectible)
        }
    }
}

struct LocalProfileAppearance: Codable {
    let peerId: Int64
    let nameColor: LocalPeerColor
    let backgroundEmojiId: Int64?
    let profileColor: Int32?
    let profileBackgroundEmojiId: Int64?
}

func localProfileAppearancePreferencesKey() -> ValueBoxKey {
    return applicationSpecificPreferencesKey(510)
}

func shouldUseLocalProfileAppearance() -> Bool {
    return locallyPreviewProfileColors
}


func _internal_updateAccountPeerName(account: Account, firstName: String, lastName: String) -> Signal<Void, NoError> {
    let accountPeerId = account.peerId
    return account.network.request(Api.functions.account.updateProfile(flags: (1 << 0) | (1 << 1), firstName: firstName, lastName: lastName, about: nil))
        |> map { result -> Api.User? in
            return result
        }
        |> `catch` { _ in
            return .single(nil)
        }
        |> mapToSignal { result -> Signal<Void, NoError> in
            return account.postbox.transaction { transaction -> Void in
                if let result = result {
                    updatePeers(transaction: transaction, accountPeerId: accountPeerId, peers: AccumulatedPeers(transaction: transaction, chats: [], users: [result]))
                }
            }
        }
}

public enum UpdateAboutError {
    case generic
}


func _internal_updateAbout(account: Account, about: String?) -> Signal<Void, UpdateAboutError> {
    return account.network.request(Api.functions.account.updateProfile(flags: about == nil ? 0 : (1 << 2), firstName: nil, lastName: nil, about: about))
    |> mapError { _ -> UpdateAboutError in
        return .generic
    }
    |> mapToSignal { apiUser -> Signal<Void, UpdateAboutError> in
        return account.postbox.transaction { transaction -> Void in
            transaction.updatePeerCachedData(peerIds: Set([account.peerId]), update: { _, current in
                if let current = current as? CachedUserData {
                    return current.withUpdatedAbout(about)
                } else {
                    return current
                }
            })
        }
        |> castError(UpdateAboutError.self)
    }
}

public enum UpdateNameColor {
    case preset(color: PeerNameColor, backgroundEmojiId: Int64?)
    case collectible(PeerCollectibleColor)
}

public enum UpdateNameColorAndEmojiError {
    case generic
}

func _internal_updateNameColorAndEmoji(account: Account, nameColor: UpdateNameColor, profileColor: PeerNameColor?, profileBackgroundEmojiId: Int64?) -> Signal<Void, UpdateNameColorAndEmojiError> {
    return account.postbox.transaction { transaction -> Signal<Peer, NoError> in
        guard let peer = transaction.getPeer(account.peerId) as? TelegramUser else {
            return .complete()
        }
        var nameColorValue: PeerColor
        var backgroundEmojiIdValue: Int64?
        switch nameColor {
        case let .preset(color, backgroundEmojiId):
            nameColorValue = .preset(color)
            backgroundEmojiIdValue = backgroundEmojiId
        case let .collectible(collectibleColor):
            nameColorValue = .collectible(collectibleColor)
            backgroundEmojiIdValue = collectibleColor.backgroundEmojiId
        }
        
        if shouldUseLocalProfileAppearance() {
            transaction.setPreferencesEntry(
                key: localProfileAppearancePreferencesKey(),
                value: PreferencesEntry(LocalProfileAppearance(
                    peerId: account.peerId.toInt64(),
                    nameColor: LocalPeerColor(nameColorValue),
                    backgroundEmojiId: backgroundEmojiIdValue,
                    profileColor: profileColor?.rawValue,
                    profileBackgroundEmojiId: profileBackgroundEmojiId
                ))
            )
        }
        updatePeersCustom(transaction: transaction, peers: [peer.withUpdatedNameColor(nameColorValue).withUpdatedBackgroundEmojiId(backgroundEmojiIdValue).withUpdatedProfileColor(profileColor).withUpdatedProfileBackgroundEmojiId(profileBackgroundEmojiId)], update: { _, updated in
            return updated
        })
        return .single(peer)
    }
    |> switchToLatest
    |> castError(UpdateNameColorAndEmojiError.self)
    |> mapToSignal { _ -> Signal<Void, UpdateNameColorAndEmojiError> in
        if shouldUseLocalProfileAppearance() {
            return .complete()
        }

        let inputRepliesColor: Api.PeerColor
        switch nameColor {
        case let .preset(color, backgroundEmojiId):
            var flags: Int32 = (1 << 0)
            if let _ = backgroundEmojiId {
                flags |= (1 << 1)
            }
            inputRepliesColor = .peerColor(.init(flags: flags, color: color.rawValue, backgroundEmojiId: backgroundEmojiId))
        case let .collectible(collectibleColor):
            inputRepliesColor = .inputPeerColorCollectible(.init(collectibleId: collectibleColor.collectibleId))
        }
        
        var flagsProfile: Int32 = 0
        if let _ = profileColor {
            flagsProfile |= (1 << 0)
        }
        if let _ = profileBackgroundEmojiId {
            flagsProfile |= (1 << 1)
        }
        
        return combineLatest(
            account.network.request(Api.functions.account.updateColor(flags: (1 << 2), color: inputRepliesColor)),
            account.network.request(Api.functions.account.updateColor(flags: (1 << 1) | (1 << 2), color: .peerColor(.init(flags: flagsProfile, color: profileColor?.rawValue ?? 0, backgroundEmojiId: profileBackgroundEmojiId))))
        )
        |> mapError { _ -> UpdateNameColorAndEmojiError in
            return .generic
        }
        |> mapToSignal { _, _ -> Signal<Void, UpdateNameColorAndEmojiError> in
            return .complete()
        }
    }
}
