import ExpoModulesCore
import PhotosUI

public class MediaLibraryModule: Module, PhotoLibraryObserverHandler {
  private var allAssetsFetchResult: PHFetchResult<PHAsset>?
  private var writeOnly = false
  private var delegates = Set<SaveToLibraryDelegate>()
  private var changeDelegate: PhotoLibraryObserver?

  // swiftlint:disable:next cyclomatic_complexity
  public func definition() -> ModuleDefinition {
    Name("ExpoMediaLibrary")

    Events("mediaLibraryDidChange")

    Constants {
      [
        "MediaType": [
          "audio": "audio",
          "photo": "photo",
          "video": "video",
          "unknown": "unknown",
          "all": "all"
        ],
        "SortBy": [
          "default": "default",
          "creationTime": "creationTime",
          "modificationTime": "modificationTime",
          "mediaType": "mediaType",
          "width": "width",
          "height": "height",
          "duration": "duration"
        ],
        "CHANGE_LISTENER_NAME": "mediaLibraryDidChange"
      ]
    }

    OnCreate {
      appContext?.permissions?.register([
        MediaLibraryPermissionRequester(),
        MediaLibraryWriteOnlyPermissionRequester()
      ])
    }

    AsyncFunction("getPermissionsAsync") { (writeOnly: Bool, promise: Promise) in
      self.writeOnly = writeOnly
      appContext?
        .permissions?
        .getPermissionUsingRequesterClass(
          requesterClass(writeOnly),
          resolve: promise.resolver,
          reject: promise.legacyRejecter
        )
    }

    AsyncFunction("requestPermissionsAsync") { (writeOnly: Bool, promise: Promise) in
      self.writeOnly = writeOnly
      appContext?
        .permissions?
        .askForPermission(
          usingRequesterClass: requesterClass(writeOnly),
          resolve: promise.resolver,
          reject: promise.legacyRejecter
        )
    }

    AsyncFunction("presentPermissionsPickerAsync") {
      guard let vc = appContext?.utilities?.currentViewController() else {
        return
      }
      PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: vc)
    }.runOnQueue(.main)

    AsyncFunction("createAssetAsync") { (uri: URL, promise: Promise) in
      if !checkPermissions(promise: promise) {
        return
      }

      if uri.pathExtension.isEmpty {
        promise.reject(EmptyFileExtensionException())
        return
      }

      let assetType = assetType(for: uri)
      if assetType == .unknown || assetType == .audio {
        promise.reject(UnsupportedAssetTypeException(uri.absoluteString))
        return
      }

      if !FileSystemUtilities.permissions(appContext, for: uri).contains(.read) {
        promise.reject(UnreadableAssetException(uri.absoluteString))
        return
      }

      var assetPlaceholder: PHObjectPlaceholder?
      PHPhotoLibrary.shared().performChanges {
        let changeRequest = assetType == .video
        ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: uri)
        : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: uri)

        assetPlaceholder = changeRequest?.placeholderForCreatedAsset
      } completionHandler: { success, error in
        if success {
          let asset = getAssetBy(id: assetPlaceholder?.localIdentifier)
          promise.resolve(exportAsset(asset: asset))
        } else {
          promise.reject(SaveAssetException(error))
        }
      }
    }

    AsyncFunction("saveToLibraryAsync") { (localUrl: URL, promise: Promise) in
      if Bundle.main.infoDictionary?["NSPhotoLibraryAddUsageDescription"] == nil {
        throw MissingPListKeyException("NSPhotoLibraryAddUsageDescription")
      }

      if localUrl.pathExtension.isEmpty {
        promise.reject(EmptyFileExtensionException())
        return
      }

      let assetType = assetType(for: localUrl)
      let delegate = SaveToLibraryDelegate()
      delegates.insert(delegate)

      let callback: SaveToLibraryCallback = { [weak self] _, error in
        guard let self else {
          return
        }
        self.delegates.remove(delegate)
        guard error == nil else {
          promise.reject(SaveAssetException(error))
          return
        }
        promise.resolve()
      }

      if assetType == .image {
        if localUrl.pathExtension.lowercased() == "gif" {
          delegate.writeGIF(localUrl, withCallback: callback)
          return
        }

        guard let image = UIImage(data: try Data(contentsOf: localUrl)) else {
          promise.reject(MissingFileException(localUrl.absoluteString))
          return
        }
        delegate.writeImage(image, withCallback: callback)
        return
      } else if assetType == .video {
        if UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(localUrl.path) {
          delegate.writeVideo(localUrl, withCallback: callback)
          return
        }
        promise.reject(SaveVideoException())
        return
      }

      promise.reject(UnsupportedAssetException())
    }

    AsyncFunction("addAssetsToAlbumAsync") { (assetIds: [String], album: String, promise: Promise) in
      runIfAllPermissionsWereGranted(reject: promise.legacyRejecter) {
        addAssets(ids: assetIds, to: album) { success, error in
          if success {
            promise.resolve(success)
          } else {
            promise.reject(SaveAlbumException(error))
          }
        }
      }
    }

    AsyncFunction("removeAssetsFromAlbumAsync") { (assetIds: [String], album: String, promise: Promise) in
      runIfAllPermissionsWereGranted(reject: promise.legacyRejecter) {
        PHPhotoLibrary.shared().performChanges {
          guard let collection = getAlbum(by: album) else {
            return
          }
          let assets = getAssetsBy(assetIds: assetIds)

          let albumChangeRequest = PHAssetCollectionChangeRequest(for: collection, assets: assets)
          albumChangeRequest?.removeAssets(assets)
        } completionHandler: { success, error in
          if success {
            promise.resolve(success)
          } else {
            promise.reject(RemoveFromAlbumException(error))
          }
        }
      }
    }

    AsyncFunction("deleteAssetsAsync") { (assetIds: [String], promise: Promise) in
      if !checkPermissions(promise: promise) {
        return
      }

      PHPhotoLibrary.shared().performChanges {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        PHAssetChangeRequest.deleteAssets(fetched)
      } completionHandler: { success, error in
        if success {
          promise.resolve(success)
        } else {
          promise.reject(RemoveAssetsException(error))
        }
      }
    }

    AsyncFunction("getAlbumsAsync") { (options: AlbumOptions, promise: Promise) in
      runIfAllPermissionsWereGranted(reject: promise.legacyRejecter) {
        var albums = [[String: Any?]?]()
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = false
        fetchOptions.includeAllBurstAssets = false

        let useAlbumsfetchResult = PHCollectionList.fetchTopLevelUserCollections(with: fetchOptions)

        let collections = exportCollections(collections: useAlbumsfetchResult, with: fetchOptions, in: nil)
        albums.append(contentsOf: collections)

        if options.includeSmartAlbums {
          let smartAlbumsFetchResult = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: fetchOptions)
          albums.append(contentsOf: exportCollections(collections: smartAlbumsFetchResult, with: fetchOptions, in: nil))
        }

        promise.resolve(albums)
      }
    }

    AsyncFunction("getMomentsAsync") { (promise: Promise) in
      if !checkPermissions(promise: promise) {
        return
      }

      let options = PHFetchOptions()
      options.includeHiddenAssets = false
      options.includeAllBurstAssets = false

      let fetchResult = PHAssetCollection.fetchMoments(with: options)
      let albums = exportCollections(collections: fetchResult, with: options, in: nil)

      promise.resolve(albums)
    }

    AsyncFunction("getAlbumAsync") { (title: String, promise: Promise) in
      runIfAllPermissionsWereGranted(reject: promise.legacyRejecter) {
        let collection = getAlbum(with: title)
        promise.resolve(exportCollection(collection))
      }
    }

    AsyncFunction("createAlbumAsync") { (title: String, assetId: String?, promise: Promise) in
      runIfAllPermissionsWereGranted(reject: promise.legacyRejecter) {
        createAlbum(with: title) { collection, createError in
          if let collection {
            if let assetId {
              addAssets(ids: [assetId], to: collection.localIdentifier) { success, addError in
                if success {
                  promise.resolve(exportCollection(collection))
                } else {
                  promise.reject(FailedToAddAssetException(addError))
                }
              }
            } else {
              promise.resolve(exportCollection(collection))
            }
          } else {
            promise.reject(CreateAlbumFailedException(createError))
          }
        }
      }
    }

    AsyncFunction("deleteAlbumsAsync") { (albumIds: [String], removeAsset: Bool, promise: Promise) in
      runIfAllPermissionsWereGranted(reject: promise.legacyRejecter) {
        let collections = getAlbums(by: albumIds)
        PHPhotoLibrary.shared().performChanges {
          if removeAsset {
            collections.enumerateObjects { collection, _, _ in
              let fetch = PHAsset.fetchAssets(in: collection, options: nil)
              PHAssetChangeRequest.deleteAssets(fetch)
            }
          }
          PHAssetCollectionChangeRequest.deleteAssetCollections(collections)
        } completionHandler: { success, error in
          if success {
            promise.resolve(success)
          } else {
            promise.reject(DeleteAlbumFailedException(error))
          }
        }
      }
    }

    AsyncFunction("getAssetInfoAsync") { (assetId: String?, options: AssetInfoOptions, promise: Promise) in
      if !checkPermissions(promise: promise) {
        return
      }

      guard let asset = getAssetBy(id: assetId) else {
        promise.resolve(nil)
        return
      }

      if asset.mediaType == .image {
        resolveImage(asset: asset, options: options, promise: promise)
      } else {
        resolveVideo(asset: asset, options: options, promise: promise)
      }
    }

    AsyncFunction("getAssetsAsync") { (options: AssetWithOptions, promise: Promise) in
      if !checkPermissions(promise: promise) {
        return
      }

      if let albumId = options.album {
        runIfAllPermissionsWereGranted(reject: promise.legacyRejecter) {
          let collection = getAlbum(by: albumId)
          getAssetsWithAfter(options: options, collection: collection, promise: promise)
        }
      } else {
        getAssetsWithAfter(options: options, collection: nil, promise: promise)
      }
    }

    OnStartObserving {
      allAssetsFetchResult = getAllAssets()
      let delegate = PhotoLibraryObserver(handler: self)
      self.changeDelegate = delegate
      PHPhotoLibrary.shared().register(delegate)
    }

    OnStopObserving {
      changeDelegate = nil
      allAssetsFetchResult = nil
    }
  }


  private func processImageData(data: Data, result: inout [String: Any]) {
    if let source = CGImageSourceCreateWithData(data as CFData, nil),
       let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
        if let exifData = metadata["{Exif}"] as? [String: Any] {
            result["exif"] = exifData
        }
        if let gpsData = metadata["{GPS}"] as? [String: Any] {
            result["gps"] = gpsData
        }
        if let tiffData = metadata["{TIFF}"] as? [String: Any] {
            result["tiff"] = tiffData
        }
    }
  }

  private func resolveImage(asset: PHAsset, options: AssetInfoOptions, promise: Promise) {
    var result: [String: Any] = [:]

    // Get creation date
    if let creationDate = asset.creationDate {
        let timestamp = creationDate.timeIntervalSince1970 * 1000 // Convert to milliseconds
        result["creationTime"] = timestamp
    }

    // Get creation date
    if let modificationDate = asset.modificationDate {
        let timestamp = modificationDate.timeIntervalSince1970 * 1000 // Convert to milliseconds
        result["modificationTime"] = timestamp
    }

    // Try getting location coordinate
    if let location = asset.location {
        result["location"] = location.coordinate
        result["locationAccuracy"] = location.horizontalAccuracy
        result["course"] = location.course
    }

    // Directly assign duration since it is not optional
    result["duration"] = asset.duration

    // Directly assign isFavorite since it is not optional
    result["isFavorite"] = asset.isFavorite

    // Directly assign isEdited (hasAdjustments) since it is not optional
    result["isEdited"] = asset.hasAdjustments

    result["isNetworkAsset"] = false
    promise.resolve(result)
  }

  private func resolveImageX(asset: PHAsset, options: AssetInfoOptions, promise: Promise) {
    let imageOptions = PHImageRequestOptions()
    imageOptions.isNetworkAccessAllowed = false  
    imageOptions.deliveryMode = .fastFormat

    var result: [String: Any] = [:]

    // // Get creation date
    // if let creationDate = asset.creationDate {
    //     let timestamp = creationDate.timeIntervalSince1970 * 1000 // Convert to milliseconds
    //     result["creationTime"] = timestamp
    // }

    // // Get creation date
    // if let modificationDate = asset.modificationDate {
    //     let timestamp = modificationDate.timeIntervalSince1970 * 1000 // Convert to milliseconds
    //     result["modificationTime"] = timestamp
    // }

    // // Try getting location coordinate
    // if let location = asset.location {
    //     result["location"] = location.coordinate
    // }

    // // Try getting location accuracy
    // if let course = asset.location {
    //     result["locationAccuracy"] = location.horizontalAccuracy
    // }

    // // Try getting location direction
    // if let course = asset.location {
    //     result["course"] = location.course
    // }

    // // Try getting duration
    // if let duration = asset.duration {
    //     result["duration"] = duration
    // }

    // // Try getting isFavorite
    // if let isFavorite = asset.isFavorite {
    //     result["isFavorite"] = isFavorite
    // }

    // // Try getting isEdited
    // if let isEdited = asset.hasAdjustments {
    //     result["isEdited"] = isEdited
    // }

    // First, attempt to fetch the image locally using requestImageData
    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: imageOptions) { data, dataUTI, orientation, info in
        // If image data is available locally, process it
        if let data = data {
            self.processImageData(data: data, result: &result)

            // Get file size
            let fileSize = data.count
            result["fileSize"] = fileSize

            result["isNetworkAsset"] = false
            promise.resolve(result)

        } else if let error = info?[PHImageErrorKey] as? NSError, error.domain == PHPhotosErrorDomain && error.code == 3164 {
            if options.shouldDownloadFromNetwork {
                // Handle the case where the image is not available locally (error 3164)
                imageOptions.isNetworkAccessAllowed = true  // Enable network access


                // Implementation 1:
                PHImageManager.default().requestImageDataAndOrientation(for: asset, options: imageOptions) { cloudData, cloudDataUTI, cloudOrientation, cloudInfo in
                    guard let cloudData = cloudData else {
                        // Check for an error from the cloudInfo dictionary
                        if let cloudError = cloudInfo?[PHImageErrorKey] as? NSError {
                            promise.reject(cloudError)
                        } else {
                            // If no error is provided, use a hardcoded error
                            let error = NSError(domain: "ImageFetch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch image data from iCloud"])
                            promise.reject(error)
                        }
                        return
                    }

                    self.processImageData(data: cloudData, result: &result)

                    result["fileSize"] = cloudData.count
                    result["isNetworkAsset"] = true
                    promise.resolve(result)
                }

                // Implementation 2:
                // // Use requestImage to fetch a very small image (1x1 pixel) to get metadata
                // let targetSize = CGSize(width: 1, height: 1)
                // PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: imageOptions) { image, info in
                //     if let cloudData = info?[PHImageFileURLKey] as? URL, let imageData = try? Data(contentsOf: cloudData) {
                //         self.processImageData(data: imageData, result: &result)

                //         result["fileSize"] = imageData.count
                //         result["isNetworkAsset"] = true
                //         promise.resolve(result)
                //     } else if let cloudError = info?[PHImageErrorKey] as? NSError {
                //         promise.reject(cloudError)
                //     } else {
                //         // If no error is provided, use a hardcoded error
                //         let error = NSError(domain: "ImageFetch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch image from iCloud"])
                //         promise.reject(error)
                //     }
                // }
            } else {
                promise.resolve(nil)
            }
        } else {
            // Handle other errors or cases where image data is nil
            promise.reject(NSError(domain: "ImageFetch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Image not available or other error"]))
        }
    }
  }

  // private func resolveImageBatch(assets: [PHAsset], options: AssetInfoOptions, promise: Promise) {
  //   // Create a dispatch group to track the completion of all metadata extraction tasks
  //   let dispatchGroup = DispatchGroup()
    
  //   // Use a semaphore to limit concurrent operations, for example, max 4 concurrent extractions
  //   let semaphore = DispatchSemaphore(value: 4)

  //   // Result array to hold the metadata for each asset
  //   var results: [[String: Any]] = []
    
  //   // Queue for safely adding to the results array
  //   let resultQueue = DispatchQueue(label: "com.yourApp.resultQueue", attributes: .concurrent)

  //   // Process each asset in parallel using DispatchQueue
  //   for asset in assets {
  //     dispatchGroup.enter()  // Enter the dispatch group for each asset
  //     semaphore.wait()  // Limit the number of concurrent operations

  //     DispatchQueue.global(qos: .userInitiated).async {
  //       let imageOptions = PHImageRequestOptions()
  //       imageOptions.isNetworkAccessAllowed = false  // First attempt without network access
  //       imageOptions.deliveryMode = .fastFormat

  //       // Attempt to request image data without network access
  //       PHImageManager.default().requestImageData(for: asset, options: imageOptions) { data, uti, orientation, info in
  //         var result: [String: Any] = [:]

  //         // Get creation date
  //         if let creationDate = asset.creationDate {
  //           result["createdAt"] = creationDate
  //         }

  //         if let error = info?[PHImageErrorKey] as? Error {
  //           // Handle errors in fetching the image data
  //           promise.reject(error)
  //           dispatchGroup.leave()
  //           semaphore.signal()
  //           return
  //         }

  //         if let data = data {
  //           // Extract EXIF, GPS, and TIFF metadata
  //           if let source = CGImageSourceCreateWithData(data as NSData, nil),
  //             let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
  //             result["exif"] = metadata["{Exif}"]
  //             if let gpsData = metadata["{GPS}"] as? [String: Any] {
  //               result["gps"] = gpsData
  //             }
  //             if let tiffData = metadata["{TIFF}"] as? [String: Any] {
  //               result["tiff"] = tiffData
  //             }
  //           }

  //           // Get file size
  //           let fileSize = data.count
  //           result["fileSize"] = fileSize

  //           // Append result to the results array in a thread-safe manner
  //           resultQueue.async(flags: .barrier) {
  //             results.append(result)
  //           }
            
  //           // Resolve the promise with the result dictionary
  //           dispatchGroup.leave()
  //           semaphore.signal()
  //         } else if let isInCloud = info?[PHImageResultIsInCloudKey] as? Bool, isInCloud && options.shouldDownloadFromNetwork {
  //           // If the image is only in iCloud, fetch the smallest possible version to extract metadata
  //           imageOptions.isNetworkAccessAllowed = true  // Allow network access for this request
  //           let targetSize = CGSize(width: 1, height: 1) // Minimal size, just a pixel
  //           PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .default, options: imageOptions) { image, info in
  //             guard let image = image else {
  //               promise.reject(NSError(domain: "ImageFetch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch image or metadata from iCloud"]))
  //               dispatchGroup.leave()
  //               semaphore.signal()
  //               return
  //             }

  //             // Convert UIImage to CGImage and extract metadata
  //             if let cgImage = image.cgImage,
  //               let dataProvider = cgImage.dataProvider,
  //               let imageData = dataProvider.data {
  //               let imageDataPointer = CFDataGetBytePtr(imageData)  // Get the raw byte pointer
  //               let imageDataLength = CFDataGetLength(imageData)    // Get the data length

  //               // Create CFData from the raw byte pointer
  //               let cfData = CFDataCreate(kCFAllocatorDefault, imageDataPointer, imageDataLength)
                
  //               if let source = CGImageSourceCreateWithData(cfData!, nil),
  //                 let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
  //                 result["exif"] = metadata["{Exif}"]
  //                 if let gpsData = metadata["{GPS}"] as? [String: Any] {
  //                   result["gps"] = gpsData
  //                 }
  //                 if let tiffData = metadata["{TIFF}"] as? [String: Any] {
  //                   result["tiff"] = tiffData
  //                 }
  //               }
  //             }

  //             result["isNetworkAsset"] = true

  //             // Append result to the results array in a thread-safe manner
  //             resultQueue.async(flags: .barrier) {
  //               results.append(result)
  //             }
              
  //             dispatchGroup.leave()
  //             semaphore.signal()
  //           }
  //         } else {
  //           // Handle cases where data is nil and not in iCloud
  //           result["exif"] = nil
  //           resultQueue.async(flags: .barrier) {
  //             results.append(result)
  //           }
  //           dispatchGroup.leave()
  //           semaphore.signal()
  //         }
  //       }
  //     }
  //   }

  //   // Once all tasks are complete, resolve the promise with the results array
  //   dispatchGroup.notify(queue: DispatchQueue.main) {
  //     promise.resolve(results)
  //   }
  // }

  private func resolveVideo(asset: PHAsset, options: AssetInfoOptions, promise: Promise) {
    // Configure PHVideoRequestOptions
    let videoOptions = PHVideoRequestOptions()
    videoOptions.isNetworkAccessAllowed = options.shouldDownloadFromNetwork
    
    // Request video data
    PHImageManager.default().requestAVAsset(forVideo: asset, options: videoOptions) { avAsset, audioMix, info in
      var result: [String: Any] = [:]
        
      if let avAsset = avAsset as? AVURLAsset {
        let duration = avAsset.duration.seconds
        let tracks = avAsset.tracks(withMediaType: AVMediaType.video)
          
        if let videoTrack = tracks.first {
          let size = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
          let resolution = CGSize(width: abs(size.width), height: abs(size.height))
            
          result["duration"] = duration
          result["resolution"] = resolution
        }
            
        // Optionally add other information from `info` if needed
        if !options.shouldDownloadFromNetwork {
          if let info = info, let isNetworkAsset = info[PHImageResultIsInCloudKey] as? Bool {
            result["isNetworkAsset"] = isNetworkAsset
          } else {
            result["isNetworkAsset"] = false
          }
        }
      } else {
        // Handle case where avAsset is not an AVURLAsset
        result["error"] = "Failed to get AVURLAsset from PHAsset"
      }
        
      // Resolve the promise with the result dictionary
      promise.resolve(result)
    }
  }

  // Helper function to extract metadata from AVURLAsset
  private func extractMetadata(from asset: AVURLAsset) -> [String: Any] {
    var metadataResult: [String: Any] = [:]
    for format in asset.availableMetadataFormats {
      let metadataItems = asset.metadata(forFormat: format)
      for item in metadataItems {
          if let key = item.commonKey?.rawValue, let value = item.value {
              metadataResult[key] = value
          }
      }
    }
    return metadataResult
  }

  private func checkPermissions(promise: Promise) -> Bool {
    guard let permissions = appContext?.permissions else {
      promise.reject(MediaLibraryPermissionsException())
      return false
    }
    if !permissions.hasGrantedPermission(usingRequesterClass: requesterClass(self.writeOnly)) {
      promise.reject(MediaLibraryPermissionsException())
      return false
    }
    return true
  }

  private func runIfAllPermissionsWereGranted(reject: @escaping EXPromiseRejectBlock, block: @escaping () -> Void) {
    appContext?.permissions?.getPermissionUsingRequesterClass(
      MediaLibraryPermissionRequester.self,
      resolve: { result in
        if let permissions = result as? [String: Any] {
          if permissions["status"] as? String != "granted" {
            reject("E_NO_PERMISSIONS", "MEDIA_LIBRARY permission is required to do this operation.", nil)
            return
          }
          if permissions["accessPrivileges"] as? String != "all" {
            reject("E_NO_PERMISSIONS", "MEDIA_LIBRARY permission is required to do this operation.", nil)
            return
          }
          block()
        }
      },
      reject: reject)
  }

  func didChange(_ changeInstance: PHChange) {
    if let allAssetsFetchResult {
      let changeDetails = changeInstance.changeDetails(for: allAssetsFetchResult)

      if let changeDetails {
        self.allAssetsFetchResult = changeDetails.fetchResultAfterChanges

        if changeDetails.hasIncrementalChanges && !changeDetails.insertedObjects.isEmpty || !changeDetails.removedObjects.isEmpty {
          var insertedAssets = [[String: Any?]?]()
          var deletedAssets = [[String: Any?]?]()
          var updatedAssets = [[String: Any?]?]()
          let body: [String: Any] = [
            "hasIncrementalChanges": true,
            "insertedAssets": insertedAssets,
            "deletedAssets": deletedAssets,
            "updatedAssets": updatedAssets
          ]

          for asset in changeDetails.insertedObjects {
            insertedAssets.append(exportAsset(asset: asset))
          }

          for asset in changeDetails.removedObjects {
            deletedAssets.append(exportAsset(asset: asset))
          }

          for asset in changeDetails.changedObjects {
            updatedAssets.append(exportAsset(asset: asset))
          }

          sendEvent("mediaLibraryDidChange", body)
          return
        }

        if !changeDetails.hasIncrementalChanges {
          sendEvent("mediaLibraryDidChange", [
            "hasIncrementalChanges": false
          ])
        }
      }
    }
  }
}
