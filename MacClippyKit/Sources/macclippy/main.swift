import Foundation

import MacClippyCore

@main
enum MacClippyCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            print(help)
            return
        }
        if arguments == ["mcp-tools"] {
            for tool in MacClippyQueryMCPPolicy.tools {
                print("\(tool.name)\t\(tool.description)")
            }
            return
        }

        do {
            _ = try MacClippyQueryCLIPolicy.parse(arguments)
            if MacClippyQueryExecutionPolicy.requiresAttachedCatalog {
                fputs("macclippy: \(MacClippyQueryExecutionPolicy.unattachedLibraryMessage)\n", stderr)
                exit(3)
            }
        } catch let error as MacClippyQueryCLIError {
            fputs("macclippy: \(error.message)\n", stderr)
            exit(2)
        } catch {
            fputs("macclippy: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static let help = """
        macclippy — local clipboard query (same API as MCP)

        Commands:
          search <query> [--scope pinboards|all-non-concealed|all] [--limit N]
          get <id> [--scope pinboards|all-non-concealed|all]
          pin <id> --board <name>
          save <text> [--board <name>]
          mcp-tools

        Default scope exposes pinboard items that are not concealed.
        The CLI parses the same request type as MCP. Live search/get/pin/save
        run inside the MacClippy app, not this executable.
        """
}
