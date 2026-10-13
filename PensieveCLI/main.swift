import Foundation
import Darwin
import MachO

// argv[0] can be just a PATH name. dyld identifies the loaded executable; FileService resolves its links.
var executableSize: UInt32 = 0
_NSGetExecutablePath(nil, &executableSize)
var executablePath = [CChar](repeating: 0, count: Int(executableSize))
guard _NSGetExecutablePath(&executablePath, &executableSize) == 0 else {
    FileHandle.standardError.write(Data("Unable to locate the pensieve executable\n".utf8))
    exit(1)
}
exit(CLIEntry.run(arguments: Array(CommandLine.arguments.dropFirst()),
    appSupport: PathConstants.pensieveAppSupportDir, executable: String(cString: executablePath)))
