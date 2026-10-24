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

enum RemoteDesktopProtocol: String, CaseIterable, Identifiable {
    case screenSharing
    case microsoftRDP

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screenSharing: return "Screen Sharing"
        case .microsoftRDP: return "Microsoft RDP"
        }
    }

    var icon: String {
        switch self {
        case .screenSharing: return "display"
        case .microsoftRDP: return "rectangle.connected.to.line.below"
        }
    }

    var hostLabel: String {
        switch self {
        case .screenSharing: return "VNC host"
        case .microsoftRDP: return "RDP host"
        }
    }

    func connectionHost(in settings: HanasandDesktopSettings) -> String {
        switch self {
        case .screenSharing:
            let vncHost = settings.vncHost.trimmingCharacters(in: .whitespacesAndNewlines)
            return vncHost.isEmpty ? settings.rdpHost : settings.vncHost
        case .microsoftRDP: return settings.rdpHost
        }
    }

    func connectionTarget(in settings: HanasandDesktopSettings) -> String? {
        let host = connectionHost(in: settings).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let user = settings.rdpUser.trimmingCharacters(in: .whitespacesAndNewlines)
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    func connectionURL(in settings: HanasandDesktopSettings) -> URL? {
        guard let target = connectionTarget(in: settings) else { return nil }
        let urlString: String
        switch self {
        case .screenSharing:
            let allowed = CharacterSet.urlUserAllowed
                .union(.urlHostAllowed)
                .union(CharacterSet(charactersIn: ":@[]"))
            let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
            urlString = "vnc://\(encodedTarget)"
        case .microsoftRDP:
            let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: ":@"))
            let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
            urlString = "rdp://full%20address=s:\(encodedTarget)"
        }
        return URL(string: urlString)
    }
}
