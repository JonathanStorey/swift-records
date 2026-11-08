import Foundation

// From Terminal with a command, such as `./run.sh scenarios`, the app prints results and quits. Run from
// Xcode or opened from Finder, it shows a window. Xcode adds arguments of its own that start with "-".
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, CommandLineRun.commands.contains(command) {
    Task { await CommandLineRun.main(arguments) }
    dispatchMain()
} else {
    LiveApp.main()
}
