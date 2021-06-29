//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Amplify
import AWSPluginsCore
import AWSS3

public class AWSS3StorageUploadDataOperation: AmplifyInProcessReportingOperation<
    StorageUploadDataRequest,
    Progress,
    String,
    StorageError
>, StorageUploadDataOperation {

    let storageConfiguration: AWSS3StoragePluginConfiguration
    let storageService: AWSS3StorageServiceBehaviour
    let authService: AWSAuthServiceBehavior

    var storageTaskReference: StorageTaskReference?

    /// Serial queue for synchronizing access to `storageTaskReference`.
    private let storageTaskActionQueue = DispatchQueue(label: "com.amazonaws.amplify.StorageTaskActionQueue")

    init(_ request: StorageUploadDataRequest,
         storageConfiguration: AWSS3StoragePluginConfiguration,
         storageService: AWSS3StorageServiceBehaviour,
         authService: AWSAuthServiceBehavior,
         progressListener: InProcessListener?,
         resultListener: ResultListener?) {

        self.storageConfiguration = storageConfiguration
        self.storageService = storageService
        self.authService = authService
        super.init(categoryType: .storage,
                   eventName: HubPayload.EventName.Storage.uploadData,
                   request: request,
                   inProcessListener: progressListener,
                   resultListener: resultListener)
    }

    override public func pause() {
        storageTaskActionQueue.async {
            self.storageTaskReference?.pause()
            super.pause()
        }
    }

    override public func resume() {
        storageTaskActionQueue.async {
            self.storageTaskReference?.resume()
            super.resume()
        }
    }

    override public func cancel() {
        storageTaskActionQueue.async {
            self.storageTaskReference?.cancel()
            super.cancel()
        }
    }

    override public func main() {
        if isCancelled {
            finish()
            return
        }

        if let error = request.validate() {
            dispatch(error)
            finish()
            return
        }

        let options = request.options.pluginOptions as? AWSS3PluginOptions
        let prefixResolver: AWSS3PluginCustomPrefixResolver = storageConfiguration.getPrefixResolver(
            options: options) ?? StorageAccessLevelAwarePrefixResolver(authService: authService)
        let prefix = prefixResolver.resolvePrefix(for: request.options.accessLevel,
                                                  targetIdentityId: request.options.targetIdentityId)
        switch prefix {
        case .success(let prefix):
            let serviceKey = prefix + request.key
            let serviceMetadata = StorageRequestUtils.getServiceMetadata(request.options.metadata)
            if request.data.count > StorageUploadDataRequest.Options.multiPartUploadSizeThreshold {
                storageService.multiPartUpload(serviceKey: serviceKey,
                                               uploadSource: .data(request.data),
                                               contentType: request.options.contentType,
                                               metadata: serviceMetadata) { [weak self] event in
                                                   self?.onServiceEvent(event: event)
                                               }
            } else {
                storageService.upload(serviceKey: serviceKey,
                                      uploadSource: .data(request.data),
                                      contentType: request.options.contentType,
                                      metadata: serviceMetadata) { [weak self] event in
                                          self?.onServiceEvent(event: event)
                                      }
            }
        case .failure(let error):
            dispatch(error)
            finish()
        }
    }

    private func onServiceEvent(
        event: StorageEvent<StorageTaskReference, Progress, Void, StorageError>) {
        switch event {
        case .initiated(let reference):
            storageTaskActionQueue.async {
                self.storageTaskReference = reference
                if self.isCancelled {
                    self.storageTaskReference?.cancel()
                    self.finish()
                }
            }
        case .inProcess(let progress):
            dispatch(progress)
        case .completed:
            dispatch(request.key)
            finish()
        case .failed(let error):
            dispatch(error)
            finish()
        }
    }

    private func dispatch(_ progress: Progress) {
        dispatchInProcess(data: progress)
    }

    private func dispatch(_ result: String) {
        let result = OperationResult.success(result)
        dispatch(result: result)
    }

    private func dispatch(_ error: StorageError) {
        let result = OperationResult.failure(error)
        dispatch(result: result)
    }
}
