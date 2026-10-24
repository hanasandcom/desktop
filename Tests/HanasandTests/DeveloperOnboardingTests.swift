import XCTest
@testable import Hanasand

final class DeveloperOnboardingTests: XCTestCase {
    func testTypedClientUsesPublishedContractAndEnvironmentStoredKey() {
        XCTAssertEqual(
            NativeDeveloperOnboardingContent.typeGenerationCommand,
            "npx openapi-typescript https://hanasand.com/api/openapi/ti -o src/hanasand-api.d.ts"
        )
        XCTAssertEqual(NativeDeveloperOnboardingContent.clientInstallCommand, "npm install openapi-fetch")
        XCTAssertTrue(NativeDeveloperOnboardingContent.typedClientExample.contains("https://api.hanasand.com/api/v1"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.typedClientExample.contains("process.env.HANASAND_API_KEY"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.typedClientExample.contains("api.GET('/actors'"))
        XCTAssertFalse(NativeDeveloperOnboardingContent.typedClientExample.contains("YOUR_API_KEY"))
    }

    func testPaginationGuidanceDocumentsBoundsAndEndCondition() {
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("page=1"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("up to 100"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("defaults to 50"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("pagination.totalPages"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("pagination.nextPage"))
        XCTAssertTrue(NativeDeveloperOnboardingContent.paginationGuidance.contains("until it is null"))
    }
}
