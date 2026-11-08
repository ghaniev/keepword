import Foundation

/// Ready-made setups for the official hosted MCP servers of task and planning services:
/// the URL, how to sign in, which tool creates a task, and which listing tools fill its ID fields.
struct MCPPreset: Identifiable, Sendable {
    /// A listing tool that offers choices for a field of the task tool.
    struct Lookup: Sendable {
        let tool: String
        var value = "id"  // key in each listed object that the task tool expects
        var args: [String: String] = [:]  // listing tool parameter ← task field already chosen
    }

    let id: String
    let name: String
    let url: String
    var scope: String?  // nil: what the server asks for; "": none (the server rejects a scope parameter)
    var needsClient = false  // no dynamic client registration: the user registers an OAuth app
    var taskTool: String?
    var lookups: [String: Lookup] = [:]
    var hidden: Set<String> = []  // tool fields Keepword fills itself or that make no sense for a task
    var placeholders: [String: String] = [:]
    var note: String
    /// Builds the task tool's arguments when they aren't a flat title/description/due form.
    var build: (@Sendable (TaskMapping.Draft, [String: String]) -> [String: Any])?

    var config: MCPServerConfig {
        var c = MCPServerConfig()
        c.name = name
        c.transport = "http"
        c.url = url
        c.auth = "oauth"
        c.preset = id
        c.taskTool = taskTool
        return c
    }
}

enum MCPPresets {
    static let all: [MCPPreset] = [
        MCPPreset(
            id: "jira", name: "Jira", url: "https://mcp.atlassian.com/v2/mcp?tools=all", taskTool: "createJiraIssue",
            lookups: [
                "cloudId": .init(tool: "getAccessibleAtlassianResources"),
                "projectKey": .init(tool: "listJiraProjects", value: "key", args: ["cloudId": "cloudId"]),
                "issueType": .init(tool: "listJiraProjectIssueTypesMetadata", value: "name", args: ["cloudId": "cloudId", "projectIdOrKey": "projectKey"]),
            ],
            note: String(localized: "Atlassian's Rovo MCP server. Sign in with your Atlassian account; an admin may need to allow MCP access first. Choose the site, project and work type once, Keepword remembers them.")),
        MCPPreset(
            id: "linear", name: "Linear", url: "https://mcp.linear.app/mcp",
            lookups: ["team": .init(tool: "list_teams"), "teamId": .init(tool: "list_teams"),
                      "project": .init(tool: "list_projects"), "projectId": .init(tool: "list_projects"),
                      "assignee": .init(tool: "list_users"), "assigneeId": .init(tool: "list_users")],
            note: String(localized: "Linear's MCP server. Sign in with your Linear account, or switch to headers and paste an API key as “Authorization: Bearer <key>”.")),
        MCPPreset(
            id: "notion", name: "Notion", url: "https://mcp.notion.com/mcp", taskTool: "notion-create-pages",
            hidden: ["pages", "allow_async", "creation_mode", "is_skill"],
            placeholders: ["parent": String(localized: "Notion page link (empty: a private page)")],
            note: String(localized: "Notion's MCP server. Each follow-up becomes a page under the page you choose."),
            build: { d, shared in
                var args: [String: Any] = ["pages": [["properties": ["title": d.title], "content": d.details]]]
                if let id = MCPPresets.notionID(shared["parent"] ?? "") { args["parent"] = ["page_id": id] }
                return args
            }),
        MCPPreset(
            id: "asana", name: "Asana", url: "https://mcp.asana.com/v2/mcp", scope: "", needsClient: true,
            note: String(localized: "Asana's MCP server needs an OAuth app: create an MCP app at app.asana.com/0/my-apps, add the redirect URL below, make it available to your workspace, then paste its client ID and secret.")),
        MCPPreset(
            id: "miro", name: "Miro", url: "https://mcp.miro.com/",
            note: String(localized: "Miro's MCP server. Sign in and pick a team. Miro adds items to boards with its own tools; choose one under “Create tasks with”.")),
    ]

    static func find(_ id: String?) -> MCPPreset? { all.first { $0.id == id } }

    /// A Notion page ID from a link or a bare ID (32 hex digits, with or without dashes).
    static func notionID(_ text: String) -> String? {
        let hex = text.replacingOccurrences(of: "-", with: "")
        return hex.matches(of: #/[0-9a-fA-F]{32}/#).last.map { String($0.0) }
    }
}
