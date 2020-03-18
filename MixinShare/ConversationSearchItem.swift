import Foundation
import MixinServices

class ConversationSearchItem {

    let conversationId: String
    let name: String
    let userId: String
    let avatarUrl: String
    let iconUrl: String
    let category: String
    let isBot : Bool
    let isVerified : Bool

    init?(conversation: ConversationItem) {
        if conversation.category == ConversationCategory.CONTACT.rawValue {
            name = conversation.ownerFullName
        } else if conversation.category == ConversationCategory.GROUP.rawValue {
            name = conversation.name
        } else {
            return nil
        }
        category = conversation.category ?? ""
        iconUrl = conversation.iconUrl
        userId = conversation.ownerId
        avatarUrl = conversation.ownerAvatarUrl
        conversationId = conversation.conversationId
        isBot = conversation.ownerIsBot
        isVerified = conversation.ownerIsVerified
    }

    init(user: UserItem) {
        conversationId = ConversationDAO.shared.makeConversationId(userId: myUserId, ownerUserId: user.userId)
        name = user.fullName
        category = ConversationCategory.CONTACT.rawValue
        iconUrl = ""
        userId = user.userId
        avatarUrl = user.avatarUrl
        isBot = user.isBot
        isVerified = user.isVerified
    }

    func matches(lowercasedKeyword keyword: String) -> Bool {
        return name.lowercased().contains(keyword)
    }
}

extension ConversationSearchItem: Equatable {

    static func == (lhs: ConversationSearchItem, rhs: ConversationSearchItem) -> Bool {
        return lhs.conversationId == rhs.conversationId
    }

}

extension ConversationSearchItem: Hashable {

    func hash(into hasher: inout Hasher) {
        hasher.combine(conversationId)
    }

}
