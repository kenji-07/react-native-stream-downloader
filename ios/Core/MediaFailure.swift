import Foundation

extension OfflineError {
    static func media(_ error: Error) -> OfflineError {
        if let known = error as? OfflineError { return known }
        var current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        var storageFailure = false
        while let value = current, seen.insert(ObjectIdentifier(value)).inserted, seen.count <= 8 {
            if value.domain == NSCocoaErrorDomain && value.code == NSFileWriteOutOfSpaceError || value.domain == NSPOSIXErrorDomain && value.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
                return OfflineError(code: "E_INSUFFICIENT_STORAGE", message: "There is not enough free storage for the download.")
            }
            if value.domain == NSCocoaErrorDomain && (NSFileReadUnknownError...NSFileWriteUnknownError + 255).contains(value.code) {
                storageFailure = true
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if storageFailure { return OfflineError(code: "E_STORAGE", message: "Downloaded media could not be read or written.") }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            if [NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile, NSURLErrorCannotCloseFile, NSURLErrorCannotWriteToFile, NSURLErrorCannotRemoveFile, NSURLErrorCannotMoveFile].contains(value.code) {
                return OfflineError(code: "E_STORAGE", message: "Downloaded media could not be saved.")
            }
            return OfflineError(code: "E_NETWORK", message: "Media transfer failed.", retryable: [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(value.code))
        }
        return OfflineError(code: "E_MEDIA", message: "Native media preparation or transfer failed.")
    }
}
