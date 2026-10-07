import XCTest

final class AccessibilityUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
  }

  override func tearDownWithError() throws {
    XCUIDevice.shared.orientation = .portrait
  }

  func testCanonicalScreensSupportUnpinnedDynamicType() throws {
    for scenario in canonicalScenarios() {
      let app = launch(scenario: scenario)
      try app.performAccessibilityAudit(for: .dynamicType)
      app.terminate()
    }
  }

  func testCanonicalScreensDoNotClipTextOrShrinkHitRegions() throws {
    let scenarios = canonicalScenarios()
    for size in ["large", "ax1", "ax3", "ax5"] {
      for scenario in scenarios {
        let app = launch(scenario: scenario, dynamicType: size)
        try app.performAccessibilityAudit(for: [.hitRegion, .textClipped])
        app.terminate()
      }
    }
  }

  func testAnswerActionsAreAtLeast44Points() throws {
    for size in ["large", "xxlarge", "xxxlarge", "ax4", "ax5"] {
      let answered = launch(scenario: "answered-chat", dynamicType: size)
      assertAccessibleControl("Conversations", in: answered)
      assertAccessibleControl("New chat", in: answered)
      assertAccessibleControl(
        answered.descendants(matching: .any)
          .matching(NSPredicate(format: "label CONTAINS 'conversation actions'"))
          .firstMatch,
        label: "Conversation actions")
      for label in ["Copy answer as Markdown", "Listen", "Not right", "More answer actions"] {
        assertAccessibleControl(scrollToControl(label, in: answered), label: label)
      }
      try answered.performAccessibilityAudit(for: .textClipped)
      tapMoreClearOfChatHeader(in: answered)
      assertAccessibleControl("Share answer", in: answered)
      assertAccessibleControl("Helpful", in: answered)
      answered.terminate()
    }
  }

  func testKnownIconControlsAreAtLeast44Points() {
    for size in ["large", "ax5"] {
      let processing = launch(scenario: "processing-queue", dynamicType: size)
      for label in ["Stop answering", "Cancel queued question"] {
        assertAccessibleControl(scrollToControl(label, in: processing), label: label)
      }
      processing.terminate()
      let error = launch(scenario: "error", dynamicType: size)
      assertAccessibleControl("Dismiss error", in: error)
      error.terminate()
      let recovery = launch(scenario: "recovery", dynamicType: size)
      for label in ["Dismiss interrupted question", "Dismiss correction"] {
        assertAccessibleControl(scrollToControl(label, in: recovery), label: label)
      }
      recovery.terminate()
    }
  }

  func testSharingReturnsToAnswerWithMoreClosed() {
    let app = launch(scenario: "answered-chat", dynamicType: "large")
    tapMoreClearOfChatHeader(in: app)
    let share = app.buttons["Share answer"]
    XCTAssertTrue(share.waitForExistence(timeout: 5))
    share.tap()
    let copy = app.cells["Copy"].firstMatch
    XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
    copy.tap()
    XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Helpful"].exists, "More should close after sharing completes")
    tapMoreClearOfChatHeader(in: app)
    XCTAssertTrue(app.buttons["Helpful"].waitForExistence(timeout: 5))
  }

  func testMoreClosesWhenAnswerActionLayoutChanges() {
    for size in ["large", "xxxlarge", "ax5"] {
      XCUIDevice.shared.orientation = .portrait
      let app = launch(scenario: "answered-chat", dynamicType: size)
      tapMoreClearOfChatHeader(in: app)
      let helpful = app.buttons["Helpful"]
      XCTAssertTrue(helpful.waitForExistence(timeout: 5))
      XCUIDevice.shared.orientation = .landscapeLeft
      XCTAssertTrue(
        helpful.waitForNonExistence(timeout: 5), "More should close when the row width changes")
      XCTAssertTrue(app.otherElements["PopoverDismissRegion"].waitForNonExistence(timeout: 5))
      tapMoreClearOfChatHeader(in: app)
      XCTAssertTrue(helpful.waitForExistence(timeout: 5), app.debugDescription)
      assertAccessibleControl(scrollToControl("Helpful", in: app), label: "Helpful")
      app.terminate()
    }
  }

  func testCancellingSharingReturnsToAnswerWithMoreClosed() {
    let app = launch(scenario: "answered-chat", dynamicType: "large")
    tapMoreClearOfChatHeader(in: app)
    app.buttons["Share answer"].tap()
    let activities = app.otherElements["ActivityListView"].firstMatch
    XCTAssertTrue(activities.waitForExistence(timeout: 5), app.debugDescription)
    closeActivitySheet(in: app)
    XCTAssertTrue(activities.waitForNonExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Helpful"].exists)
    tapMoreClearOfChatHeader(in: app)
    XCTAssertTrue(app.buttons["Helpful"].waitForExistence(timeout: 5))
  }

  func testSharingSurvivesConcurrentCompletionInLongTranscript() {
    let app = launch(scenario: "long-transcript-sharing", dynamicType: "large")
    let originalMoreID = "answer-more-00000000-0000-0000-0000-000000006099"
    tapMoreClearOfChatHeader(in: app, identifier: originalMoreID)
    app.buttons["Share answer"].tap()
    let activities = app.otherElements["ActivityListView"].firstMatch
    XCTAssertTrue(activities.waitForExistence(timeout: 5), app.debugDescription)
    // The fixture completes another turn when the stable share coordinator
    // presents. That completion scrolls the older owning row out of the stack.
    XCTAssertTrue(activities.isHittable, "Sharing must stay open across completion")
    closeActivitySheet(in: app)
    XCTAssertTrue(activities.waitForNonExistence(timeout: 5))
    let completed = app.staticTexts["Concurrent answer completed"]
    for _ in 0..<8 {
      if completed.exists && completed.isHittable { break }
      swipeScrollableContent(app.scrollViews.firstMatch, in: app, up: true)
    }
    XCTAssertTrue(completed.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertFalse(app.buttons[originalMoreID].isHittable,
      "Concurrent completion must move the original answer out of view")
    tapMoreClearOfChatHeader(in: app, identifier: originalMoreID)
    let helpful = app.buttons["Helpful"]
    XCTAssertTrue(helpful.waitForExistence(timeout: 5))
    XCTAssertFalse(activities.exists, "Returning to the old row must not reopen sharing")
    helpful.tap()
    XCTAssertTrue(helpful.waitForNonExistence(timeout: 5))
    XCTAssertFalse(activities.exists)
  }

  func testConversationLoadFailureOffersRecovery() throws {
    for size in ["large", "ax5"] {
      for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
        XCUIDevice.shared.orientation = orientation
        let app = launch(scenario: "conversation-load-failure", dynamicType: size)
        XCTAssertTrue(app.staticTexts["History unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["conversation-loading"].exists)
        let conversations = scrollToControl("Conversations", in: app,
          identifier: "conversation-recovery-browser")
        assertAccessibleControl(conversations, label: "Conversations")
        let newChat = scrollToControl("New chat", in: app,
          identifier: "conversation-recovery-new-chat")
        assertAccessibleControl(newChat, label: "New chat")
        try app.performAccessibilityAudit(for: [.hitRegion, .textClipped])
        scrollToControl("Conversations", in: app, identifier: "conversation-recovery-browser").tap()
        XCTAssertTrue(app.textFields["Search"].waitForExistence(timeout: 5))
        app.buttons["New Chat"].tap()
        XCTAssertTrue(app.staticTexts["Ask about your portfolio"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["History unavailable"].exists)
        app.terminate()

        let directRecovery = launch(scenario: "conversation-load-failure", dynamicType: size)
        let directNewChat = scrollToControl("New chat", in: directRecovery,
          identifier: "conversation-recovery-new-chat")
        XCTAssertTrue(directNewChat.waitForExistence(timeout: 5))
        directNewChat.tap()
        XCTAssertTrue(directRecovery.staticTexts["Ask about your portfolio"].waitForExistence(timeout: 5))
        XCTAssertFalse(directRecovery.staticTexts["History unavailable"].exists)
        directRecovery.terminate()
      }
    }
  }

  func testHistoryStoreRetryAtAX5PortraitAndLandscape() throws {
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      let app = launch(scenario: "history-store-unavailable", dynamicType: "ax5")
      XCTAssertTrue(app.staticTexts["History unavailable"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts[
        "CREG couldn’t open your conversation history. Tap Retry to try again."].exists)
      let newChat = app.buttons["conversation-recovery-new-chat"]
      XCTAssertFalse(newChat.isEnabled)
      assertAccessibleControl(scrollToControl("Retry history", in: app, identifier: "history-retry"),
        label: "Retry history")
      try auditRecovery(in: app)
      scrollToControl("Dismiss error", in: app).tap()
      XCTAssertTrue(app.staticTexts["conversation-recovery-idle"].waitForExistence(timeout: 5))
      XCTAssertFalse(app.descendants(matching: .any)["conversation-loading"].exists)
      XCTAssertFalse(newChat.isEnabled)
      if orientation == .landscapeLeft {
        scrollToControl("Conversations", in: app, identifier: "conversation-recovery-browser").tap()
        XCTAssertTrue(app.textFields["Search"].waitForExistence(timeout: 5))
        assertAccessibleControl(
          scrollToControl("Retry history", in: app, identifier: "browser-history-retry"),
          label: "Retry history")
        try auditRecovery(in: app)
      }
      scrollToControl("Retry history", in: app,
        identifier: orientation == .landscapeLeft ? "browser-history-retry" : "history-retry").tap()
      XCTAssertTrue(app.staticTexts["Ask about your portfolio"].waitForExistence(timeout: 5), app.debugDescription)
      XCTAssertFalse(app.staticTexts["History unavailable"].exists)
      app.terminate()
    }
  }

  func testRetryInspectionOffersDismissOnlyAtAX5PortraitAndLandscape() throws {
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      let app = launch(scenario: "retry-inspection", dynamicType: "ax5")
      XCTAssertTrue(app.staticTexts["Checking retry…"].waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons["Ask Again"].exists)
      XCTAssertFalse(app.buttons["Cancel queued retry"].exists)
      let dismiss = scrollToControl("Dismiss interrupted question", in: app)
      assertAccessibleControl(dismiss, label: "Dismiss interrupted question")
      try app.performAccessibilityAudit(for: [.hitRegion, .textClipped])
      dismiss.tap()
      XCTAssertTrue(app.staticTexts["Checking retry…"].waitForNonExistence(timeout: 5))
      XCTAssertFalse(app.staticTexts["Retry unavailable"].exists)
      app.terminate()
    }
  }

  private func auditRecovery(in app: XCUIApplication) throws {
    try app.performAccessibilityAudit(for: [.hitRegion, .textClipped]) { issue in
      print("Recovery accessibility issue: \(issue.detailedDescription)\n\(issue.element?.debugDescription ?? "No owning element")")
      return false
    }
  }

  func testSupportWarningAtAX5PortraitAndLandscape() throws {
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      let app = launch(scenario: "support-bundle-fallback", dynamicType: "ax5")
      let warning = app.staticTexts["support-bundle-warning"]
      XCTAssertTrue(warning.waitForExistence(timeout: 5))
      XCTAssertTrue(warning.label.contains("full history database snapshot"))
      assertAccessibleControl(
        scrollToControl("Share support bundle", in: app), label: "Share support bundle")
      assertAccessibleControl(scrollToControl("Done", in: app), label: "Done")
      try app.performAccessibilityAudit(for: [.hitRegion, .textClipped])
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "Support-warning-AX5-\(orientation.rawValue)"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      app.terminate()
    }
  }

  func testMoreActionsRemainAccessibleInConstrainedHeight() throws {
    for size in ["large", "ax5"] {
      for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
        XCUIDevice.shared.orientation = orientation
        let app = launch(scenario: "answered-chat-reading", dynamicType: size)
        tapMoreClearOfChatHeader(in: app)
        for label in ["Share answer", "Helpful", "Stop reading"] {
          let control = app.buttons[label]
          for _ in 0..<6 {
            if control.exists && control.isHittable { break }
            swipeScrollableContent(app.scrollViews["answer-more-scroll"], in: app, up: true)
          }
          assertAccessibleControl(control, label: label)
        }
        if size == "ax5" {
          XCTAssertGreaterThan(app.buttons["Share answer"].frame.height, 44)
        }
        XCTAssertTrue(app.buttons["Helpful"].isSelected)
        try app.performAccessibilityAudit(for: [.hitRegion, .textClipped])
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "More-\(size)-\(orientation.rawValue)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Stop reading"].tap()
        XCTAssertTrue(app.buttons["Helpful"].waitForNonExistence(timeout: 5))
        app.terminate()
      }
    }
  }

  func testAnswerActionAccessibilitySemantics() {
    for size in ["large", "ax5"] {
      let app = launch(scenario: "answered-chat-helpful", dynamicType: size)
      assertAccessibleControl(scrollToControl("Listen", in: app), label: "Listen")
      tapMoreClearOfChatHeader(in: app)
      let helpful = app.buttons["Helpful"]
      assertAccessibleControl(helpful, label: "Helpful")
      XCTAssertTrue(helpful.isSelected)
      app.terminate()
    }
  }

  func testSimpleChartValuesAreAccessible() {
    for size in ["large", "ax5"] {
      let app = launch(scenario: "answered-chat", dynamicType: size)
      let preview = scrollToControl("Result chart, 4 rows", in: app)
      let summary = preview.value as? String ?? ""
      XCTAssertTrue(summary.contains("Meridian Core Fund I, $412,500,000"))
      XCTAssertTrue(summary.contains("Meridian Value-Add II, $268,900,000"))
      XCTAssertTrue(summary.contains("Harborline Opportunistic, $154,300,000"))
      XCTAssertTrue(summary.contains("Coastal Core-Plus III, $98,750,000"))
      app.terminate()
    }
  }

  func testChartRecoveryControlsOwnFullLeadingTouchTargets() {
    for size in ["large", "ax5"] {
      let app = launch(scenario: "result-chart-recovery", dynamicType: size)
      assertAccessibleControl("Keep Table", in: app)
      assertAccessibleControl("Retry Chart", in: app)

      let chartType = app.descendants(matching: .any)["result-chart-type-retry"]
      XCTAssertTrue(chartType.waitForExistence(timeout: 5))
      chartType.tap()
      let selectedChartType = app.buttons["Bar"]
      XCTAssertTrue(selectedChartType.waitForExistence(timeout: 5))
      XCTAssertTrue(selectedChartType.isSelected)
      XCTAssertFalse(app.buttons["Ranked dot"].isSelected)
      selectedChartType.tap()
      XCTAssertTrue(app.staticTexts["Bar selected again"].waitForExistence(timeout: 5))
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

  func testTerminalChartRecoveryOwnsOneFullLeadingTouchTarget() {
    for size in ["large", "ax5"] {
      let app = launch(
        scenario: "result-chart-terminal-recovery",
        dynamicType: size)
      assertAccessibleControl("Keep Table", in: app)
      XCTAssertFalse(app.descendants(matching: .any)["Retry Chart"].exists)

      let chartType = app.descendants(matching: .any)["result-chart-type-retry"]
      XCTAssertTrue(chartType.waitForExistence(timeout: 5))
      chartType.tap()
      let alternativeChartType = app.buttons["Ranked dot"]
      XCTAssertTrue(alternativeChartType.waitForExistence(timeout: 5))
      XCTAssertFalse(alternativeChartType.isSelected)
      alternativeChartType.tap()
      XCTAssertTrue(
        app.staticTexts["Ranked dot selected"].waitForExistence(timeout: 5))

      app.descendants(matching: .any)["Keep Table"]
        .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        .tap()
      XCTAssertTrue(app.staticTexts["Keep Table selected"].waitForExistence(timeout: 5))
      app.descendants(matching: .any)["Keep Table"]
        .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        .tap()
      XCTAssertTrue(
        app.staticTexts["Keep Table selected again"].waitForExistence(timeout: 5))

      if size == "ax5" {
        let status = app.staticTexts["Chart unavailable"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertLessThan(
          status.frame.midX,
          app.frame.midX,
          "The terminal accessibility stack should remain leading-aligned")
      }
      app.terminate()
    }
  }

  func testRejectedChartRetryPreservesTheOriginalSelection() {
    let app = launch(scenario: "result-chart-rejected-retry")
    let chartType = app.descendants(matching: .any)["result-chart-type-retry"]
    XCTAssertTrue(chartType.waitForExistence(timeout: 5))
    chartType.tap()

    let original = app.buttons["Bar"]
    let alternative = app.buttons["Ranked dot"]
    XCTAssertTrue(original.waitForExistence(timeout: 5))
    XCTAssertTrue(original.isSelected)
    XCTAssertFalse(alternative.isSelected)
    alternative.tap()
    XCTAssertTrue(
      app.staticTexts["Chart retry unavailable"].waitForExistence(timeout: 5))

    chartType.tap()
    XCTAssertTrue(original.waitForExistence(timeout: 5))
    XCTAssertTrue(original.isSelected)
    XCTAssertFalse(app.buttons["Ranked dot"].isSelected)
    app.terminate()
  }

  func testUnresolvedChartTypeDoesNotMarkTheFirstOptionSelected() {
    let app = launch(scenario: "result-chart-unresolved-selection")
    let chartType = app.descendants(matching: .any)["result-chart-type-retry"]
    XCTAssertTrue(chartType.waitForExistence(timeout: 5))
    chartType.tap()

    let firstChartType = app.buttons["Bar"]
    let secondChartType = app.buttons["Ranked dot"]
    XCTAssertTrue(firstChartType.waitForExistence(timeout: 5))
    XCTAssertFalse(firstChartType.isSelected)
    XCTAssertFalse(secondChartType.isSelected)
    firstChartType.tap()

    XCTAssertTrue(app.staticTexts["Bar selected"].waitForExistence(timeout: 5))
    app.terminate()
  }

  func testHighestRiskScreensAtAX5Landscape() throws {
    XCUIDevice.shared.orientation = .landscapeLeft

    for scenario in ["answered-chat", "browser"] {
      let app = launch(scenario: scenario, dynamicType: "ax5")
      // `.dynamicType` asks XCTest to vary an otherwise unpinned font size;
      // this contract deliberately fixes AX5 and audits that exact layout.
      try app.performAccessibilityAudit(for: [.hitRegion, .textClipped])
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
      app.descendants(matching: .any)["result-chart-preparing-bar"].exists,
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

    let chart = app.segmentedControls.buttons["Chart"]
    XCTAssertTrue(chart.waitForExistence(timeout: 5))
    chart.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["result-chart-explorer"]
        .waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["auto-chart-bar"]
        .waitForExistence(timeout: 5))
    app.terminate()
  }

  func testPreviewShowsNewTableWhenChartInputIdentityChanges() {
    let app = launch(scenario: "result-preview-identity")
    let originalChart = app.buttons["auto-chart-bar"]
    XCTAssertTrue(originalChart.waitForExistence(timeout: 10))

    app.buttons["Replace result"].tap()
    let replacementTable = app.buttons["3 rows, Explore result"]
    XCTAssertTrue(replacementTable.waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["auto-chart-bar"].exists)
    app.terminate()
  }

  func testChartPreparationHasDistinctIdentityInProductionPresentation() {
    let app = launch(
      scenario: "result-chart-preparation",
      dynamicType: "large")
    let preparation =
      app.descendants(matching: .any)["result-chart-preparing-bar"]
    XCTAssertTrue(preparation.waitForExistence(timeout: 5))
    XCTAssertFalse(app.descendants(matching: .any)["auto-chart-bar"].exists)

    let explorer = app.descendants(matching: .any)["result-chart-explorer"]
    let plot = app.descendants(matching: .any)["result-chart-preparing-plot"]
    let rationale =
      app.descendants(matching: .any)["result-chart-explorer-rationale"]
    XCTAssertTrue(explorer.waitForExistence(timeout: 5))
    XCTAssertTrue(plot.waitForExistence(timeout: 5))
    XCTAssertEqual(
      plot.frame.height,
      360,
      accuracy: 1)
    XCTAssertTrue(rationale.waitForExistence(timeout: 5))

    let title = app.staticTexts["Portfolio value by fund"]
    let rationaleText =
      app.staticTexts["Bars compare portfolio value across funds."]
    let diagnostic =
      app.staticTexts["Long fund names may be shortened on the category axis."]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    XCTAssertTrue(rationaleText.waitForExistence(timeout: 5))
    XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
    app.terminate()
  }

  func testMalformedConfigurationRendersInvalidConfigurationScreen() {
    let app = XCUIApplication()
    app.launchEnvironment["CREG_UI_TEST_SCENARIO"] = "settings"
    app.launchEnvironment["CREG_UI_TEST_DYNAMIC_TYPE"] = "enormous"
    app.launchEnvironment["CREG_UI_TEST_SCENARIO_MANIFEST"] = "1"
    app.launch()

    let invalid = app.staticTexts["ui-test-invalid-configuration"]
    XCTAssertTrue(invalid.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["ui-test-scenario-manifest"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["ui-test-settings"].exists)
    app.terminate()
  }

  @discardableResult
  private func launch(
    scenario: String,
    dynamicType: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["CREG_UI_TEST_SCENARIO"] = scenario
    app.launchEnvironment["CREG_UI_TEST_SCENARIO_MANIFEST"] = "0"
    if let dynamicType {
      app.launchEnvironment["CREG_UI_TEST_DYNAMIC_TYPE"] = dynamicType
    } else {
      app.launchEnvironment["CREG_UI_TEST_DYNAMIC_TYPE"] = ""
    }
    app.launch()

    let fixture = app.descendants(matching: .any)["ui-test-\(scenario)"]
    XCTAssertTrue(
      fixture.waitForExistence(timeout: 10),
      "The DEBUG fixture for \(scenario) did not launch")
    return app
  }

  private func canonicalScenarios(
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> [String] {
    let app = XCUIApplication()
    app.launchEnvironment["CREG_UI_TEST_SCENARIO"] = ""
    app.launchEnvironment["CREG_UI_TEST_DYNAMIC_TYPE"] = ""
    app.launchEnvironment["CREG_UI_TEST_SCENARIO_MANIFEST"] = "1"
    app.launch()
    defer { app.terminate() }

    let manifest = app.staticTexts["ui-test-scenario-manifest"]
    XCTAssertTrue(
      manifest.waitForExistence(timeout: 10),
      "The app's accessibility scenario manifest did not launch",
      file: file,
      line: line)
    let scenarios = manifest.label.split(separator: "|").map(String.init)
    XCTAssertFalse(
      scenarios.isEmpty,
      "The app's accessibility scenario manifest must not be empty",
      file: file,
      line: line)
    return scenarios
  }

  private func assertAccessibleControl(
    _ label: String,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let control = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", label))
      .firstMatch
    assertAccessibleControl(control, label: label, file: file, line: line)
  }

  private func closeActivitySheet(in app: XCUIApplication) {
    let close = app.buttons["header.closeButton"].firstMatch
    XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
    let hittable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: close)
    XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed, app.debugDescription)
    close.tap()
  }

  private func scrollToControl(
    _ label: String, in app: XCUIApplication, identifier: String? = nil
  ) -> XCUIElement {
    let control = identifier.map { app.buttons[$0] } ?? app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    let moreScroll = app.scrollViews["answer-more-scroll"]
    let recoveryScroll = app.scrollViews["conversation-recovery-scroll"]
    let browserHistoryScroll = app.scrollViews["browser-history-scroll"]
    let scroll: XCUIElement
    if identifier == "browser-history-retry", browserHistoryScroll.exists {
      scroll = browserHistoryScroll
    } else if recoveryScroll.exists {
      scroll = recoveryScroll
    } else {
      scroll = moreScroll.exists ? moreScroll
        : (app.scrollViews.allElementsBoundByIndex.first { $0.isHittable } ?? app.scrollViews.firstMatch)
    }
    for _ in 0..<6 {
      if control.exists && control.isHittable {
        if settleVisibleControl(control, scroll: scroll, app: app) { return control }
        continue
      }
      swipeScrollableContent(scroll, in: app, up: true)
    }
    for _ in 0..<6 {
      if control.exists && control.isHittable {
        if settleVisibleControl(control, scroll: scroll, app: app) { return control }
        continue
      }
      swipeScrollableContent(scroll, in: app, up: false)
    }
    XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing control named \(label)")
    return control
  }

  private func settleVisibleControl(
    _ control: XCUIElement, scroll: XCUIElement, app: XCUIApplication
  ) -> Bool {
    if scroll.identifier == "ui-test-support-bundle-fallback" { return true }
    // XCTest calls partially clipped buttons hittable, but their synthesized
    // center tap can land in the system's top or bottom gesture region.
    let viewport = app.frame.insetBy(dx: 0, dy: 64)
    let frame = control.frame
    let delta: CGFloat
    if ["conversation-recovery-scroll", "browser-history-scroll"].contains(scroll.identifier) {
      delta = frame.midY < viewport.minY ? max(24, viewport.minY - frame.midY + 12)
        : (frame.midY > viewport.maxY ? min(-24, viewport.maxY - frame.midY - 12) : 0)
    } else {
      delta = frame.minY < viewport.minY ? viewport.minY - frame.minY
        : (frame.maxY > viewport.maxY ? viewport.maxY - frame.maxY : 0)
    }
    guard delta != 0, frame.height <= viewport.height else { return true }
    let visibleScroll = scroll.frame.intersection(app.frame)
    guard !visibleScroll.isEmpty else { return true }
    let start = app.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: visibleScroll.midX, dy: visibleScroll.midY))
    start.press(forDuration: 0.1,
      thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)),
      withVelocity: .slow, thenHoldForDuration: 0.2)
    return false
  }

  private func swipeScrollableContent(
    _ scroll: XCUIElement, in app: XCUIApplication, up: Bool
  ) {
    let frame = scroll.frame
    if ["answer-more-scroll", "conversation-recovery-scroll", "browser-history-scroll",
      "ui-test-support-bundle-fallback"].contains(scroll.identifier) {
      // SwiftUI can report a zero-sized ancestor for a visible popover.
      // XCTest's automatic swipe then rejects its visible scroll view.
      let visible = frame.intersection(app.frame)
      XCTAssertFalse(visible.isEmpty, "More scrolling content is offscreen: \(scroll.debugDescription)")
      guard !visible.isEmpty else { return }
      let origin = app.coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(CGVector(
        dx: visible.midX - app.frame.minX,
        dy: visible.minY + visible.height * (up ? 0.8 : 0.2) - app.frame.minY))
      let end = origin.withOffset(CGVector(
        dx: visible.midX - app.frame.minX,
        dy: visible.minY + visible.height * (up ? 0.2 : 0.8) - app.frame.minY))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
      return
    }
    if frame.height >= frame.width {
      if up { scroll.swipeUp() } else { scroll.swipeDown() }
      return
    }
    let header = app.buttons.matching(
      NSPredicate(format: "label CONTAINS 'conversation actions'")).firstMatch
    let composer = app.textFields.firstMatch
    let top = max(frame.minY + 16, header.exists ? header.frame.maxY + 16 : frame.minY + 16)
    let bottom = min(frame.maxY - 16, composer.exists ? composer.frame.minY - 16 : frame.maxY - 16)
    // Landscape scroll views extend under the chrome. Keep the stroke in
    // visible content and clear of the centered Jump to latest control.
    let start = scroll.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: frame.width * 0.7, dy: (up ? bottom : top) - frame.minY))
    let end = scroll.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: frame.width * 0.7, dy: (up ? top : bottom) - frame.minY))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
  }

  private func tapMoreClearOfChatHeader(in app: XCUIApplication, identifier: String? = nil) {
    let more = scrollToControl("More answer actions", in: app, identifier: identifier)
    let header = app.buttons.matching(
      NSPredicate(format: "label CONTAINS 'conversation actions'")).firstMatch
    for _ in 0..<6 {
      // XCTest may call an underlying SwiftUI control hittable even when
      // the translucent header receives the tap at its center.
      if !header.exists || more.frame.midY > header.frame.maxY + 8 { break }
      let top = header.frame.maxY
      let bottom = app.textFields.firstMatch.exists
        ? app.textFields.firstMatch.frame.minY : app.frame.maxY - 120
      let start = app.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: app.frame.midX, dy: (top + bottom) / 2))
      start.press(
        forDuration: 0.1,
        thenDragTo: start.withOffset(CGVector(dx: 0, dy: min(30, (bottom - top) * 0.4))),
        withVelocity: .slow,
        thenHoldForDuration: 0.3)
    }
    XCTAssertTrue(more.isHittable, app.debugDescription)
    XCTAssertGreaterThan(more.frame.midY, header.frame.maxY)
    more.tap()
  }

  private func assertAccessibleControl(
    _ control: XCUIElement,
    label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(
      control.waitForExistence(timeout: 5),
      "Missing control named \(label)",
      file: file,
      line: line)
    XCTAssertTrue(
      control.isHittable, "\(label) is not hittable: \(control.debugDescription)",
      file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      control.frame.width, 44 - 0.001, "\(label) is narrower than 44 points", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      control.frame.height, 44 - 0.001, "\(label) is shorter than 44 points", file: file, line: line)
  }
}
