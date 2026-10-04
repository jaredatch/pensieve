import Foundation

extension GitService {
    /// Internal transport seam for fault and scheduling tests. Normal calls own fresh pipes and a child.
    struct ProcessIO {
        var process = Process()
        var stdout = Pipe()
        var stderr = Pipe()
        var read: (FileHandle) throws -> Data? = ProcessOutputReader.defaultRead
    }

    func readOutput(_ io: ProcessIO, args: [String]) throws -> (Data, Data) {
        let (stdout, stderr) = ProcessOutputReader.read(process: io.process, stdout: io.stdout,
                                                     stderr: io.stderr, read: io.read)
        do { return (try stdout.get(), try stderr.get()) } catch {
            throw GitError.commandFailed(args: args, exitCode: io.process.terminationStatus,
                                         stderr: "Could not read git output: \(error.localizedDescription)")
        }
    }

}
