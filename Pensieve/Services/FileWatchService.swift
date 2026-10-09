import CoreServices
import Foundation
import os

// MARK: - Protocol

protocol FileWatchServiceProtocol: AnyObject {
    /// The closure invoked (on the MAIN queue) with the changed skill `directoryName`.
    /// Settable so a consumer can register its handler after the service is constructed.
    var onChange: (String) -> Void { get set }
    @discardableResult
    func start() -> Bool
    func stop()
}

// MARK: - Implementation

final class FileWatchService: FileWatchServiceProtocol {
    private let rootDir: String
    var onChange: (String) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.jaredatch.pensieve.filewatch")

    init(
        rootDir: String,
        onChange: @escaping (String) -> Void = FileWatchService.osLogSink
    ) {
        self.rootDir = URL(fileURLWithPath: rootDir).resolvingSymlinksInPath().path
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        if stream != nil {
            return true
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let createdStream = FSEventStreamCreate(
            nil,
            { _, info, _, eventPaths, _, _ in
                guard let info else {
                    return
                }

                let service = Unmanaged<FileWatchService>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                let changedPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                service.handle(changedPaths: changedPaths)
            },
            &context,
            [rootDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            return false
        }

        stream = createdStream
        FSEventStreamSetDispatchQueue(createdStream, queue)

        guard FSEventStreamStart(createdStream) else {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            stream = nil
            return false
        }

        return true
    }

    func stop() {
        guard let activeStream = stream else {
            return
        }

        FSEventStreamStop(activeStream)
        FSEventStreamInvalidate(activeStream)
        FSEventStreamRelease(activeStream)
        stream = nil
    }

    private func handle(changedPaths: [String]) {
        var directoryNames = Set<String>()

        for path in changedPaths {
            let normalizedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard let relativePath = PathSyntax.relativePath(normalizedPath, under: rootDir),
                  let directoryName = PathSyntax.components(relativePath).first else { continue }

            directoryNames.insert(directoryName)
        }

        DispatchQueue.main.async {
            for directoryName in directoryNames {
                self.onChange(directoryName)
            }
        }
    }

    private static func osLogSink(_ directoryName: String) {
        os_log(
            "%{public}@ %{public}@",
            log: .pensieveSignals,
            type: .info,
            AppSignal.skillChangedExternally,
            directoryName
        )
    }
}
