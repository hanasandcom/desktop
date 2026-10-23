import Foundation

struct APIReferenceDocument: Decodable {
    struct Info: Decodable {
        let title: String
        let version: String
        let description: String?
    }

    struct Operation: Decodable {
        let summary: String?
        let description: String?
        let operationId: String?
        let security: [APIReferenceJSONValue]?
        let parameters: [APIReferenceJSONValue]?
        let requestBody: APIReferenceJSONValue?
        let responses: [String: APIReferenceJSONValue]
    }

    let openapi: String
    let info: Info
    let servers: [Server]?
    let paths: [String: [String: APIReferenceJSONValue]]
    let components: [String: APIReferenceJSONValue]?
    let security: [APIReferenceJSONValue]?

    struct Server: Decodable { let url: String }

    var operations: [APIReferenceOperationRow] {
        var result: [APIReferenceOperationRow] = []
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for (path, pathValues) in paths {
            for (method, value) in pathValues {
                guard APIReferenceOperation.methods.contains(method.lowercased()), value.objectValue != nil,
                      let data = try? encoder.encode(value),
                      let operation = try? decoder.decode(Operation.self, from: data) else { continue }
                result.append(APIReferenceOperationRow(method: method.uppercased(), path: path, operation: operation))
            }
        }
        return result.sorted { left, right in
            if left.path == right.path { return left.method < right.method }
            return left.path < right.path
        }
    }

    var schemas: [String: APIReferenceJSONValue] {
        guard let components,
              case .object(let schemas)? = components["schemas"] else { return [:] }
        return schemas
    }

    static func decode(_ data: Data) throws -> APIReferenceDocument {
        guard data.count <= APIReferenceClient.documentLimit else { throw APIReferenceError.tooLarge }
        let document: APIReferenceDocument
        do { document = try JSONDecoder().decode(APIReferenceDocument.self, from: data) }
        catch { throw APIReferenceError.invalidDocument }
        guard document.openapi.range(of: #"^3\.(0|1)\.\d+$"#, options: .regularExpression) != nil,
              !document.info.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !document.info.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              document.paths.keys.allSatisfy({ $0.hasPrefix("/") }),
              document.operations.count == document.paths.values.reduce(0, { count, path in
                  count + path.keys.filter { APIReferenceOperation.methods.contains($0.lowercased()) }.count
              }) else { throw APIReferenceError.invalidDocument }
        return document
    }
}

struct APIReferenceOperation {
    static let methods: Set<String> = ["get", "post", "put", "patch", "delete", "head", "options", "trace"]
}

struct APIReferenceOperationRow: Identifiable {
    let method: String
    let path: String
    let operation: APIReferenceDocument.Operation
    var id: String { "\(method) \(path)" }

    func matches(_ query: String) -> Bool {
        query.isEmpty || "\(method) \(path) \(operation.summary ?? "") \(operation.operationId ?? "") \(operation.description ?? "")"
            .localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum APIReferenceSecurity {
    static func label(operation: [APIReferenceJSONValue]?, document: [APIReferenceJSONValue]?) -> String {
        guard let requirements = operation ?? document else { return "Public (no security requirement declared)" }
        guard !requirements.isEmpty else { return "Public" }
        if requirements.contains(where: { requirement in
            guard case .object(let schemes) = requirement else { return false }
            return schemes.isEmpty
        }) { return "Public" }
        return requirements.map { requirement in
            guard case .object(let schemes) = requirement else { return "Invalid requirement" }
            return schemes.keys.sorted().map { name in
                let scopes: [String]
                if case .array(let values)? = schemes[name] {
                    scopes = values.compactMap { if case .string(let value) = $0 { value } else { nil } }
                } else {
                    scopes = []
                }
                return scopes.isEmpty ? name : "\(name) (\(scopes.joined(separator: ", ")))"
            }.joined(separator: " + ")
        }.joined(separator: " OR ")
    }
}

enum APIReferenceJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: APIReferenceJSONValue])
    case array([APIReferenceJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: APIReferenceJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([APIReferenceJSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: APIReferenceJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let value = String(data: data, encoding: .utf8) else { return "null" }
        return value
    }
}

struct APIReferenceSnapshot: Decodable {
    struct Endpoint: Decodable, Identifiable {
        let method: String
        let path: String
        let summary: String
        var id: String { "\(method) \(path)" }
        func matches(_ query: String) -> Bool {
            query.isEmpty || "\(method) \(path) \(summary)".localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    struct Example: Decodable {
        let status: Int
        let body: APIReferenceJSONValue
    }

    let documentationSource: String
    let applicationEndpoints: [Endpoint]
    let responseExamples: [String: Example]

    static let current: APIReferenceSnapshot = {
        do { return try JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
        catch { preconditionFailure("Bundled API reference snapshot is invalid: \(error)") }
    }()

    static let json = #"""
    {
      "documentationSource": "a71de4414381d2dc11ae03d3a912dba96223e538",
      "applicationEndpoints": [
        {
          "method": "POST",
          "path": "/billing/portal",
          "summary": "Create a billing portal session"
        },
        {
          "method": "GET",
          "path": "/billing/subscription",
          "summary": "Read billing subscription"
        },
        {
          "method": "GET",
          "path": "/findings/webhook-destinations",
          "summary": "List webhook destinations"
        },
        {
          "method": "POST",
          "path": "/findings/webhook-destinations",
          "summary": "Create a webhook destination"
        },
        {
          "method": "DELETE",
          "path": "/findings/webhook-destinations/:id",
          "summary": "Delete a webhook destination"
        },
        {
          "method": "PUT",
          "path": "/findings/webhook-destinations/:id",
          "summary": "Update a webhook destination"
        },
        {
          "method": "GET",
          "path": "/organizations",
          "summary": "List organizations"
        },
        {
          "method": "POST",
          "path": "/organizations",
          "summary": "Create an organization"
        },
        {
          "method": "GET",
          "path": "/organizations/:id",
          "summary": "Read an organization"
        },
        {
          "method": "GET",
          "path": "/organizations/:id/api-keys",
          "summary": "List organization API keys"
        },
        {
          "method": "POST",
          "path": "/organizations/:id/api-keys",
          "summary": "Create an organization API key"
        },
        {
          "method": "DELETE",
          "path": "/organizations/:id/api-keys/:keyId",
          "summary": "Revoke an organization API key"
        },
        {
          "method": "GET",
          "path": "/organizations/:id/members",
          "summary": "List organization members"
        },
        {
          "method": "GET",
          "path": "/organizations/:id/settings",
          "summary": "Read organization settings"
        },
        {
          "method": "PUT",
          "path": "/organizations/:id/settings",
          "summary": "Update organization settings"
        },
        {
          "method": "GET",
          "path": "/organizations/:id/watchlists",
          "summary": "List organization watchlists"
        },
        {
          "method": "POST",
          "path": "/organizations/:id/watchlists",
          "summary": "Create a watchlist item"
        },
        {
          "method": "DELETE",
          "path": "/project/:alias",
          "summary": "Delete a shared project"
        },
        {
          "method": "GET",
          "path": "/project/:alias",
          "summary": "Read a shared project"
        },
        {
          "method": "GET",
          "path": "/projects/user/:id",
          "summary": "List the current user’s projects"
        },
        {
          "method": "POST",
          "path": "/share",
          "summary": "Create or update a shared file"
        },
        {
          "method": "DELETE",
          "path": "/share/:id",
          "summary": "Delete a shared file"
        },
        {
          "method": "GET",
          "path": "/share/:id",
          "summary": "Read a shared file"
        },
        {
          "method": "PUT",
          "path": "/share/:id",
          "summary": "Update a shared file"
        },
        {
          "method": "PUT",
          "path": "/share/lock/:id",
          "summary": "Set a share lock state",
          "requestBody": {
            "required": true,
            "content": {
              "application/json": {
                "schema": {
                  "type": "object",
                  "required": [
                    "locked"
                  ],
                  "properties": {
                    "locked": {
                      "type": "boolean"
                    }
                  }
                }
              }
            }
          }
        },
        {
          "method": "GET",
          "path": "/share/tree/:id",
          "summary": "Read a share file tree"
        },
        {
          "method": "GET",
          "path": "/share/user/:id",
          "summary": "List the current user’s shares"
        },
        {
          "method": "GET",
          "path": "/support/tickets",
          "summary": "List support tickets"
        },
        {
          "method": "POST",
          "path": "/support/tickets",
          "summary": "Create a support ticket"
        },
        {
          "method": "GET",
          "path": "/support/tickets/:id/messages",
          "summary": "List support messages"
        },
        {
          "method": "POST",
          "path": "/support/tickets/:id/messages",
          "summary": "Post a support message"
        },
        {
          "method": "GET",
          "path": "/ti/enrichment",
          "summary": "Read threat-intelligence enrichment"
        },
        {
          "method": "POST",
          "path": "/ti/enrichment/run",
          "summary": "Run threat-intelligence enrichment"
        },
        {
          "method": "DELETE",
          "path": "/ti/saved-searches",
          "summary": "Delete a saved search"
        },
        {
          "method": "GET",
          "path": "/ti/saved-searches",
          "summary": "List saved searches"
        },
        {
          "method": "POST",
          "path": "/ti/saved-searches",
          "summary": "Save a search"
        }
      ],
      "responseExamples": {
        "GET /share/:id": {
          "status": 200,
          "body": {
            "id": "share_example",
            "path": "review-notes.md",
            "content": "Review the vendor documentation before Friday.",
            "wordCount": 6,
            "estimatedMinutes": 1,
            "timestamp": "2026-06-12T09:30:00Z",
            "git": null,
            "locked": false,
            "owner": "user_example",
            "parent": "",
            "alias": "review-notes",
            "type": "file"
          }
        },
        "GET /share/tree/:id": {
          "status": 200,
          "body": [
            {
              "id": "share_example",
              "name": "review-notes.md",
              "type": "file"
            }
          ]
        },
        "GET /share/user/:id": {
          "status": 200,
          "body": [
            {
              "id": "share_example",
              "path": "review-notes.md",
              "content": "Review the vendor documentation before Friday.",
              "wordCount": 6,
              "estimatedMinutes": 1,
              "timestamp": "2026-06-12T09:30:00Z",
              "git": null,
              "locked": false,
              "owner": "user_example",
              "parent": "",
              "alias": "review-notes",
              "type": "file"
            }
          ]
        },
        "PUT /share/lock/:id": {
          "status": 200,
          "body": {
            "id": "share_example",
            "path": "review-notes.md",
            "content": "Review the vendor documentation before Friday.",
            "wordCount": 6,
            "estimatedMinutes": 1,
            "timestamp": "2026-06-12T09:30:00Z",
            "git": null,
            "locked": true,
            "owner": "user_example",
            "parent": "",
            "alias": "review-notes",
            "type": "file"
          }
        },
        "POST /share": {
          "status": 201,
          "body": {
            "id": "share_example",
            "path": "review-notes.md",
            "content": "Review the vendor documentation before Friday.",
            "wordCount": 6,
            "estimatedMinutes": 1,
            "timestamp": "2026-06-12T09:30:00Z",
            "git": null,
            "locked": false,
            "owner": "user_example",
            "parent": "",
            "alias": "review-notes",
            "type": "file"
          }
        },
        "PUT /share/:id": {
          "status": 200,
          "body": {
            "id": "share_example",
            "path": "review-notes.md",
            "content": "Review the vendor documentation before Friday.",
            "wordCount": 6,
            "estimatedMinutes": 1,
            "timestamp": "2026-06-12T09:30:00Z",
            "git": null,
            "locked": false,
            "owner": "user_example",
            "parent": "",
            "alias": "review-notes",
            "type": "file"
          }
        },
        "DELETE /share/:id": {
          "status": 200,
          "body": {
            "deleted": "share_example"
          }
        },
        "GET /project/:alias": {
          "status": 200,
          "body": {
            "share": {
              "id": "share_example",
              "path": "review-notes.md",
              "content": "Review the vendor documentation before Friday.",
              "wordCount": 6,
              "estimatedMinutes": 1,
              "timestamp": "2026-06-12T09:30:00Z",
              "git": null,
              "locked": false,
              "owner": "user_example",
              "parent": "",
              "alias": "review-notes",
              "type": "file"
            },
            "tree": [
              {
                "id": "share_example",
                "name": "review-notes.md",
                "type": "file"
              }
            ]
          }
        },
        "GET /projects/user/:id": {
          "status": 200,
          "body": [
            {
              "alias": "review-notes",
              "owner": "user_example",
              "editors": [
                "user_example"
              ],
              "file_count": 1,
              "total_size": 50,
              "last_updated": "2026-06-12T09:30:00Z"
            }
          ]
        },
        "DELETE /project/:alias": {
          "status": 200,
          "body": {
            "deleted": "review-notes"
          }
        },
        "GET /support/tickets": {
          "status": 200,
          "body": {
            "role": "user",
            "tickets": [
              {
                "id": "ticket_example",
                "user_id": "user_example",
                "user_name": "Morgan Reed",
                "subject": "Help connecting a webhook",
                "status": "open",
                "created_at": "2026-06-12T09:30:00Z",
                "updated_at": "2026-06-12T09:30:00Z",
                "last_message": "Where can I send a test notification?"
              }
            ]
          }
        },
        "POST /support/tickets": {
          "status": 201,
          "body": {
            "id": "ticket_example"
          }
        },
        "GET /support/tickets/:id/messages": {
          "status": 200,
          "body": {
            "messages": [
              {
                "id": "message_example",
                "sender_id": "user_example",
                "sender_name": "Morgan Reed",
                "body": "Where can I send a test notification?",
                "created_at": "2026-06-12T09:30:00Z"
              }
            ]
          }
        },
        "POST /support/tickets/:id/messages": {
          "status": 200,
          "body": {
            "ok": true
          }
        },
        "GET /ti/enrichment": {
          "status": 410,
          "body": {
            "ok": false,
            "error": "api_ti_enrichment_retired",
            "canonicalRoute": "/v1/intel/search"
          }
        },
        "POST /ti/enrichment/run": {
          "status": 409,
          "body": {
            "ok": false,
            "error": "api_ti_enrichment_retired",
            "canonicalRoute": "/v1/intel/search"
          }
        },
        "GET /ti/saved-searches": {
          "status": 200,
          "body": {
            "savedSearches": [
              {
                "query": "cedar-bay.example.com",
                "savedAt": "2026-06-12T09:30:00Z"
              }
            ]
          }
        },
        "POST /ti/saved-searches": {
          "status": 201,
          "body": {
            "savedSearch": {
              "query": "cedar-bay.example.com",
              "savedAt": "2026-06-12T09:30:00Z"
            }
          }
        },
        "DELETE /ti/saved-searches": {
          "status": 200,
          "body": {
            "ok": true
          }
        },
        "GET /organizations": {
          "status": 200,
          "body": {
            "organizations": [
              {
                "id": "org_example",
                "name": "Cedar Bay Studio",
                "slug": "cedar-bay-studio",
                "role": "owner",
                "status": "active"
              }
            ]
          }
        },
        "POST /organizations": {
          "status": 201,
          "body": {
            "organization": {
              "id": "org_example",
              "name": "Cedar Bay Studio",
              "slug": "cedar-bay-studio",
              "role": "owner",
              "status": "active"
            }
          }
        },
        "GET /organizations/:id": {
          "status": 200,
          "body": {
            "organization": {
              "id": "org_example",
              "name": "Cedar Bay Studio",
              "slug": "cedar-bay-studio",
              "role": "owner",
              "status": "active"
            }
          }
        },
        "GET /organizations/:id/members": {
          "status": 200,
          "body": {
            "organization": {
              "id": "org_example",
              "name": "Cedar Bay Studio",
              "slug": "cedar-bay-studio",
              "role": "owner",
              "status": "active"
            },
            "members": [
              {
                "userId": "user_example",
                "name": "Morgan Reed",
                "organizationId": "org_example",
                "role": "owner",
                "status": "active",
                "joinedAt": "2026-06-12T09:30:00Z"
              }
            ]
          }
        },
        "GET /organizations/:id/settings": {
          "status": 200,
          "body": {
            "organization": {
              "id": "org_example",
              "name": "Cedar Bay Studio",
              "slug": "cedar-bay-studio",
              "role": "owner",
              "status": "active"
            },
            "settings": {
              "name": "Cedar Bay Studio",
              "slug": "cedar-bay-studio",
              "defaultWebhookPolicy": "disabled",
              "alertVisibilityPolicy": "members",
              "lifecycleStatus": "active",
              "retentionDays": 90
            }
          }
        },
        "PUT /organizations/:id/settings": {
          "status": 200,
          "body": {
            "organization": {
              "id": "org_example",
              "name": "Cedar Bay Studio",
              "slug": "cedar-bay-studio",
              "role": "owner",
              "status": "active"
            },
            "settings": {
              "name": "Cedar Bay Studio",
              "slug": "cedar-bay-studio",
              "defaultWebhookPolicy": "disabled",
              "alertVisibilityPolicy": "members",
              "lifecycleStatus": "active",
              "retentionDays": 90
            }
          }
        },
        "GET /organizations/:id/api-keys": {
          "status": 200,
          "body": {
            "organizationId": "org_example",
            "apiKeys": [
              {
                "id": "key_example",
                "name": "Reporting integration",
                "organizationId": "org_example",
                "keyPrefix": "example_",
                "enabled": true,
                "createdAt": "2026-06-12T09:30:00Z"
              }
            ]
          }
        },
        "POST /organizations/:id/api-keys": {
          "status": 201,
          "body": {
            "apiKey": {
              "id": "key_example",
              "name": "Reporting integration",
              "organizationId": "org_example",
              "keyPrefix": "example_",
              "enabled": true,
              "createdAt": "2026-06-12T09:30:00Z"
            },
            "secret": "example-not-a-valid-api-key"
          }
        },
        "DELETE /organizations/:id/api-keys/:keyId": {
          "status": 200,
          "body": {
            "apiKey": {
              "id": "key_example",
              "name": "Reporting integration",
              "organizationId": "org_example",
              "keyPrefix": "example_",
              "enabled": false,
              "createdAt": "2026-06-12T09:30:00Z"
            }
          }
        },
        "GET /organizations/:id/watchlists": {
          "status": 200,
          "body": {
            "organization": {
              "id": "org_example",
              "name": "Cedar Bay Studio",
              "slug": "cedar-bay-studio",
              "role": "owner",
              "status": "active"
            },
            "watchlistItems": [
              {
                "id": "watch_example",
                "organizationId": "org_example",
                "kind": "domain",
                "value": "cedar-bay.example.com",
                "notes": "Monitor our public website.",
                "status": "active",
                "createdAt": "2026-06-12T09:30:00Z",
                "updatedAt": "2026-06-12T09:30:00Z"
              }
            ]
          }
        },
        "POST /organizations/:id/watchlists": {
          "status": 201,
          "body": {
            "watchlistItem": {
              "id": "watch_example",
              "organizationId": "org_example",
              "kind": "domain",
              "value": "cedar-bay.example.com",
              "notes": "Monitor our public website.",
              "status": "active",
              "createdAt": "2026-06-12T09:30:00Z",
              "updatedAt": "2026-06-12T09:30:00Z"
            }
          }
        },
        "GET /findings/webhook-destinations": {
          "status": 200,
          "body": {
            "destinations": [
              {
                "id": "destination_example",
                "orgId": "org_example",
                "name": "Security inbox",
                "kind": "webhook",
                "endpointHint": "https://hooks.example.com/…",
                "status": "active",
                "events": [
                  "dwm.alert.created"
                ],
                "signingConfigured": true,
                "createdAt": "2026-06-12T09:30:00Z"
              }
            ]
          }
        },
        "POST /findings/webhook-destinations": {
          "status": 201,
          "body": {
            "destination": {
              "id": "destination_example",
              "orgId": "org_example",
              "name": "Security inbox",
              "kind": "webhook",
              "endpointHint": "https://hooks.example.com/…",
              "status": "active",
              "events": [
                "dwm.alert.created"
              ],
              "signingConfigured": true,
              "createdAt": "2026-06-12T09:30:00Z"
            }
          }
        },
        "PUT /findings/webhook-destinations/:id": {
          "status": 200,
          "body": {
            "destination": {
              "id": "destination_example",
              "orgId": "org_example",
              "name": "Security inbox",
              "kind": "webhook",
              "endpointHint": "https://hooks.example.com/…",
              "status": "active",
              "events": [
                "dwm.alert.created"
              ],
              "signingConfigured": true,
              "createdAt": "2026-06-12T09:30:00Z"
            }
          }
        },
        "DELETE /findings/webhook-destinations/:id": {
          "status": 200,
          "body": {
            "destination": {
              "id": "destination_example",
              "orgId": "org_example",
              "name": "Security inbox",
              "kind": "webhook",
              "endpointHint": "https://hooks.example.com/…",
              "status": "archived",
              "events": [
                "dwm.alert.created"
              ],
              "signingConfigured": true,
              "createdAt": "2026-06-12T09:30:00Z",
              "updatedAt": "2026-06-12T09:30:00Z"
            }
          }
        },
        "GET /billing/subscription": {
          "status": 200,
          "body": {
            "subscription": null,
            "entitlements": [],
            "quotas": []
          }
        },
        "POST /billing/portal": {
          "status": 200,
          "body": {
            "url": "https://billing.example.com/session/example-session"
          }
        },
        "POST /ti/search": {
          "status": 200,
          "body": {
            "query": "cedar-bay.example.com",
            "queryKind": "domain",
            "generatedAt": "2026-06-12T09:30:00Z",
            "mode": "scraper",
            "status": "ready",
            "summary": "One public report mentions the domain. An analyst has not yet confirmed the finding.",
            "confidence": 0.72,
            "aliases": [],
            "recentActivity": [
              {
                "date": "2026-06-12",
                "title": "Domain mentioned in a public report",
                "detail": "The report lists the domain among affected websites.",
                "confidence": 0.72,
                "sourceIds": [
                  "source_example"
                ]
              }
            ],
            "targets": [],
            "ttps": [],
            "datasets": [],
            "sources": [
              {
                "id": "source_example",
                "name": "Harbor Security Bulletin",
                "type": "vendor_report",
                "provenance": "Public advisory",
                "url": "https://reports.example.com/advisories/42"
              }
            ],
            "notes": [
              "Review the source report before taking action."
            ]
          }
        },
        "POST /ti/search/batch": {
          "status": 200,
          "body": {
            "generatedAt": "2026-06-12T09:30:00Z",
            "count": 1,
            "partial": false,
            "results": [
              {
                "query": "cedar-bay.example.com",
                "status": "ok",
                "result": {
                  "query": "cedar-bay.example.com",
                  "queryKind": "domain",
                  "generatedAt": "2026-06-12T09:30:00Z",
                  "mode": "scraper",
                  "status": "ready",
                  "summary": "One public report mentions the domain. An analyst has not yet confirmed the finding.",
                  "confidence": 0.72,
                  "aliases": [],
                  "recentActivity": [
                    {
                      "date": "2026-06-12",
                      "title": "Domain mentioned in a public report",
                      "detail": "The report lists the domain among affected websites.",
                      "confidence": 0.72,
                      "sourceIds": [
                        "source_example"
                      ]
                    }
                  ],
                  "targets": [],
                  "ttps": [],
                  "datasets": [],
                  "sources": [
                    {
                      "id": "source_example",
                      "name": "Harbor Security Bulletin",
                      "type": "vendor_report",
                      "provenance": "Public advisory",
                      "url": "https://reports.example.com/advisories/42"
                    }
                  ],
                  "notes": [
                    "Review the source report before taking action."
                  ]
                }
              }
            ]
          }
        },
        "GET /actors": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "actor_example",
                "canonicalName": "Copper Finch",
                "aliases": [
                  "Finch Group"
                ],
                "confidence": 0.78,
                "sourceIds": [
                  "source_example"
                ],
                "captureIds": [
                  "capture_example"
                ]
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        },
        "GET /aliases": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "alias_example",
                "actorProfileId": "actor_example",
                "alias": "Finch Group",
                "normalizedAlias": "finch group",
                "confidence": 0.78,
                "sourceIds": [
                  "source_example"
                ]
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        },
        "GET /incidents": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "incident_example",
                "title": "Reported disruption at Cedar Bay Studio",
                "summary": "A public advisory describes a brief website outage. Attribution remains unconfirmed.",
                "assertionKind": "inferred",
                "reviewState": "needs_review",
                "actorAttribution": null
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        },
        "GET /findings": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "finding_example",
                "claimType": "domain_mention",
                "subjectType": "domain",
                "subjectId": "cedar-bay.example.com",
                "value": {
                  "value": "cedar-bay.example.com",
                  "summary": "Domain named in a public advisory."
                },
                "summary": "A public advisory mentions the monitored domain.",
                "confidence": 0.72,
                "reviewState": "needs_review",
                "sourceIds": [
                  "source_example"
                ],
                "captureIds": [
                  "capture_example"
                ]
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        },
        "GET /evidence": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "evidence_example",
                "captureId": "capture_example",
                "subjectType": "incident",
                "subjectId": "incident_example",
                "relationship": "supports",
                "confidence": 0.72
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        },
        "GET /sources": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "source_example",
                "name": "Harbor Security Bulletin",
                "type": "vendor_report",
                "status": "active",
                "risk": "low",
                "trustScore": 0.85,
                "tags": [
                  "public-advisories"
                ],
                "url": "https://reports.example.com",
                "urlHash": "example-url-hash",
                "locatorRedacted": false,
                "operatingMode": {
                  "accessMethod": "https",
                  "metadataOnly": false,
                  "approvalState": "approved"
                },
                "collection": {
                  "cadenceSeconds": 3600
                }
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        },
        "GET /validations": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "validation_example",
                "validationType": "source_comparison",
                "status": "unconfirmed",
                "referenceUrl": "https://reports.example.com/advisories/42",
                "matchedAt": "2026-06-12T09:30:00Z",
                "notes": "An independent report has not yet confirmed the claim."
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        },
        "GET /alerts": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "alert_example",
                "assertionKind": "inferred",
                "reviewState": "needs_review",
                "summary": "A new public report mentions cedar-bay.example.com.",
                "severity": "medium",
                "evidence": {
                  "captureIds": [
                    "capture_example"
                  ],
                  "sourceIds": [
                    "source_example"
                  ],
                  "evidenceCount": 1,
                  "sourceCount": 1,
                  "metadataOnly": true
                }
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        },
        "GET /evaluation": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "evaluation_example",
                "labelType": "domain_extraction",
                "outcome": "correct",
                "labeledBy": "reviewer_example",
                "labelingMethod": "manual",
                "labeledAt": "2026-06-12T09:30:00Z",
                "datasetSplit": "test",
                "expectedValue": "cedar-bay.example.com",
                "observedValue": "cedar-bay.example.com"
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        },
        "GET /timeliness": {
          "status": 200,
          "body": {
            "data": [
              {
                "id": "timeliness_example",
                "sourceId": "source_example",
                "captureId": "capture_example",
                "incidentId": "incident_example",
                "publishedAt": "2026-06-12T09:00:00Z",
                "collectedAt": "2026-06-12T09:05:00Z",
                "processedAt": "2026-06-12T09:06:00Z",
                "timestampAnomalies": [],
                "latencies": {
                  "publicationToCollectionSeconds": 300,
                  "collectionToProcessingSeconds": 60
                }
              }
            ],
            "pagination": {
              "page": 1,
              "limit": 50,
              "total": 1,
              "totalPages": 1,
              "nextPage": null,
              "nextCursor": null
            },
            "meta": {
              "requestId": "request_example"
            }
          }
        }
      }
    }
    """#
}

enum APIReferenceError: LocalizedError {
    case invalidURL
    case unavailable(Int)
    case tooLarge
    case invalidDocument

    var errorDescription: String? {
        switch self {
        case .invalidURL: "API documentation requires an HTTPS website URL without credentials, query, or fragment."
        case .unavailable(let status): "API documentation is unavailable (HTTP \(status)). Refresh to retry."
        case .tooLarge: "The API contract exceeds the 2 MB display limit."
        case .invalidDocument: "The API documentation service returned an invalid OpenAPI 3 contract."
        }
    }
}
