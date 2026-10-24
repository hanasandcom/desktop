import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct NativeAuthenticatorPanel: View {
    private let vault: any NativeAuthenticatorVault
    @State private var entries: [NativeAuthenticatorEntry] = []
    @State private var label = ""
    @State private var secretOrURI = ""
    @State private var message: String?
    @State private var isImportingQR = false
    @State private var pendingDeletion: NativeAuthenticatorEntry?

    init(vault: any NativeAuthenticatorVault = KeychainNativeAuthenticatorVault()) {
        self.vault = vault
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Authenticator").font(.largeTitle.weight(.semibold))
                    Text("Store TOTP secrets in this Mac’s Keychain and copy codes here.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Add an account") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Account label", text: $label)
                            .textFieldStyle(.roundedBorder)
                        TextField("Base32 secret or otpauth:// URI", text: $secretOrURI, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                        HStack {
                            Button("Choose QR image…") { isImportingQR = true }
                            Spacer()
                            Button("Add code", action: addEntry)
                                .keyboardShortcut(.defaultAction)
                                .disabled(secretOrURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.top, 5)
                }

                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(message.hasPrefix("Added") || message.hasPrefix("Updated") ? .green : .red)
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved codes").font(.title2.weight(.semibold))
                    if entries.isEmpty {
                        ContentUnavailableView("No authenticator codes", systemImage: "key.horizontal", description: Text("Add a Base32 secret or choose an image containing a TOTP QR code."))
                            .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ForEach(entries) { entry in
                            AuthenticatorCodeRow(entry: entry, onCopy: { copy(entry) }, onDelete: { pendingDeletion = entry })
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: reload)
        .fileImporter(isPresented: $isImportingQR, allowedContentTypes: [.image], allowsMultipleSelection: false, onCompletion: importQR)
        .confirmationDialog("Delete authenticator code?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDeletion { delete(entry) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletion?.label ?? "")
        }
    }

    private func reload() {
        do { entries = try vault.read() }
        catch { message = error.localizedDescription }
    }

    private func addEntry() {
        let value = secretOrURI.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var entry: NativeAuthenticatorEntry
            if value.lowercased().hasPrefix("otpauth://") {
                entry = try NativeAuthenticator.parse(value)
                if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { entry.label = label.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else {
                entry = NativeAuthenticatorEntry(label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Authenticator code" : label,
                                                 secret: value)
                try NativeAuthenticator.validate(entry)
            }
            let isUpdate = entries.contains { $0.secret == entry.secret }
            let next = NativeAuthenticator.upsert(entry, into: entries)
            try vault.save(next)
            entries = next
            label = ""
            secretOrURI = ""
            message = "\(isUpdate ? "Updated" : "Added") \(entry.label)."
        } catch { message = error.localizedDescription }
    }

    private func delete(_ entry: NativeAuthenticatorEntry) {
        do {
            let next = entries.filter { $0.id != entry.id }
            try vault.save(next)
            entries = next
            message = "Deleted \(entry.label)."
        } catch { message = error.localizedDescription }
    }

    private func copy(_ entry: NativeAuthenticatorEntry) {
        do {
            let code = try NativeAuthenticator.code(for: entry)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            message = "Copied a code for \(entry.label)."
        } catch { message = error.localizedDescription }
    }

    private func importQR(_ result: Result<[URL], Error>) {
        do {
            let url = try result.get().first.unwrap(or: NativeAuthenticatorError.imageHasNoQRCode)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NativeAuthenticatorError.imageHasNoQRCode
            }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image).perform([request])
            guard let payload = request.results?.compactMap(\.payloadStringValue).first(where: { $0.lowercased().hasPrefix("otpauth://totp/") }) else {
                throw NativeAuthenticatorError.imageHasNoQRCode
            }
            secretOrURI = payload
            addEntry()
        } catch { message = error.localizedDescription }
    }
}

private struct AuthenticatorCodeRow: View {
    let entry: NativeAuthenticatorEntry
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.label).font(.headline)
                    if let account = entry.account, !account.isEmpty { Text(account).font(.caption).foregroundStyle(.secondary) }
                    if let code = try? NativeAuthenticator.code(for: entry, at: context.date) {
                        Text(code).font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    } else {
                        Text("Invalid secret").foregroundStyle(.red)
                    }
                    Text("Refreshes in \(NativeAuthenticator.remainingSeconds(for: entry, at: context.date))s")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Copy", action: onCopy)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Delete code")
            }
            .padding(14)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private extension Optional {
    func unwrap(or error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
