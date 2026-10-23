import Foundation

/// App-owned UI stays in English, independent of the Mac's preferred language.
enum DisplayText {
    static let locale = Locale(identifier: "en_US")

    static func date(_ value: Date) -> String {
        value.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(locale))
    }

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    static func error(_ value: Error) -> String {
        if let described = value as? EnglishDescribedError { return described.englishDescription }
        if value is DecodingError { return "The saved data could not be read. It may be damaged or from an incompatible version." }
        if value is EncodingError { return "The data could not be saved." }
        let error = value as NSError
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError), (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSPOSIXErrorDomain, 1), (NSPOSIXErrorDomain, 13):
            return "Permission denied. Check access to the folder in System Settings."
        case (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
             (NSPOSIXErrorDomain, 2):
            return "The file or folder no longer exists."
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError), (NSPOSIXErrorDomain, 28):
            return "The disk is full. Free some space and try again."
        default:
            return "The operation could not be completed (\(error.domain), code \(error.code))."
        }
    }
}

protocol EnglishDescribedError: Error {
    var englishDescription: String { get }
}
