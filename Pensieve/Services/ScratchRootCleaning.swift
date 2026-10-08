/// One best-effort launch cleanup, shared by the GitHub-skill services. The caller names the root.
protocol ScratchRootCleaning {}

extension ScratchRootCleaning {
    static func cleanupScratchRoot(fileService: FileServiceProtocol = FileService(), scratchRoot: String) {
        if fileService.directoryExists(at: scratchRoot) || fileService.isSymlink(at: scratchRoot) {
            try? fileService.deleteDirectory(at: scratchRoot)
        } else if fileService.fileExists(at: scratchRoot) {
            try? fileService.deleteFile(at: scratchRoot)
        }
    }
}
