import XCTest

final class AccessibilityUITests: XCTestCase {
  private let scenarios = [
    "empty-chat",
    "answered-chat",
    "processing-queue",
    "error",
    "recovery",
    "browser",
    "settings",
    "result-preview",
    "result-explorer",
    "result-chart-recovery",
    "transient-banners",
  ]

  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDownWithError() throws {
    XCUIDevice.shared.orientation = .portrait
  }

  func testCanonicalScreensSupportUnpinnedDynamicType() throws {
    for scenario in scenarios {
      let app = launch(scenario: scenario)
      try app.performAccessibilityAudit(for: .dynamicType)
      app.terminate()
    }
  }

  func testCanonicalScreensDoNotClipTextOrShrinkHitRegions() throws {
    for size in ["large", "ax1", "ax3", "ax5"] {
      for scenario in scenarios {
        let app = launch(scenario: scenario, dynamicType: size)
        try app.performAccessibilityAudit(for: [.hitRegion, .textClipped])
        app.terminate()
      }
    }
  }

  func testKnownIconControlsAreAtLeast44Points() {
    for size in ["large", "ax5"] {
      let answered = launch(scenario: "answered-chat", dynamicType: size)
      assertAccessibleControl("Conversations", in: answered)
      assertAccessibleControl("New chat", in: answered)
      assertAccessibleControl("More", in: answered)
      assertAccessibleControl("Copy answer as Markdown", in: answered)
      assertAccessibleControl("Share answer", in: answered)
      assertAccessibleControl("Read narration aloud", in: answered)
      assertAccessibleControl("Helpful", in: answered)
      assertAccessibleControl("Not right", in: answered)
      answered.terminate()

      let processing = launch(scenario: "processing-queue", dynamicType: size)
      assertAccessibleControl("Stop answering", in: processing)
      assertAccessibleControl("Cancel queued question", in: processing)
      processing.terminate()

      let error = launch(scenario: "error", dynamicType: size)
      assertAccessibleControl("Dismiss error", in: error)
      error.terminate()

      let recovery = launch(scenario: "recovery", dynamicType: size)
      assertAccessibleControl("Dismiss interrupted question", in: recovery)
      assertAccessibleControl("Dismiss correction", in: recovery)
      recovery.terminate()
    }
  }

  func testChartRecoveryControlsOwnFullLeadingTouchTargets() {
    for size in ["large", "ax5"] {
      let app = launch(scenario: "result-chart-recovery", dynamicType: size)
      assertAccessibleControl("Keep Table", in: app)
      assertAccessibleControl("Retry Chart", in: app)

      XCTAssertTrue(app.staticTexts["No recovery action"].waitForExistence(timeout: 5))
      app.descendants(matching: .any)["Keep Table"]
        .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        .tap()
      XCTAssertTrue(app.staticTexts["Keep Table selected"].waitForExistence(timeout: 5))
      app.descendants(matching: .any)["Retry Chart"]
        .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        .tap()
      XCTAssertTrue(app.staticTexts["Retry Chart selected"].waitForExistence(timeout: 5))

      if size == "ax5" {
        let status = app.staticTexts["Chart unavailable"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertLessThan(
          status.frame.midX,
          app.frame.midX,
          "The accessibility stack should remain aligned to the leading edge")
      }
      app.terminate()
    }
  }

  func testHighestRiskScreensAtAX5Landscape() throws {
    XCUIDevice.shared.orientation = .landscapeLeft

    for scenario in ["answered-chat", "browser", "result-preview"] {
      let app = launch(scenario: scenario, dynamicType: "ax5")
      try app.performAccessibilityAudit(for: [.dynamicType, .hitRegion, .textClipped])
      app.terminate()
    }
  }

  func testChartExplorerExposesStableControlsAndTableFallback() {
    let app = launch(scenario: "result-explorer")
    XCTAssertTrue(
      app.descendants(matching: .any)["result-view-mode"]
        .waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["result-chart-explorer"]
        .waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["auto-chart-bar"]
        .waitForExistence(timeout: 5),
      "portfolioValueByFundV1 is expected to use the bar family")
    XCTAssertFalse(
      app.descendants(matching: .any)["auto-chart-preparing-bar"].exists,
      "The rendered-chart signal must not be satisfied by its loading placeholder")
    XCTAssertTrue(
      app.descendants(matching: .any)["result-chart-type"]
        .waitForExistence(timeout: 5))

    let table = app.segmentedControls.buttons["Table"]
    XCTAssertTrue(table.waitForExistence(timeout: 5))
    table.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["result-table-explorer"]
        .waitForExistence(timeout: 5))
    app.terminate()
  }

  @discardableResult
  private func launch(
    scenario: String,
    dynamicType: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["CREG_UI_TEST_SCENARIO"] = scenario
    if let dynamicType {
      app.launchEnvironment["CREG_UI_TEST_DYNAMIC_TYPE"] = dynamicType
    }
    app.launch()

    let fixture = app.descendants(matching: .any)["ui-test-\(scenario)"]
    XCTAssertTrue(
      fixture.waitForExistence(timeout: 10),
      "The DEBUG fixture for \(scenario) did not launch")
    return app
  }

  private func assertAccessibleControl(
    _ label: String,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let control = app.descendants(matching: .any)[label]
    XCTAssertTrue(
      control.waitForExistence(timeout: 5),
      "Missing control named \(label)",
      file: file,
      line: line)
    XCTAssertTrue(control.isHittable, "\(label) is not hittable", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      control.frame.width, 44, "\(label) is narrower than 44 points", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      control.frame.height, 44, "\(label) is shorter than 44 points", file: file, line: line)
  }
}
