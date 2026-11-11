import Foundation
import ObjCExceptions

/// Turns Objective-C exceptions into Swift errors. AVAudioEngine raises them for some
/// device problems (e.g. "Input HW format is invalid" while a USB mic is reconnecting),
/// and an uncaught one aborts the app.
enum ObjCException {
    static func catching<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, any Error>?
        try DKObjCExceptionCatcher.run {
            result = Result { try body() }
        }
        // `run` returns normally only after the block has finished.
        return try result!.get()
    }
}
