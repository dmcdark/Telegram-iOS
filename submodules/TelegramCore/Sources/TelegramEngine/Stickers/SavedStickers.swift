import Foundation
import Postbox
import TelegramApi
import SwiftSignalKit

public enum SavedStickerResult {
    case generic
    case limitExceeded(Int32, Int32)
}

func _internal_toggleStickerSaved(postbox: Postbox, network: Network, accountPeerId: PeerId, file: TelegramMediaFile, saved: Bool) -> Signal<SavedStickerResult, AddSavedStickerError> {
    if saved {
        return postbox.transaction { transaction -> Signal<SavedStickerResult, AddSavedStickerError> in
            let items = transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.CloudSavedStickers)
            
            let appConfiguration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? .defaultValue
            let premiumLimitsConfiguration = UserLimitsConfiguration(appConfiguration: appConfiguration, isPremium: true)
            
            let result: SavedStickerResult
            if items.count >= premiumLimitsConfiguration.maxFavedStickerCount {
                result = .limitExceeded(premiumLimitsConfiguration.maxFavedStickerCount, premiumLimitsConfiguration.maxFavedStickerCount)
            } else {
                result = .generic
            }
            
            return addSavedSticker(postbox: postbox, network: network, file: file, limit: Int(premiumLimitsConfiguration.maxFavedStickerCount))
            |> map { _ -> SavedStickerResult in
                return .generic
            }
            |> filter { _ in
                return false
            }
            |> then(
                .single(result)
            )
        }
        |> castError(AddSavedStickerError.self)
        |> switchToLatest
    } else {
        return removeSavedSticker(postbox: postbox, mediaId: file.fileId)
        |> map { _ -> SavedStickerResult in
            return .generic
        }
        |> castError(AddSavedStickerError.self)
    }
}
