import AppKit
import SwiftUI

struct APIReferenceNativePanel: View {
    @EnvironmentObject private var appModel: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @StateObject private var reference: APIReferenceModel

    init(initialSection: APIReferenceModel.Section = .publicAPI) {
        _reference = StateObject(wrappedValue: APIReferenceModel(section: initialSection))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "API reference", subtitle: "Endpoint documentation, schemas, examples, and authentication") {
                HStack(spacing: 10) {
                    SearchFieldRow(placeholder: "Search endpoints and schemas", text: $reference.query)
                    ActionButton(title: reference.isLoading ? "Loading…" : "Refresh", icon: "arrow.clockwise") {
                        Task { await reference.refresh(websiteBaseURL: appModel.settings.websiteBaseURL) }
                    }
                    .disabled(reference.isLoading)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(APIReferenceModel.Section.allCases) { section in
                            FilterChip(title: section.rawValue, active: reference.section == section) {
                                reference.section = section
                            }
                        }
                    }
                }
                if !reference.errorMessage.isEmpty { NativeNotice(message: reference.errorMessage) }
                if reference.isLoading && reference.document == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading public API contract…").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary) }
                }
            }

            if let document = reference.document {
                switch reference.section {
                case .publicAPI:
                    NativeGroupPanel(title: document.info.title, subtitle: "Version \(document.info.version) · \(document.operations.count) operations · \(document.schemas.count) schemas") {
                        if let description = document.info.description, !description.isEmpty {
                            Text(description).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                        }
                        Text("Base URL: \(document.servers?.first?.url ?? "Not declared in the contract")")
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                        operationList(document: document, rows: reference.operationRows, isApplication: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .applicationAPI:
                    NativeGroupPanel(title: "Application API", subtitle: "Website snapshot · \(APIReferenceSnapshot.current.documentationSource) · Fictional examples") {
                        Text("Application authentication applies. The source snapshot does not specify every endpoint access rule.")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                        operationList(document: document, rows: reference.operationRows, isApplication: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .schemas:
                    NativeGroupPanel(title: "Schemas", subtitle: "\(reference.filteredSchemas.count) matching schemas") {
                        if reference.filteredSchemas.isEmpty {
                            NativeEmptyState(title: "No matching schemas", message: "Try a different search term.")
                        } else {
                            ForEach(reference.filteredSchemas, id: \.0) { name, value in
                                NativeGroupPanel(title: name, subtitle: reference.expandedSchemas.contains(name) ? "Schema definition" : "Select to inspect", fillsAvailableWidth: true) {
                                    Button(reference.expandedSchemas.contains(name) ? "Hide schema" : "Show schema") {
                                        reference.toggleSchema(name)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityLabel("\(reference.expandedSchemas.contains(name) ? "Hide" : "Show") schema \(name)")
                                    if reference.expandedSchemas.contains(name) { jsonView(value.prettyJSON) }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .json:
                    NativeGroupPanel(title: "OpenAPI JSON", subtitle: "Select text to copy") {
                        jsonView(reference.rawJSON)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !reference.isLoading && reference.errorMessage.isEmpty {
                NativeEmptyState(title: "Load API documentation", message: "Refresh to retrieve endpoint details and schemas from the public OpenAPI contract.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await reference.refresh(websiteBaseURL: appModel.settings.websiteBaseURL) }
        .onDisappear { reference.invalidate() }
    }

    @ViewBuilder
    private func operationList(document: APIReferenceDocument, rows: [APIReferenceOperationRow], isApplication: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(rows.count) matching operations")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
            if rows.isEmpty {
                NativeEmptyState(title: "No matching endpoints", message: "Try another method, path, or description.")
            } else {
                ForEach(rows) { row in
                    let example = isApplication ? APIReferenceSnapshot.current.responseExamples[row.id] : nil
                    NativeGroupPanel(title: "\(row.method)  \(row.path)", subtitle: row.operation.summary ?? row.operation.operationId ?? "Endpoint", fillsAvailableWidth: true) {
                        Button(reference.expandedRows.contains(row.id) ? "Hide details" : "Show details") {
                            reference.toggleOperation(row.id)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("\(reference.expandedRows.contains(row.id) ? "Hide" : "Show") details for \(row.method) \(row.path)")
                        if reference.expandedRows.contains(row.id) {
                            operationDetails(document: document, operation: row.operation, isApplication: isApplication, example: example)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func operationDetails(document: APIReferenceDocument, operation: APIReferenceDocument.Operation, isApplication: Bool, example: APIReferenceSnapshot.Example?) -> some View {
        Text(isApplication ? "Authentication: Hanasand application authentication applies; endpoint-level rules are not included in this snapshot." : "Security: \(APIReferenceSecurity.label(operation: operation.security, document: document.security))")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
        if !isApplication, case .object(let schemes)? = document.components?["securitySchemes"] {
            ForEach(securitySchemeNames(document: document, operation: operation), id: \.self) { name in
                if let scheme = schemes[name] { jsonSection("Security scheme · \(name)", scheme) }
            }
        }
        if let description = operation.description, !description.isEmpty {
            Text(description).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
        }
        if let parameters = operation.parameters, !parameters.isEmpty {
            jsonSection("Parameters", .array(parameters))
        }
        if let requestBody = operation.requestBody {
            jsonSection("Request body", requestBody)
        } else {
            Text("No request body documented.").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
        }
        if operation.responses.isEmpty {
            Text("No response schema documented.").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
        } else {
            ForEach(operation.responses.keys.sorted(), id: \.self) { status in
                if let response = operation.responses[status] { jsonSection("Response · HTTP \(status)", response) }
            }
        }
        if let example {
            Text("Fictional response example · HTTP \(example.status)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
            Text("Names, addresses, and credentials are illustrative.")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
            jsonView(example.body.prettyJSON)
        }
    }

    private func securitySchemeNames(document: APIReferenceDocument, operation: APIReferenceDocument.Operation) -> [String] {
        let requirements = operation.security ?? document.security ?? []
        var names = Set<String>()
        for requirement in requirements {
            if case .object(let schemes) = requirement { names.formUnion(schemes.keys) }
        }
        return names.sorted()
    }

    private func jsonSection(_ title: String, _ value: APIReferenceJSONValue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
            jsonView(value.prettyJSON)
        }
    }

    private func jsonView(_ value: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 330)
        .background(theme.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
