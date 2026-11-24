import Foundation
import VoiceMemosMCPCore

// Launcher only. Everything testable lives in VoiceMemosMCPCore, which the test target
// imports; an executable target cannot be imported.
//
// Settings come from the Claude extension manifest, which substitutes the
// person's user_config into this process's arguments.
await VoiceMemosMCPServer.run(
    configuration: Configuration.parse(Array(CommandLine.arguments.dropFirst())))
