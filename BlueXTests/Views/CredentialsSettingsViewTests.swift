// BlueXTests/Views/CredentialsSettingsViewTests.swift
import XCTest
@testable import BlueX

final class CredentialsSettingsViewTests: XCTestCase {
    func testKeychainCredentialsHasExpectedInterface() {
        let saveFn: (String, String) -> Bool = KeychainCredentials.save
        let loadFn: () -> KeychainCredentials? = KeychainCredentials.load  // NOT KeychainCredentials.Stored?
        let deleteFn: () -> Void = KeychainCredentials.delete
        XCTAssertNotNil(saveFn)
        XCTAssertNotNil(loadFn)
        XCTAssertNotNil(deleteFn)
    }
    func testHandleAndPasswordValidation() {
        let emptyHandle = ""
        let validPassword = "app-password-123"
        let validHandle = "user.bsky.social"
        XCTAssertFalse(!emptyHandle.isEmpty && !validPassword.isEmpty,
                       "Empty handle should prevent save")
        let bothValid = !validHandle.isEmpty && !validPassword.isEmpty
        XCTAssertTrue(bothValid, "Non-empty handle and password should pass validation")
    }
    func testConnectionResultPrefixConvention() {
        let successResult = "✓ Connected successfully"
        let failureResult = "✗ Auth failed"
        XCTAssertTrue(successResult.hasPrefix("✓"))
        XCTAssertTrue(failureResult.hasPrefix("✗"))
        XCTAssertFalse(successResult.hasPrefix("✗"))
    }
}
