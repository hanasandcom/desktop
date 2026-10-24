import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct DashboardBackupFile: Decodable, Identifiable {
    var id: String { "\(service)-\(file)-\(location ?? "unknown")" }
    let service: String
    let file: String
    let mtime: String?
    let size: String?
    let location: String?
}

func filterNativeBackupFiles(_ files: [NativeBackupFile], service: String, date: String, search: String) -> [NativeBackupFile] {
    files.filter { file in
        (service.isEmpty || file.service == service) &&
        (date.isEmpty || file.mtime?.hasPrefix(date) == true || file.file.localizedCaseInsensitiveContains(date)) &&
        (search.isEmpty || file.file.localizedCaseInsensitiveContains(search))
    }
}

func selectedNativeBackupFile(_ files: [NativeBackupFile], id: String, service: String, date: String, search: String) -> NativeBackupFile? {
    filterNativeBackupFiles(files, service: service, date: date, search: search).first { $0.id == id }
}
