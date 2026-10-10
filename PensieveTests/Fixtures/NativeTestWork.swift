import SwiftData
import XCTest

/// Runs an explicitly synchronous test operation on a native thread and joins it.
/// XCTest keeps ownership of invocation, activities and teardown. This helper changes no
/// production runner and supplies no guard exemption; actor entry points run separately.
enum NativeTestWork {
    static func run<Value>(container: ModelContainer,
                           _ operation: @escaping (ModelContext) throws -> Value) throws -> Value {
        try run { try operation(ModelContext(container)) }
    }

    static func run<Value>(_ operation: @escaping () throws -> Value) throws -> Value {
        if !Thread.isMainThread { return try operation() }
        let completed = DispatchSemaphore(value: 0)
        var result: Result<Value, Error>?
        Thread {
            result = Result { try operation() }
            completed.signal()
        }.start()
        completed.wait()
        return try XCTUnwrap(result).get()
    }
}
