//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation

fileprivate extension ZMUser {
    func update(with serviceUser: ServiceUser) {
        self.update(withProviderIdentifier: serviceUser.providerIdentifier)
        self.name = serviceUser.name
        self.accentColorValue = serviceUser.accentColorValue
        self.previewProfileAssetIdentifier = serviceUser.imageSmallProfileIdentifier
        self.completeProfileAssetIdentifier = serviceUser.imageMediumIdentifier
    }
}

public extension ServiceUser {
    public func startConversation(in userSession: ZMUserSession, completion: ((ZMConversation)->())?) {
        guard let syncContext = userSession.syncManagedObjectContext else {
            fatal("sync context is not available")
        }
        
        guard let serviceId = UUID(uuidString: self.serviceIdentifier) else {
            fatal("serviceId is not available")
        }
        
        syncContext.performGroupedBlock {
            
            let syncSelfUser = ZMUser.selfUser(in: syncContext)
            let syncBotUser = ZMUser(remoteID: serviceId,
                                     isService: true,
                                     createIfNeeded: true,
                                     in: syncContext)!
            
            syncBotUser.update(with: self)

            let syncConversation = ZMConversation.insertNewObject(in: syncContext)
            syncConversation.lastModifiedDate = Date()
            syncConversation.conversationType = .group
            syncConversation.creator = syncSelfUser
            syncConversation.team = syncSelfUser.team
            
            syncConversation.internalAddParticipants(Set(arrayLiteral: syncBotUser), isAuthoritative: false)
            
            syncConversation.appendNewConversationSystemMessageIfNeeded()
            
            syncContext.saveOrRollback()
            let syncConversationID = syncConversation.objectID
            guard !syncConversationID.isTemporaryID else {
                fatal("conversation failed to save")
            }
            
            userSession.managedObjectContext.performGroupedBlock {
                guard let object = try? userSession.managedObjectContext.existingObject(with: syncConversationID),
                        let uiConversation = object as? ZMConversation else {
                    fatal("cannot fetch conversation")
                }
                completion?(uiConversation)
            }
        }
    }
}
