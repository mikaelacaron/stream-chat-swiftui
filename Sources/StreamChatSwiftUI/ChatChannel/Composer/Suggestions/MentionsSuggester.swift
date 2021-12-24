//
// Copyright © 2021 Stream.io Inc. All rights reserved.
//

import Combine
import StreamChat
import SwiftUI

public struct MentionsSuggester: CommandHandler {
    
    let id: String = "mentions"
    
    // TODO: read from config
    private var mentionAllAppUsers = false
    private let typingSuggester = TypingSuggester(options: .init(symbol: "@"))
    
    private let channelController: ChatChannelController
    private let userSearchController: ChatUserSearchController
        
    init(channelController: ChatChannelController) {
        self.channelController = channelController
        userSearchController = channelController.client.userSearchController()
    }
    
    func canHandleCommand(in text: String, caretLocation: Int) -> ComposerCommand? {
        if let suggestion = typingSuggester.typingSuggestion(
            in: text,
            caretLocation: caretLocation
        ) {
            return ComposerCommand(id: id, typingSuggestion: suggestion)
        } else {
            return nil
        }
    }
    
    func handleCommand(
        for text: Binding<String>,
        selectedRangeLocation: Binding<Int>,
        command: Binding<ComposerCommand?>,
        extraData: [String: Any]
    ) {
        guard let chatUser = extraData["chatUser"] as? ChatUser,
              let typingSuggestionValue = command.wrappedValue?.typingSuggestion else {
            return
        }
        
        let mentionText = self.mentionText(for: chatUser)
        let newText = (text.wrappedValue as NSString).replacingCharacters(
            in: typingSuggestionValue.locationRange,
            with: mentionText
        )
        text.wrappedValue = newText

        let newCaretLocation =
            selectedRangeLocation.wrappedValue + (mentionText.count - typingSuggestionValue.text.count)
        selectedRangeLocation.wrappedValue = newCaretLocation
        command.wrappedValue = nil
    }
    
    func showSuggestions(
        for command: ComposerCommand
    ) -> Future<SuggestionInfo, Never> {
        showMentionSuggestions(
            for: command.typingSuggestion.text,
            mentionRange: command.typingSuggestion.locationRange
        )
    }
    
    // MARK: - private
    
    private func showMentionSuggestions(
        for typingMention: String,
        mentionRange: NSRange
    ) -> Future<SuggestionInfo, Never> {
        guard let channel = channelController.channel,
              let currentUserId = channelController.client.currentUserId else {
            return resolve(with: SuggestionInfo(key: "", value: []))
        }

        if mentionAllAppUsers {
            return searchAllUsers(for: typingMention)
        } else {
            let users = searchUsers(
                channel.lastActiveWatchers.map { $0 } + channel.lastActiveMembers.map { $0 },
                by: typingMention,
                excludingId: currentUserId
            )
            let suggestionInfo = SuggestionInfo(key: id, value: users)
            return resolve(with: suggestionInfo)
        }
    }
        
    /// searchUsers does an autocomplete search on a list of ChatUser and returns users with `id` or `name` containing the search string
    /// results are returned sorted by their edit distance from the searched string
    /// distance is calculated using the levenshtein algorithm
    /// both search and name strings are normalized (lowercased and by replacing diacritics)
    private func searchUsers(_ users: [ChatUser], by searchInput: String, excludingId: String? = nil) -> [ChatUser] {
        let normalize: (String) -> String = {
            $0.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        }

        let searchInput = normalize(searchInput)

        let matchingUsers = users.filter { $0.id != excludingId }
            .filter { searchInput == "" || $0.id.contains(searchInput) || (normalize($0.name ?? "").contains(searchInput)) }

        let distance: (ChatUser) -> Int = {
            min($0.id.levenshtein(searchInput), $0.name?.levenshtein(searchInput) ?? 1000)
        }

        return Array(Set(matchingUsers)).sorted {
            /// a tie breaker is needed here to avoid results from flickering
            let dist = distance($0) - distance($1)
            if dist == 0 {
                return $0.id < $1.id
            }
            return dist < 0
        }
    }
    
    private func queryForMentionSuggestionsSearch(typingMention term: String) -> UserListQuery {
        UserListQuery(
            filter: .or([
                .autocomplete(.name, text: term),
                .autocomplete(.id, text: term)
            ]),
            sort: [.init(key: .name, isAscending: true)]
        )
    }
        
    private func mentionText(for user: ChatUser) -> String {
        if let name = user.name, !name.isEmpty {
            return name
        } else {
            return user.id
        }
    }
    
    private func resolve(with users: SuggestionInfo) -> Future<SuggestionInfo, Never> {
        Future { promise in
            promise(.success(users))
        }
    }
    
    private func searchAllUsers(for typingMention: String) -> Future<SuggestionInfo, Never> {
        Future { promise in
            let query = queryForMentionSuggestionsSearch(typingMention: typingMention)
            userSearchController.search(query: query) { _ in
                let users = Array(userSearchController.users)
                let suggestionInfo = SuggestionInfo(key: id, value: users)
                promise(.success(suggestionInfo))
            }
        }
    }
}
