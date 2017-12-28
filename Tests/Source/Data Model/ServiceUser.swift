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

public extension ServiceUser {
    fileprivate func requestToAddService(to conversation: ZMConversation) -> ZMTransportRequest {
        guard let remoteIdentifier = conversation.remoteIdentifier else {
            fatal("conversation is not synced with the backend")
        }
        
        let path = "/conversations/\(remoteIdentifier.transportString())/bots"
        
        let payload: NSDictionary = ["provider": self.providerIdentifier,
                                     "service": self.serviceIdentifier,
                                     "locale": NSLocale.formattedLocaleIdentifier()]
        
        return ZMTransportRequest(path: path, method: .methodPOST, payload: payload as ZMTransportData)
    }
    
    public func startConversation(in userSession: ZMUserSession, completion: ((ZMConversation)->())?) {
        let selfUser = ZMUser.selfUser(in: userSession.managedObjectContext)
        
        let conversation = ZMConversation.insertNewObject(in: userSession.managedObjectContext)
        conversation.lastModifiedDate = Date()
        conversation.conversationType = .group
        conversation.creator = selfUser
        conversation.team = selfUser.team
        var onCreatedRemotelyToken: NSObjectProtocol? = nil
        
        _ = onCreatedRemotelyToken; // remove warning
        
        onCreatedRemotelyToken = conversation.onCreatedRemotely {
            
            let request = self.requestToAddService(to: conversation)
            
            request.add(ZMCompletionHandler(on: userSession.managedObjectContext, block: { (response) in
                print(response)
                completion?(conversation)
            }))
            
            // TODO: abusing search requests here
            userSession.transportSession.enqueueSearch(request)
            
            onCreatedRemotelyToken = nil
        }

        userSession.managedObjectContext.saveOrRollback()
    }
}
