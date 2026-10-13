import Foundation
import Darwin

exit(CLIEntry.run(arguments: Array(CommandLine.arguments.dropFirst()),
    appSupport: PathConstants.pensieveAppSupportDir, executable: CommandLine.arguments[0]))
