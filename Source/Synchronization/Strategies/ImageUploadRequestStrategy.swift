//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
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

open class ImageUploadRequestStrategy: ZMObjectSyncStrategy, RequestStrategy, ZMContextChangeTrackerSource {
    
    fileprivate let imagePreprocessor : ZMImagePreprocessingTracker
    fileprivate let authenticationStatus : AuthenticationStatusProvider
    fileprivate let requestFactory : ClientMessageRequestFactory = ClientMessageRequestFactory()
    fileprivate weak var clientRegistrationStatus : ZMClientRegistrationStatus?
    fileprivate var upstreamSync : ZMUpstreamModifiedObjectSync!
    
    
    public init(authenticationStatus: AuthenticationStatusProvider, clientRegistrationStatus: ZMClientRegistrationStatus, managedObjectContext: NSManagedObjectContext) {
        self.authenticationStatus = authenticationStatus
        self.clientRegistrationStatus = clientRegistrationStatus
        
        let fetchPredicate = NSPredicate(format: "delivered == NO")
        let needsProcessingPredicate = NSPredicate(format: "(mediumGenericMessage.image.width == 0 || previewGenericMessage.image.width == 0) && delivered == NO")
        self.imagePreprocessor = ZMImagePreprocessingTracker(managedObjectContext: managedObjectContext,
                                                             imageProcessingQueue: OperationQueue(),
                                                             fetchPredicate: fetchPredicate,
                                                             needsProcessingPredicate: needsProcessingPredicate,
                                                             entityClass: ZMAssetClientMessage.self)
        
        super.init(managedObjectContext: managedObjectContext)
        
        let insertPredicate = NSPredicate(format: "\(ZMAssetClientMessageUploadedStateKey) != \(ZMAssetUploadState.Done.rawValue)")
        let uploadFilter = NSPredicate { (object : AnyObject, _) -> Bool in
            guard let message = object as? ZMAssetClientMessage else { return false }
            return message.imageMessageData != nil &&
                (message.uploadState == .UploadingPlaceholder || message.uploadState == .UploadingFullAsset) &&
                message.imageAssetStorage?.mediumGenericMessage?.image.width != 0 &&
                message.imageAssetStorage?.previewGenericMessage?.image.width != 0
        }
        
        upstreamSync = ZMUpstreamModifiedObjectSync(transcoder: self,
                                                    entityName: ZMAssetClientMessage.entityName(),
                                                    updatePredicate:insertPredicate,
                                                    filter: uploadFilter,
                                                    keysToSync: nil,
                                                    managedObjectContext: managedObjectContext)
    }
    
    open var contextChangeTrackers: [ZMContextChangeTracker] {
        return [imagePreprocessor, upstreamSync]
    }
    
    open func nextRequest() -> ZMTransportRequest? {
        guard self.authenticationStatus.currentPhase == .authenticated else { return nil }
        return self.upstreamSync.nextRequest()
    }
}

extension ImageUploadRequestStrategy : ZMUpstreamTranscoder {
    
    public func requestForInsertingObject(_ managedObject: ZMManagedObject, forKeys keys: Set<NSObject>?) -> ZMUpstreamRequest? {
        return nil // no-op
    }
    
    public func dependentObjectNeedingUpdateBeforeProcessingObject(_ dependant: ZMManagedObject) -> ZMManagedObject? {
        guard let message = dependant as? ZMMessage else { return nil }
        return message.dependendObjectNeedingUpdateBeforeProcessing()
    }
    
    fileprivate func update(_ message: ZMAssetClientMessage, withResponse response: ZMTransportResponse, updatedKeys keys: Set<NSObject>) {
        message.markAsSent()
        message.updateWithPostPayload(response.payload.asDictionary(), updatedKeys: keys)
        
        if let clientRegistrationStatus = self.clientRegistrationStatus {
            message.parseUploadResponse(response, clientDeletionDelegate: clientRegistrationStatus)
        }
    }
    
    public func updateInsertedObject(_ managedObject: ZMManagedObject, request upstreamRequest: ZMUpstreamRequest, response: ZMTransportResponse) {
        guard let message = managedObject as? ZMAssetClientMessage else { return }
        update(message, withResponse: response, updatedKeys: Set())
    }
    
    public func updateUpdatedObject(_ managedObject: ZMManagedObject, requestUserInfo: [AnyHashable: Any]?, response: ZMTransportResponse, keysToParse: Set<NSObject>) -> Bool {
        guard let message = managedObject as? ZMAssetClientMessage else { return false }
        
        update(message, withResponse: response, updatedKeys: keysToParse)
        
        var needsMoreRequests = false
        
        if keysToParse.contains(ZMAssetClientMessageUploadedStateKey) {
            switch message.uploadState {
            case .UploadingPlaceholder:
                message.uploadState = .UploadingFullAsset
                managedObjectContext.zm_imageAssetCache.deleteAssetData(message.nonce, format: .Preview, encrypted: false)
                managedObjectContext.zm_imageAssetCache.deleteAssetData(message.nonce, format: .Preview, encrypted: true)
                needsMoreRequests = true // want to upload full asset
            case .UploadingFullAsset:
                message.uploadState = .Done
                if let assetId = response.headers["Location"] as? String {
                    message.assetId = UUID.uuidWithTransportString(assetId)
                }
                message.managedObjectContext?.zm_imageAssetCache.deleteAssetData(message.nonce, format: .Medium, encrypted: true)
                message.resetLocallyModifiedKeys(Set(arrayLiteral: ZMAssetClientMessageUploadedStateKey))
            default:
                break
            }
        }
        
        return needsMoreRequests
    }
    
    public func requestForUpdatingObject(_ managedObject: ZMManagedObject, forKeys keys: Set<NSObject>) -> ZMUpstreamRequest? {
        guard let message = managedObject as? ZMAssetClientMessage, let conversation = message.conversation else { return nil }
        
        let format = imageFormatForKeys(keys, message: message)
        
        if format == .Invalid {
            ZMTrapUnableToGenerateRequest(keys, self)
            return nil
        }
        
        guard let request = requestFactory.upstreamRequestForAssetMessage(format, message: message, forConversationWithId: conversation.remoteIdentifier) else {
            // We will crash, but we should still delete the image
            message.managedObjectContext?.deleteObject(message)
            managedObjectContext.saveOrRollback()
            return nil
        }
        
        request.addCompletionHandler(ZMCompletionHandler(onGroupQueue: managedObjectContext, block: { [weak self] (response) in
            if response.result == .Success {
                message.markAsSent()
                ZMOperationLoop.notifyNewRequestsAvailable(self)
            }
        }))
        
        return ZMUpstreamRequest(keys: Set(arrayLiteral: ZMAssetClientMessageUploadedStateKey), transportRequest: request)        
    }
    
    public func shouldCreateRequestToSyncObject(_ managedObject: ZMManagedObject, forKeys keys: Set<String>, withSync sync: AnyObject) -> Bool {
        guard let message = managedObject as? ZMAssetClientMessage, let imageAssetStorage = message.imageAssetStorage  else { return false }
        
        let format = imageFormatForKeys(keys, message: message)
        
        if format == .Invalid {
            return true // We will ultimately crash here when trying to create the request
        }
        
        if imageAssetStorage.shouldReprocessForFormat(format) {
            // before we create an upstream request we should check if we can (and should) process image data again
            // if we can we reschedule processing
            // this might cause a loop if the message can not be processed whatsoever
            scheduleImageProcessing(forMessage: message, format: format)
            managedObjectContext.saveOrRollback()
            return false
        }
        
        return true
    }
    
    public func shouldRetryToSyncAfterFailedToUpdateObject(_ managedObject: ZMManagedObject, request upstreamRequest: ZMUpstreamRequest, response: ZMTransportResponse, keysToParse keys: Set<NSObject>) -> Bool {
        guard let message = managedObject as? ZMAssetClientMessage, let clientRegistrationStatus = self.clientRegistrationStatus else { return false }
     
        let shouldRetry = message.parseUploadResponse(response, clientDeletionDelegate: clientRegistrationStatus)
        if !shouldRetry {
            message.uploadState = .UploadingFailed
        }
        return shouldRetry
    }
    
    public func objectToRefetchForFailedUpdateOfObject(_ managedObject: ZMManagedObject) -> ZMManagedObject? {
        return nil
    }
    
    public func shouldProcessUpdatesBeforeInserts() -> Bool {
        return false
    }
    
    func imageFormatForKeys(_ keys: Set<NSObject>, message: ZMAssetClientMessage) -> ZMImageFormat {
        var format : ZMImageFormat = .invalid
        
        if keys.contains(ZMAssetClientMessageUploadedStateKey) {
            switch message.uploadState {
            case .UploadingPlaceholder:
                format = .preview
                
            case .UploadingFullAsset:
                format = .medium
            default:
                break
            }
        }
        
        return format
    }
    
    func scheduleImageProcessing(forMessage message: ZMAssetClientMessage, format : ZMImageFormat) {
        let genericMessage = ZMGenericMessage(mediumImageProperties: nil, processedImageProperties: nil, encryptionKeys: nil, nonce: message.nonce.transportString(), format: format)
        message.addGenericMessage(genericMessage)
        ZMOperationLoop.notifyNewRequestsAvailable(self)
    }
    
}
