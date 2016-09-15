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
import zimages
import ZMTransport

@objc public final class AssetDownloadRequestStrategyNotification: NSObject {
    public static let downloadFinishedNotificationName = "AssetDownloadRequestStrategyDownloadFinishedNotificationName"
    public static let downloadStartTimestampKey = "requestStartTimestamp"
    public static let downloadFailedNotificationName = "AssetDownloadRequestStrategyDownloadFailedNotificationName"
}

@objc public final class AssetDownloadRequestStrategy: NSObject, RequestStrategy, ZMDownstreamTranscoder, ZMContextChangeTrackerSource {
    
    fileprivate var assetDownstreamObjectSync: ZMDownstreamObjectSync!
    fileprivate let managedObjectContext: NSManagedObjectContext
    fileprivate let authStatus: AuthenticationStatusProvider
    fileprivate weak var taskCancellationProvider: ZMRequestCancellation?
    
    public init(authStatus: AuthenticationStatusProvider, taskCancellationProvider: ZMRequestCancellation, managedObjectContext: NSManagedObjectContext) {
        self.managedObjectContext = managedObjectContext
        self.authStatus = authStatus
        self.taskCancellationProvider = taskCancellationProvider
        super.init()
        registerForCancellationNotification()
        
        let downstreamPredicate = NSPredicate(format: "transferState == %d AND assetId_data != nil", ZMFileTransferState.Downloading.rawValue)
        
        self.assetDownstreamObjectSync = ZMDownstreamObjectSync(
            transcoder: self,
            entityName: ZMAssetClientMessage.entityName(),
            predicateForObjectsToDownload: downstreamPredicate,
            filter: NSPredicate(format: "fileMessageData != nil"),
            managedObjectContext: managedObjectContext
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func registerForCancellationNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(AssetDownloadRequestStrategy.cancelOngoingRequestForAssetClientMessage(_:)), name: ZMAssetClientMessageDidCancelFileDownloadNotificationName, object: nil)
    }
    
    func cancelOngoingRequestForAssetClientMessage(_ note: Notification) {
        guard let objectID = note.object as? NSManagedObjectID else { return }
        managedObjectContext.performGroupedBlock { [weak self] in
            guard let message = self?.managedObjectContext.registeredObject(for: objectID) as? ZMAssetClientMessage else { return }
            guard let identifier = message.associatedTaskIdentifier else { return }
            self?.taskCancellationProvider?.cancelTaskWithIdentifier(identifier)
            message.associatedTaskIdentifier = nil
        }
    }

    func nextRequest() -> ZMTransportRequest? {
        guard self.authStatus.currentPhase == .authenticated else {
            return .none
        }
        
        return self.assetDownstreamObjectSync.nextRequest()
    }
    
    fileprivate func handleResponse(_ response: ZMTransportResponse, forMessage assetClientMessage: ZMAssetClientMessage) {
        if response.result == .success {
            guard let fileMessageData = assetClientMessage.fileMessageData, let asset = assetClientMessage.genericAssetMessage?.asset else { return }
            // TODO: create request that streams directly to the cache file, otherwise the memory would overflow on big files
            let fileCache = self.managedObjectContext.zm_fileAssetCache
            fileCache.storeAssetData(assetClientMessage.nonce, fileName: fileMessageData.filename, encrypted: true, data: response.rawData)

            let decryptionSuccess = fileCache.decryptFileIfItMatchesDigest(
                assetClientMessage.nonce,
                fileName: fileMessageData.filename,
                encryptionKey: asset.uploaded.otrKey,
                sha256Digest: asset.uploaded.sha256
            )
            
            if decryptionSuccess {
                assetClientMessage.transferState = .Downloaded
            }
            else {
                assetClientMessage.transferState = .FailedDownload
            }
        }
        else {
            if assetClientMessage.transferState == .Downloading {
                assetClientMessage.transferState = .FailedDownload
            }
        }
        
        let messageObjectId = assetClientMessage.objectID
        self.managedObjectContext.zm_userInterface.performGroupedBlock({ () -> Void in
            let uiMessage = try? self.managedObjectContext.zm_userInterfaceContext.existingObjectWithID(messageObjectId)
            
            let userInfo = [AssetDownloadRequestStrategyNotification.downloadStartTimestampKey: response.startOfUploadTimestamp ?? Date()]
            if assetClientMessage.transferState == .Downloaded {
                NotificationCenter.default.post(name: AssetDownloadRequestStrategyNotification.downloadFinishedNotificationName, object: uiMessage, userInfo: userInfo)
            }
            else {
                NotificationCenter.default.post(name: AssetDownloadRequestStrategyNotification.downloadFailedNotificationName, object: uiMessage, userInfo: userInfo)
            }
        })
    }
    
    // MARK: - ZMContextChangeTrackerSource
    
    public var contextChangeTrackers: [ZMContextChangeTracker] {
        get {
            return [self.assetDownstreamObjectSync]
        }
    }

    // MARK: - ZMDownstreamTranscoder
    
    public func requestForFetchingObject(_ object: ZMManagedObject!, downstreamSync: ZMObjectSync!) -> ZMTransportRequest! {
        if let assetClientMessage = object as? ZMAssetClientMessage {
            
            let taskCreationHandler = ZMTaskCreatedHandler(onGroupQueue: managedObjectContext) { taskIdentifier in
                assetClientMessage.associatedTaskIdentifier = taskIdentifier
            }
            
            let completionHandler = ZMCompletionHandler(onGroupQueue: self.managedObjectContext) { response in
                self.handleResponse(response, forMessage: assetClientMessage)
            }
            
            let progressHandler = ZMTaskProgressHandler(on: self.managedObjectContext) { progress in
                assetClientMessage.progress = progress
                self.managedObjectContext.enqueueDelayedSave()
            }
            
            if let request = ClientMessageRequestFactory().downstreamRequestForEcryptedOriginalFileMessage(assetClientMessage) {
                request.addTaskCreatedHandler(taskCreationHandler)
                request.addCompletionHandler(completionHandler)
                request.addProgressHandler(progressHandler)
                return request
            }
        }
        
        fatalError("Cannot generate request for \(object)")
    }
    
    public func deleteObject(_ object: ZMManagedObject!, downstreamSync: ZMObjectSync!) {
        // no-op
    }
    
    public func updateObject(_ object: ZMManagedObject!, withResponse response: ZMTransportResponse!, downstreamSync: ZMObjectSync!) {
        // no-op
    }
}
