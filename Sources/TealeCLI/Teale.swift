import ArgumentParser

@main
struct Teale: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teale",
        abstract: "Teale decentralized AI inference node",
        subcommands: [Up.self, Down.self, Login.self, Serve.self, Status.self, Models.self, Chat.self]
    )
}
