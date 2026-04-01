//
//  WalletCreationUITests.swift
//  railcartUITests
//
//  UI test verifying the full wallet creation flow completes
//  and the setup modal is dismissed.
//

import XCTest

final class WalletCreationUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testWalletCreationFlow() throws {
        // Step 1: Wait for backend to start and the create wallet view to appear.
        // The Node.js process takes a few seconds to initialize.
        let createTitle = app.staticTexts["Create Wallet"]
        XCTAssertTrue(
            createTitle.waitForExistence(timeout: 20),
            "Create Wallet title should appear after backend starts"
        )

        let passwordField = app.secureTextFields["walletSetup.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "Password field should exist")

        // Step 2: Enter password in both fields.
        passwordField.click()
        passwordField.typeText("TestPassword123!")

        let confirmField = app.secureTextFields["walletSetup.confirmPassword"]
        XCTAssertTrue(confirmField.exists, "Confirm password field should exist")
        confirmField.click()
        confirmField.typeText("TestPassword123!")

        // Step 3: Click "Create Wallet".
        let createButton = app.buttons["walletSetup.createButton"]
        XCTAssertTrue(createButton.isEnabled, "Create Wallet button should be enabled")
        createButton.click()

        // Step 4: Wait for mnemonic generation and backup view.
        let savedButton = app.buttons["walletSetup.savedMnemonicButton"]
        XCTAssertTrue(
            savedButton.waitForExistence(timeout: 15),
            "Mnemonic backup view should appear after mnemonic generation"
        )

        // Step 5: Acknowledge the mnemonic and trigger wallet creation.
        // This calls deriveEncryptionKey (PBKDF2) + createWallet (RAILGUN SDK).
        savedButton.click()

        // Step 6: Wait for wallet creation to complete and modal to dismiss.
        // The sidebar becomes visible once the modal is gone.
        let walletLabel = app.staticTexts["Wallet 1"]
        XCTAssertTrue(
            walletLabel.waitForExistence(timeout: 30),
            "Created wallet should appear in sidebar after creation completes"
        )
    }
}
