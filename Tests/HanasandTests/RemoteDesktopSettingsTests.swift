import Foundation
import XCTest
@testable import Hanasand

final class RemoteDesktopSettingsTests: XCTestCase {
    func testLegacySettingsMigrateSharedHostToVNCWithoutLosingRDPValue() throws {
        let data = Data(#"{"rdpHost":"mac-mini.local:5900","rdpUser":"macmini","remoteDesktopProtocol":"screenSharing"}"#.utf8)

        let settings = try JSONDecoder().decode(HanasandDesktopSettings.self, from: data)

        XCTAssertEqual(settings.rdpHost, "mac-mini.local:5900")
        XCTAssertEqual(settings.vncHost, "mac-mini.local:5900")
        XCTAssertEqual(RemoteDesktopProtocol.screenSharing.connectionHost(in: settings), "mac-mini.local:5900")
        XCTAssertEqual(RemoteDesktopProtocol.microsoftRDP.connectionHost(in: settings), "mac-mini.local:5900")
    }

    func testNewSettingsPersistDistinctRDPAndVNCHosts() throws {
        let data = Data(#"{"rdpHost":"windows.local:3389","vncHost":"mac-mini.local:5900","rdpUser":"eirik"}"#.utf8)

        let decoded = try JSONDecoder().decode(HanasandDesktopSettings.self, from: data)
        let roundTripped = try JSONDecoder().decode(HanasandDesktopSettings.self, from: JSONEncoder().encode(decoded))

        XCTAssertEqual(roundTripped.rdpHost, "windows.local:3389")
        XCTAssertEqual(roundTripped.vncHost, "mac-mini.local:5900")
    }

    func testEachProtocolBuildsConnectionURLFromItsOwnHost() throws {
        var settings = HanasandDesktopSettings()
        settings.rdpHost = "windows.local:3389"
        settings.vncHost = "mac-mini.local:5900"
        settings.rdpUser = "eirik"

        XCTAssertEqual(
            RemoteDesktopProtocol.screenSharing.connectionURL(in: settings)?.absoluteString,
            "vnc://eirik@mac-mini.local:5900"
        )
        XCTAssertEqual(
            RemoteDesktopProtocol.microsoftRDP.connectionURL(in: settings)?.absoluteString,
            "rdp://full%20address=s:eirik@windows.local:3389"
        )
    }

    func testVNCFallsBackToRDPHostWhenItsDedicatedHostIsBlank() {
        var settings = HanasandDesktopSettings()
        settings.rdpHost = "shared-host.local:5900"
        settings.vncHost = "  \n"

        XCTAssertEqual(RemoteDesktopProtocol.screenSharing.connectionHost(in: settings), "shared-host.local:5900")
        XCTAssertEqual(
            RemoteDesktopProtocol.screenSharing.connectionURL(in: settings)?.absoluteString,
            "vnc://macmini@shared-host.local:5900"
        )
    }

    func testMissingHostUsesProtocolSpecificFieldAndReturnsNoConnectionURL() {
        var settings = HanasandDesktopSettings()
        settings.rdpHost = "  "
        settings.vncHost = "  \n"

        XCTAssertNil(RemoteDesktopProtocol.screenSharing.connectionURL(in: settings))
        XCTAssertNil(RemoteDesktopProtocol.microsoftRDP.connectionURL(in: settings))
        XCTAssertEqual(RemoteDesktopProtocol.screenSharing.hostLabel, "VNC host")
        XCTAssertEqual(RemoteDesktopProtocol.microsoftRDP.hostLabel, "RDP host")
    }
}
