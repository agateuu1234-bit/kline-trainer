import Testing
import Foundation
import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite("ZipErrorMapping disk-full domain coverage")
struct ZipErrorMappingTests {

    @Test func cocoa_NSFileWriteOutOfSpaceError_mapsToDiskFull() {
        let err = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError, userInfo: nil
        )
        #expect(ZipErrorMapping.translate(err) == .persistence(.diskFull))
    }

    @Test func posix_ENOSPC_mapsToDiskFull() {
        let err = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue), userInfo: nil
        )
        #expect(ZipErrorMapping.translate(err) == .persistence(.diskFull))
    }

    @Test func cocoaWrappedPOSIX_ENOSPC_mapsToDiskFull() {
        let inner = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue), userInfo: nil
        )
        let outer = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: inner]
        )
        #expect(ZipErrorMapping.translate(outer) == .persistence(.diskFull))
    }
}
