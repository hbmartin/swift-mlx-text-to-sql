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
    let previousContinueAfterFailure = continueAfterFailure
    continueAfterFailure = true
    defer { continueAfterFailure = previousContinueAfterFailure }
    let scenarios = canonicalScenarios()
    for size in ["large", "ax1", "ax3", "ax5"] {
      for scenario in scenarios {
        let app = launch(scenario: scenario, dynamicType: size)
        if scenario == "support-bundle-fallback" {
          _ = scrollToControl("Share support bundle", in: app)
        }
        if app.descendants(matching: .any)["ui-test-effective-dynamic-type"].exists {
          assertEffectiveDynamicType(
            ["large": "large", "ax1": "accessibility1", "ax3": "accessibility3", "ax5": "accessibility5"][size]!,
            in: app)
        }
        do {
          try app.performAccessibilityAudit(for: [.hitRegion, .textClipped]) { issue in
            print("Canonical audit: \(scenario), \(size): \(issue.detailedDescription) \(issue.element?.debugDescription ?? "No element")")
            return false
          }
        } catch {
          let attachment = XCTAttachment(screenshot: app.screenshot())
          attachment.name = "Canonical-\(scenario)-\(size)"
          attachment.lifetime = .keepAlways
          add(attachment)
          XCTFail("Canonical audit failed for \(scenario), \(size): \(error)")
        }
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
      error.buttons["conversation-notices"].tap()
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
        "CREG couldn’t open your conversation history. Tap Retry history to try again."].exists)
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
      XCTAssertTrue(app.buttons["conversation-notices"].waitForExistence(timeout: 5))
      app.buttons["conversation-notices"].tap()
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

  func testConversationNoticesScrollAndRetainDismissalState() throws {
    for size in ["large", "ax5"] {
      for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
        XCUIDevice.shared.orientation = orientation
        let app = launch(scenario: "conversation-notices", dynamicType: size)
        let notice = app.buttons["conversation-notices"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        assertAccessibleControl(notice, label: "Conversation notices")
        XCTAssertFalse(app.buttons["Dismiss error"].exists)
        let originalLabel = notice.label
        notice.tap()
        let scroll = app.scrollViews["conversation-notices-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        assertEffectiveDynamicType(size == "ax5" ? "accessibility5" : "large", in: app)
        let firstError = scrollToControl("Dismiss error", in: app)
        assertAccessibleControl(firstError, label: "Dismiss error")
        firstError.tap()
        let share = scrollToControl("Share JSONL export", in: app, identifier: "conversation-export-share")
        assertAccessibleControl(share, label: "Share JSONL export")
        try app.performAccessibilityAudit(for: [.hitRegion, .textClipped])
        let done = app.buttons["conversation-notices-done"]
        assertAccessibleControl(done, label: "Done")
        done.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertNotEqual(notice.label, originalLabel)
        notice.tap()
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        assertAccessibleControl(scrollToControl("Share JSONL export", in: app), label: "Share JSONL export")
        app.terminate()
      }
    }
  }

  func testRetainedExportDoesNotAutomaticallyPresentSharing() throws {
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      let app = launch(scenario: "retained-export", dynamicType: "ax5")
      let complete = app.buttons["held-export-complete"]
      XCTAssertTrue(complete.waitForExistence(timeout: 5))
      complete.tap()
      XCTAssertFalse(app.staticTexts["Conversation events exported"].exists)
      app.buttons["held-export-return"].tap()
      let notice = app.buttons["conversation-notices"]
      XCTAssertTrue(notice.waitForExistence(timeout: 5))
      XCTAssertTrue(notice.label.contains("Export ready"), notice.debugDescription)
      XCTAssertFalse(app.staticTexts["Conversation events exported"].exists)
      notice.tap()
      assertEffectiveDynamicType("accessibility5", in: app)
      assertAccessibleControl(scrollToControl("Share JSONL export", in: app), label: "Share JSONL export")
      app.buttons["conversation-notices-done"].tap()
      XCTAssertTrue(notice.waitForExistence(timeout: 5))
      notice.tap()
      scrollToControl("Share JSONL export", in: app).tap()
      XCTAssertTrue(app.staticTexts["Conversation events exported"].waitForExistence(timeout: 5))
      assertEffectiveDynamicType("accessibility5", in: app)
      try auditRecovery(in: app)
      scrollToControl("Share JSONL", in: app).tap()
      let fileCaption = app.descendants(matching: .any)["LP.CaptionBar.TopCaption"].firstMatch
      XCTAssertTrue(fileCaption.waitForExistence(timeout: 5))
      XCTAssertTrue(fileCaption.label.hasPrefix("creg-conversation-"))
      closeActivitySheet(in: app)
      XCTAssertTrue(app.staticTexts["Conversation events exported"].waitForExistence(timeout: 5))
      scrollToControl("Done", in: app, identifier: "conversation-export-done").tap()
      XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
      app.terminate()
    }
  }

  func testPresentedSheetsReceiveEffectiveAX5() throws {
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      let app = launch(scenario: "conversation-notices", dynamicType: "ax5")
      app.buttons["conversation-notices"].tap()
      assertEffectiveDynamicType("accessibility5", in: app)
      try auditRecovery(in: app)
      app.terminate()
      let settings = launch(scenario: "browser-refresh", dynamicType: "ax5")
      scrollToControl("Settings", in: settings).tap()
      assertEffectiveDynamicType("accessibility5", in: settings)
      try auditRecovery(in: settings)
      settings.terminate()
      let support = launch(scenario: "support-bundle-fallback", dynamicType: "ax5")
      assertEffectiveDynamicType("accessibility5", in: support)
      try auditRecovery(in: support)
      support.terminate()
    }
  }

  func testProductionSupportBindingDismissesAndReleasesArtifacts() throws {
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      let app = launch(scenario: "support-bundle-dismissal", dynamicType: "ax5")
      let completions = orientation == .portrait
        ? ["Done", "Mail Cancel", "Mail Send", "swipe"] : ["Done", "Mail Cancel", "Mail Send"]
      for (index, completion) in completions.enumerated() {
        scrollToControl("Email complete support bundle", in: app).tap()
        let warning = app.staticTexts["support-bundle-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5), app.debugDescription)
        assertEffectiveDynamicType("accessibility5", in: app)
        if index == 0 {
          try auditRecovery(in: app)
          scrollToControl("Share support bundle", in: app).tap()
          let caption = app.descendants(matching: .any)["LP.CaptionBar.TopCaption"].firstMatch
          XCTAssertTrue(caption.waitForExistence(timeout: 5))
          XCTAssertTrue(caption.label.hasPrefix("creg-support-bundle"))
          closeActivitySheet(in: app)
          XCTAssertTrue(warning.waitForExistence(timeout: 5))
        }
        if completion == "swipe" {
          let origin = app.coordinate(withNormalizedOffset: .zero)
          let sheet = app.scrollViews["ui-test-support-bundle-fallback"].frame
          origin.withOffset(CGVector(dx: sheet.midX, dy: sheet.minY + 10))
            .press(forDuration: 0.1, thenDragTo:
              origin.withOffset(CGVector(dx: app.frame.midX, dy: app.frame.maxY - 35)),
              withVelocity: .slow, thenHoldForDuration: 0)
        } else {
          scrollToControl(completion, in: app,
            identifier: completion == "Mail Cancel" ? "support-mail-cancel" :
              completion == "Mail Send" ? "support-mail-send" : nil).tap()
        }
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5), app.debugDescription)
        let artifacts = app.staticTexts["support-artifact-count"]
        let released = XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "label == %@", "\(index + 1):0"), object: artifacts)
        XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 5), .completed,
          "The matching completion must release its directory")
      }
      app.terminate()
    }
  }

  func testMoreRetainsHeldExportUntilExplicitRegeneration() throws {
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      XCUIDevice.shared.orientation = orientation
      let app = launch(scenario: "export-more", dynamicType: "ax5")
      let latest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Jump to latest'")).firstMatch
      if latest.exists { latest.tap() }
      tapMoreClearOfChatHeader(in: app)
      assertEffectiveDynamicType("accessibility5", in: app)
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label == 'ready'"), object: app.descendants(matching: .any)["more-export-state"])
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
      XCTAssertTrue(app.buttons["Helpful"].exists, "Completion must leave More visible")
      XCTAssertFalse(app.staticTexts["Conversation events exported"].exists)
      XCTAssertEqual(app.descendants(matching: .any)["more-export-leases"].label, "0")
      scrollToControl("Helpful", in: app).tap()
      XCTAssertTrue(app.buttons["Helpful"].waitForNonExistence(timeout: 5))
      app.buttons["conversation-notices"].tap()
      scrollToControl("Share JSONL export", in: app).tap()
      XCTAssertTrue(app.staticTexts["Conversation events exported"].waitForExistence(timeout: 5))
      assertEffectiveDynamicType("accessibility5", in: app)
      scrollToControl("Share JSONL", in: app).tap()
      let caption = app.descendants(matching: .any)["LP.CaptionBar.TopCaption"].firstMatch
      XCTAssertTrue(caption.waitForExistence(timeout: 5))
      XCTAssertTrue(caption.label.hasPrefix("creg-conversation"))
      closeActivitySheet(in: app)
      scrollToControl("Done", in: app, identifier: "conversation-export-done").tap()
      XCTAssertTrue(app.buttons["conversation-notices"].waitForNonExistence(timeout: 5))
      app.terminate()
    }
  }

  func testRetainedExportCanBeDiscardedWithoutClearingOtherNotices() throws {
    let app = launch(scenario: "conversation-notices", dynamicType: "ax5")
    let summary = app.buttons["conversation-notices"]
    let before = summary.label
    let beforeCount = try XCTUnwrap(Int(before.split(separator: ",").last!.split(separator: " ").first!))
    summary.tap()
    assertEffectiveDynamicType("accessibility5", in: app)
    let discard = scrollToControl("Discard export", in: app)
    assertAccessibleControl(discard, label: "Discard export")
    discard.tap()
    XCTAssertTrue(discard.waitForNonExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Export ready"].exists)
    XCTAssertTrue(app.buttons["Dismiss error"].firstMatch.exists)
    app.buttons["conversation-notices-done"].tap()
    XCTAssertNotEqual(summary.label, before)
    let afterCount = try XCTUnwrap(Int(summary.label.split(separator: ",").last!.split(separator: " ").first!))
    XCTAssertEqual(afterCount, beforeCount - 1)
    XCTAssertTrue(summary.exists)
    app.terminate()
  }

  func testLongDrawerPreviewsStayBoundedAndSettingsReachable() throws {
    for size in ["large", "ax3", "ax5"] {
      for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
        XCUIDevice.shared.orientation = orientation
        let app = launch(scenario: "browser-long-previews", dynamicType: size)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'DRAWER_FULL_PREVIEW_TAIL'")).firstMatch.exists)
        let preview = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'A long answer paragraph'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(preview.label.count, size == "large" ? 120 : 60)
        try auditRecovery(in: app)
        let settings = scrollToControl("Settings", in: app)
        assertAccessibleControl(settings, label: "Settings")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.terminate()
      }
    }
  }

  func testCompactJumpToLatestWithKeyboardAndCorrection() throws {
    for size in ["large", "ax3", "ax5"] {
      for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
        XCUIDevice.shared.orientation = orientation
        let app = launch(scenario: "compact-jump", dynamicType: size)
        let composer = app.descendants(matching: .any).matching(identifier: "conversation-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["correction-source-answer"].tap()
        let jump = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Jump to latest'")).firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 5), app.debugDescription)
        assertAccessibleControl(jump, label: "Jump to latest")
        XCTAssertTrue(jump.isHittable)
        XCTAssertTrue(app.buttons["correction-source-answer"].isHittable)
        try auditRecovery(in: app)
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "Jump must reach the bottom sentinel")
        XCTAssertTrue(app.buttons["correction-source-answer"].exists)
        app.terminate()
      }
    }
  }

  func testHistoryProgressWarningsAreNeutralOnEverySurface() {
    let app = launch(scenario: "history-progress", dynamicType: "ax5")
    app.buttons["conversation-notices"].tap()
    XCTAssertTrue(app.buttons["Dismiss notice"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Dismiss error"].exists)
    app.buttons["conversation-notices-done"].tap()
    app.buttons["sidebar.leading"].tap()
    scrollToControl("Settings", in: app).tap()
    XCTAssertTrue(app.buttons["Dismiss notice"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Dismiss error"].exists)
    app.terminate()
    let unavailable = launch(scenario: "history-progress-unavailable", dynamicType: "ax5")
    XCTAssertTrue(unavailable.buttons["Dismiss notice"].waitForExistence(timeout: 5))
    XCTAssertFalse(unavailable.buttons["Dismiss error"].exists)
    unavailable.terminate()
  }

  func testDrawerCancellationAllowsTheFirstFollowingSwipe() {
    for reduceMotion in [false, true] {
      let app = launch(scenario: "drawer-gesture-cancellation", dynamicType: "large")
      if reduceMotion { app.buttons["toggle-drawer-motion"].tap() }
      let origin = app.coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(CGVector(dx: 20, dy: app.frame.midY))
      let end = origin.withOffset(CGVector(dx: app.frame.width - 30, dy: app.frame.midY))
      app.buttons["reset-drawer-motion"].tap()
      start.press(forDuration: 0.05,
        thenDragTo: origin.withOffset(CGVector(dx: 110, dy: app.frame.midY)),
        withVelocity: XCUIGestureVelocity(rawValue: 50), thenHoldForDuration: 0.3)
      XCTAssertLessThan(app.buttons["sidebar.leading"].frame.minX, 100)
      let opening = app.descendants(matching: .any)["drawer-rollback-frames"].firstMatch.label
      XCTAssertGreaterThan(Int(opening.split(separator: "|")[0].split(separator: ",")[0]) ?? 0, 1,
        "Short opening rollback must interpolate, Reduce Motion: \(reduceMotion)")
      XCTAssertEqual(Int(opening.split(separator: "|")[0].split(separator: ",")[1]), 0,
        "Each fixture starts with cleared closing rollback capture")
      print("Drawer opening rollback Reduce Motion \(reduceMotion): \(opening)")
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = "Drawer rollback Reduce Motion \(reduceMotion)"
      attachment.lifetime = .keepAlways; add(attachment)
      start.press(forDuration: 0.05,
        thenDragTo: origin.withOffset(CGVector(dx: 100, dy: app.frame.midY + 160)),
        withVelocity: .slow, thenHoldForDuration: 0.1)
      XCTAssertLessThan(app.buttons["sidebar.leading"].frame.minX, 100)
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
      XCTAssertTrue(app.buttons["Close conversation browser"].waitForExistence(timeout: 5))
      app.buttons["reset-drawer-motion"].tap()
      end.press(forDuration: 0.05,
        thenDragTo: origin.withOffset(CGVector(dx: app.frame.width - 110, dy: app.frame.midY)),
        withVelocity: XCUIGestureVelocity(rawValue: 50), thenHoldForDuration: 0.3)
      XCTAssertTrue(app.buttons["Close conversation browser"].exists)
      let closing = app.descendants(matching: .any)["drawer-rollback-frames"].firstMatch.label
      XCTAssertGreaterThan(Int(closing.split(separator: "|")[0].split(separator: ",")[1]) ?? 0, 1,
        "Short closing rollback must interpolate, Reduce Motion: \(reduceMotion)")
      XCTAssertEqual(Int(closing.split(separator: "|")[0].split(separator: ",")[0]), 0,
        "Reset clears opening capture before closing interpolation, Reduce Motion: \(reduceMotion)")
      print("Drawer closing rollback Reduce Motion \(reduceMotion): \(closing)")
      end.press(forDuration: 0.05, thenDragTo: start, withVelocity: .fast, thenHoldForDuration: 0)
      app.buttons["interrupt-drawer-drag"].tap()
      start.press(forDuration: 0.05, thenDragTo: end,
        withVelocity: XCUIGestureVelocity(rawValue: 50), thenHoldForDuration: 0)
      XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
      app.buttons["Done"].tap()
      XCTAssertLessThan(app.buttons["sidebar.leading"].frame.minX, 100)
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
      XCTAssertTrue(app.buttons["Close conversation browser"].waitForExistence(timeout: 5),
        "The first edge swipe after cancellation must open the drawer")
      app.terminate()
    }
  }

  func testNoticeTechnicalDetailsKeepFailureIdentity() {
    let app = launch(scenario: "conversation-notices", dynamicType: "large", developerMode: true)
    app.buttons["conversation-notices"].tap()
    XCTAssertTrue(app.buttons["conversation-notices-done"].waitForExistence(timeout: 5), app.debugDescription)
    let details = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "failure-details-notice_fixture_1-")).firstMatch
    XCTAssertTrue(details.waitForExistence(timeout: 5), app.debugDescription)
    details.tap()
    let expanded = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'notice-details-1'")).firstMatch
    XCTAssertTrue(expanded.waitForExistence(timeout: 5))
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "failure-dismiss-notice_fixture_0-")).firstMatch.tap()
    XCTAssertTrue(expanded.isHittable, "The expanded section must remain with failure 1 after failure 0 is removed")
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "failure-dismiss-notice_fixture_1-")).firstMatch.tap()
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'notice-details-2'")).firstMatch.isHittable,
      "Expansion must not move to the next failure")
    app.buttons["conversation-notices-done"].tap()
    app.terminate()

    let occurrences = launch(scenario: "notice-occurrences", dynamicType: "large", developerMode: true)
    let matching = occurrences.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "failure-details-same_code-"))
    let original = matching.matching(NSPredicate(format: "identifier CONTAINS 'global' ")).firstMatch
    let survivor = matching.matching(NSPredicate(format: "identifier CONTAINS 'history-2' ")).firstMatch
    XCTAssertTrue(original.waitForExistence(timeout: 5))
    XCTAssertNotEqual(original.identifier, survivor.identifier)
    original.tap(); survivor.tap()
    let oldDetails = occurrences.staticTexts.matching(NSPredicate(format: "label CONTAINS 'occurrence-original'")).firstMatch
    let survivorDetails = occurrences.staticTexts.matching(NSPredicate(format: "label CONTAINS 'occurrence-survivor'")).firstMatch
    XCTAssertTrue(oldDetails.isHittable)
    occurrences.buttons["notice-duplicate"].tap()
    XCTAssertTrue(oldDetails.isHittable, "Duplicate delivery preserves expansion")
    occurrences.buttons["notice-replace"].tap()
    XCTAssertFalse(oldDetails.exists)
    let replacementDetails = occurrences.staticTexts.matching(NSPredicate(format: "label CONTAINS 'occurrence-replacement'")).firstMatch
    XCTAssertFalse(replacementDetails.isHittable, "Replacement begins collapsed")
    XCTAssertTrue(survivorDetails.isHittable, "Surviving failure retains expansion")
    matching.matching(NSPredicate(format: "identifier CONTAINS 'global'")).firstMatch.tap()
    XCTAssertTrue(replacementDetails.isHittable)
    occurrences.terminate()
  }

  func testConversationWriteRecoveryOffersRetryInNoticesAndSettings() throws {
    for settings in [false, true] {
      let app = launch(scenario: "notice-occurrences", dynamicType: "ax5", developerMode: true)
      if settings {
        app.buttons["Settings"].tap()
        assertEffectiveDynamicType("accessibility5", in: app)
      }
      for code in ["history_draft_save_failed", "history_result_preference_save_failed"] {
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "failure-retry-saving-" + code + "-")).firstMatch
        _ = scrollToControl("Retry saving", in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        let identity = retry.identifier
        assertAccessibleControl(retry, label: "Retry saving")
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(app.buttons[identity].waitForNonExistence(timeout: 5))
      }
      XCTAssertFalse(app.staticTexts["Draft not saved"].exists)
      app.terminate()
    }
  }

  func testAccessibleHeadersWrapAtLargeTextSizes() throws {
    for size in ["ax1", "ax3", "ax5"] {
      for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
        XCUIDevice.shared.orientation = orientation
        for scenario in ["recovery", "conversation-notices", "apple-intelligence-disabled", "result-explorer"] {
          let app = launch(scenario: scenario, dynamicType: size)
          if scenario == "result-explorer" {
            assertEffectiveDynamicType(
              ["ax1": "accessibility1", "ax3": "accessibility3", "ax5": "accessibility5"][size]!,
              in: app)
          }
          if scenario == "apple-intelligence-disabled" {
            let callout = scrollToControl("Turn on Apple Intelligence", in: app)
            XCTAssertTrue(callout.label.contains("Settings › Apple Intelligence & Siri"))
          }
          try auditRecovery(in: app)
          app.terminate()
        }
      }
    }
  }

  func testDrawerRealizationStaysBoundedAndUnrelatedErrorsDoNotRedrawRows() {
    let app = launch(scenario: "browser-performance", dynamicType: "large")
    let count = app.staticTexts["drawer-realized-count"]
    XCTAssertTrue(count.waitForExistence(timeout: 5))
    let populated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != '0'"), object: count)
    XCTAssertEqual(XCTWaiter.wait(for: [populated], timeout: 5), .completed)
    let realized = Int(count.label) ?? 1000
    XCTAssertGreaterThan(realized, 0)
    XCTAssertLessThan(realized, 100)
    print("Drawer initial realized rows: \(realized)")
    let renders = app.staticTexts["drawer-render-count"]
    let previous = renders.label
    print("Drawer initial row bodies: \(previous)")
    app.buttons["drawer-inject-error"].tap()
    XCTAssertTrue(app.staticTexts["drawer-error-settled"].waitForExistence(timeout: 5))
    XCTAssertEqual(renders.label, previous)
    app.terminate()
  }

  func testCorrectionControlsRemainReachableWithKeyboardAndReduceMotion() throws {
    for size in ["large", "ax3", "ax5"] {
      for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
        XCUIDevice.shared.orientation = orientation
        let app = launch(scenario: "recovery", dynamicType: size)
        let composer = app.descendants(matching: .any).matching(identifier: "conversation-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.isHittable, app.debugDescription)
        try auditRecovery(in: app)
        composer.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) {
          let attachment = XCTAttachment(screenshot: app.screenshot())
          attachment.lifetime = .keepAlways
          add(attachment)
          XCTFail("Keyboard did not appear: \(app.debugDescription)")
        }
        let source = app.buttons["correction-source-answer"]
        XCTAssertTrue(source.isHittable, app.debugDescription)
        assertAccessibleControl(source, label: "Review source answer")
        for control in [app.buttons["sidebar.leading"], app.buttons["square.and.pencil"],
          app.buttons["conversation-notices"]] {
          assertAccessibleControl(control, label: control.label)
          XCTAssertTrue(control.isHittable, app.debugDescription)
        }
        if app.buttons["Dismiss keyboard"].exists {
          assertAccessibleControl("Dismiss keyboard", in: app)
          XCTAssertTrue(app.buttons["Dismiss keyboard"].isHittable)
        }
        source.tap()
        let dismiss = app.buttons["Dismiss correction"]
        assertAccessibleControl(dismiss, label: "Dismiss correction")
        XCTAssertTrue(dismiss.isHittable)
        dismiss.tap()
        XCTAssertTrue(source.waitForNonExistence(timeout: 5))
        app.terminate()
      }
    }
    XCUIDevice.shared.orientation = .portrait
    let table = launch(scenario: "recovery", dynamicType: "large")
    scrollToControl("Table", in: table).tap()
    let result = scrollToControl("4 rows, Explore result", in: table)
    let origin = table.coordinate(withNormalizedOffset: .zero)
    let start = CGPoint(x: result.frame.midX, y: result.frame.midY)
    origin.withOffset(CGVector(dx: start.x, dy: start.y)).press(forDuration: 0.05,
      thenDragTo: origin.withOffset(CGVector(dx: table.frame.width - 10, dy: start.y)),
      withVelocity: .fast, thenHoldForDuration: 0)
    XCTAssertLessThan(table.buttons["sidebar.leading"].frame.minX, 100,
      "A flick starting inside the result table must keep the drawer closed")
    table.terminate()
    let disabled = launch(scenario: "apple-intelligence-disabled", dynamicType: "ax5")
    let callout = disabled.descendants(matching: .any).matching(identifier: "apple-intelligence-callout").firstMatch
    XCTAssertTrue(callout.waitForExistence(timeout: 5))
    XCTAssertTrue(callout.label.contains("Settings › Apple Intelligence & Siri"))
    disabled.terminate()
  }

  private func assertEffectiveDynamicType(_ size: String, in app: XCUIApplication) {
    let probe = app.descendants(matching: .any).matching(identifier: "ui-test-effective-dynamic-type").firstMatch
    XCTAssertTrue(probe.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(probe.label, size, "Audit the effective presented size before claiming coverage")
  }

  func testBrowserRefreshPreservesSearchAndKeyboardFocus() {
    for size in ["large", "ax5"] {
      for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
        XCUIDevice.shared.orientation = orientation
        let app = launch(scenario: "browser-refresh", dynamicType: size)
        let search = app.textFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if size == "large", orientation == .portrait {
          let origin = app.coordinate(withNormalizedOffset: .zero)
          // The dimmed foreground chat supports swiping the drawer closed.
          let start = origin.withOffset(CGVector(dx: app.frame.width - 20, dy: app.frame.midY))
          start.press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: 20, dy: app.frame.midY)),
            withVelocity: .fast, thenHoldForDuration: 0)
          let sidebar = app.buttons["sidebar.leading"]
          XCTAssertLessThan(sidebar.frame.minX, 100, "The chat must return to its closed-drawer position: \(app.debugDescription)")
          sidebar.tap()
          XCTAssertTrue(search.waitForExistence(timeout: 5))
        }
        search.tap()
        search.typeText("Saved")
        scrollToControl("Retry history", in: app, identifier: "browser-history-retry").tap()
        XCTAssertTrue(app.buttons["browser-history-retry"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "Saved")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.terminate()
      }
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
      assertEffectiveDynamicType("accessibility5", in: app)
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
        assertEffectiveDynamicType(size == "ax5" ? "accessibility5" : "large", in: app)
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
    dynamicType: String? = nil,
    developerMode: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["CREG_UI_TEST_DEVELOPER_MODE"] = developerMode ? "1" : "0"
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
    let popupDismissal = app.otherElements["PopoverDismissRegion"].firstMatch
    if app.popovers.firstMatch.exists, popupDismissal.exists {
      let bounds = popupDismissal.frame
      let popup = app.popovers.firstMatch.frame
      let safeBounds = bounds.insetBy(dx: 24, dy: 24)
      let outside = [
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, popup.minY - bounds.minY)),
        CGRect(x: bounds.minX, y: popup.maxY, width: bounds.width, height: max(0, bounds.maxY - popup.maxY)),
        CGRect(x: bounds.minX, y: bounds.minY, width: max(0, popup.minX - bounds.minX), height: bounds.height),
        CGRect(x: popup.maxX, y: bounds.minY, width: max(0, bounds.maxX - popup.maxX), height: bounds.height),
      ].map { $0.intersection(safeBounds) }.filter { !$0.isEmpty }
        .max { $0.width * $0.height < $1.width * $1.height }
      guard let outside else {
        XCTFail("No dismissal region outside the native share popover: \(app.debugDescription)")
        return
      }
      popupDismissal.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: outside.midX - bounds.minX, dy: outside.midY - bounds.minY)).tap()
      XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
      return
    }
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
    if label == "Dismiss correction", app.buttons["conversation-notices-done"].exists {
      app.buttons["conversation-notices-done"].tap()
      XCTAssertTrue(app.scrollViews["conversation-notices-scroll"].waitForNonExistence(timeout: 5))
    }
    if ["Dismiss error", "Dismiss interrupted question", "Ask Again", "Share JSONL export"].contains(label),
      !app.scrollViews["conversation-notices-scroll"].exists,
      !app.scrollViews["conversation-export-scroll"].exists,
      app.buttons["conversation-notices"].exists {
      app.buttons["conversation-notices"].tap()
    }
    let control = identifier.map { app.buttons[$0] } ?? app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    let moreScroll = app.scrollViews["answer-more-scroll"]
    let recoveryScroll = app.scrollViews["conversation-recovery-scroll"]
    let noticesScroll = app.scrollViews["conversation-notices-scroll"]
    let exportScroll = app.scrollViews["conversation-export-scroll"]
    let browserHistoryScroll = app.scrollViews["browser-history-scroll"]
    let settingsScroll = app.descendants(matching: .any)["settings-scroll"].firstMatch
    let scrollers = app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
    let owningScroller = control.exists
      ? scrollers.last { controlBelongsToScroll(control, scroll: $0) } : nil
    let scroll: XCUIElement
    if let owningScroller {
      scroll = owningScroller
    } else if settingsScroll.exists {
      scroll = settingsScroll
    } else if identifier == "browser-history-retry", browserHistoryScroll.exists {
      scroll = browserHistoryScroll
    } else if exportScroll.exists {
      scroll = exportScroll
    } else if noticesScroll.exists {
      scroll = noticesScroll
    } else if recoveryScroll.exists {
      scroll = recoveryScroll
    } else if moreScroll.exists {
      scroll = moreScroll
    } else if app.scrollViews["conversation-transcript-scroll"].exists {
      scroll = app.scrollViews["conversation-transcript-scroll"]
    } else {
      scroll = (app.scrollViews.allElementsBoundByIndex.first { $0.isHittable }
          ?? app.collectionViews.allElementsBoundByIndex.first { $0.isHittable }
          ?? app.scrollViews.firstMatch)
    }
    for _ in 0..<40 {
      let before = scrollProgress(scroll)
      if control.exists && !controlBelongsToScroll(control, scroll: scroll) {
        guard control.isHittable else {
          failScrollGeometry("Fixed control is not hittable: \(control.debugDescription)", app: app)
          return control
        }
        _ = settleVisibleControl(control, scroll: scroll, app: app)
        return control
      }
      if control.exists && control.isHittable {
        let frameBeforeGesture = control.frame
        if settleVisibleControl(control, scroll: scroll, app: app) { return control }
        if control.frame == frameBeforeGesture {
          failScrollGeometry("Control \(label) did not move after a settling gesture and remains unreachable: \(control.debugDescription)", app: app)
          return control
        }
        continue
      }
      swipeScrollableContent(scroll, in: app, up: true)
      if scrollProgress(scroll) == before { break }
    }
    for _ in 0..<40 {
      let before = scrollProgress(scroll)
      if control.exists && !controlBelongsToScroll(control, scroll: scroll) {
        guard control.isHittable else {
          failScrollGeometry("Fixed control is not hittable: \(control.debugDescription)", app: app)
          return control
        }
        _ = settleVisibleControl(control, scroll: scroll, app: app)
        return control
      }
      if control.exists && control.isHittable {
        let frameBeforeGesture = control.frame
        if settleVisibleControl(control, scroll: scroll, app: app) { return control }
        if control.frame == frameBeforeGesture {
          failScrollGeometry("Control \(label) did not move after a settling gesture and remains unreachable: \(control.debugDescription)", app: app)
          return control
        }
        continue
      }
      swipeScrollableContent(scroll, in: app, up: false)
      if scrollProgress(scroll) == before { break }
    }
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
    XCTFail("Control \(label) remains unreachable after scrolling stopped making progress: \(control.debugDescription)")
    return control
  }

  private func scrollProgress(_ scroll: XCUIElement) -> String {
    let anchor = scroll.descendants(matching: .staticText).firstMatch
    return anchor.exists ? "\(anchor.label):\(anchor.frame)" : scroll.debugDescription
  }

  private func settleVisibleControl(
    _ control: XCUIElement, scroll: XCUIElement, app: XCUIApplication
  ) -> Bool {
    // XCTest calls partially clipped buttons hittable, but their synthesized
    // center tap can land in the system's top or bottom gesture region.
    let keyboardTop = unobscuredBottom(in: app)
    let window = app.windows.firstMatch.frame.intersection(app.frame)
    let unobscuredWindow = CGRect(x: window.minX, y: window.minY,
      width: window.width, height: max(0, min(window.maxY, keyboardTop) - window.minY))
    var viewport = CGRect(x: app.frame.minX, y: app.frame.minY + 64,
      width: app.frame.width, height: max(0, min(app.frame.maxY - 24, keyboardTop) - app.frame.minY - 64))
    let frame = control.frame
    // A footer/header control can be hittable without belonging to the
    // transcript. Scrolling that transcript cannot settle a fixed control.
    guard controlBelongsToScroll(control, scroll: scroll) else {
      let reachable = unobscuredWindow.contains(CGPoint(x: frame.midX, y: frame.midY))
      if !reachable { failScrollGeometry("Fixed control is obscured: \(control.debugDescription)", app: app) }
      return reachable
    }
    let scrollingFrame = visibleScrollFrame(scroll, in: app)
    // Fixed recovery/header/footer controls can sit outside their panel's
    // scroller. Only transcript controls must stay clear of chat chrome.
    viewport = CGRect(x: viewport.minX, y: max(viewport.minY, scrollingFrame.minY),
      width: viewport.width, height: max(0, min(viewport.maxY, scrollingFrame.maxY) - max(viewport.minY, scrollingFrame.minY)))
    let delta: CGFloat
    // A control nearly fills a compact lane. Requiring its entire frame
    // plus a minimum drag would alternate past each edge indefinitely.
    // Settle its tap center while the accessibility audit checks clipping.
    if (!hasOwnScrollingChrome(scroll) && frame.height + 48 > viewport.height)
      || ["conversation-recovery-scroll", "browser-history-scroll", "conversation-notices-scroll",
        "ui-test-support-bundle-fallback"].contains(scroll.identifier) {
      delta = frame.midY < viewport.minY ? max(24, viewport.minY - frame.midY + 12)
        : (frame.midY > viewport.maxY ? min(-24, viewport.maxY - frame.midY - 12) : 0)
    } else {
      delta = frame.minY < viewport.minY ? max(24, viewport.minY - frame.minY)
        : (frame.maxY > viewport.maxY ? min(-24, viewport.maxY - frame.maxY) : 0)
    }
    guard delta != 0 else { return true }
    let visibleScroll = visibleScrollFrame(scroll, in: app)
    guard visibleScroll.height >= 44 else {
      failScrollGeometry("No usable settling lane: \(visibleScroll), control=\(frame)", app: app)
      return false
    }
    let origin = app.coordinate(withNormalizedOffset: .zero)
    if hasOwnScrollingChrome(scroll) {
      let stroke = max(-visibleScroll.height / 2 + 2,
        min(delta, visibleScroll.height / 2 - 2))
      let start = origin.withOffset(CGVector(dx: visibleScroll.midX - app.frame.minX, dy: visibleScroll.midY - app.frame.minY))
      start.press(forDuration: 0.1,
        thenDragTo: origin.withOffset(CGVector(dx: visibleScroll.midX - app.frame.minX, dy: visibleScroll.midY - app.frame.minY + stroke)),
        withVelocity: .slow, thenHoldForDuration: 0.2)
    } else {
      let stroke = max(-visibleScroll.height + 4, min(delta, visibleScroll.height - 4))
      let startY = stroke > 0 ? visibleScroll.minY + 2 : visibleScroll.maxY - 2
      let start = origin.withOffset(CGVector(dx: visibleScroll.midX - app.frame.minX, dy: startY - app.frame.minY))
      start.press(forDuration: 0.1,
        thenDragTo: origin.withOffset(CGVector(dx: visibleScroll.midX - app.frame.minX, dy: startY - app.frame.minY + stroke)),
        withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    return false
  }

  private func swipeScrollableContent(
    _ scroll: XCUIElement, in app: XCUIApplication, up: Bool
  ) {
    let frame = scroll.frame
    if ["settings-scroll", "answer-more-scroll", "conversation-recovery-scroll", "browser-history-scroll", "conversation-notices-scroll", "conversation-export-scroll",
      "ui-test-support-bundle-fallback"].contains(scroll.identifier) {
      // SwiftUI can report a zero-sized ancestor for a visible popover.
      // XCTest's automatic swipe then rejects its visible scroll view.
      let visible = visibleScrollFrame(scroll, in: app)
      guard visible.height >= 44 else {
        failScrollGeometry("No usable panel swipe lane: \(visible)", app: app)
        return
      }
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
    let visible = visibleScrollFrame(scroll, in: app)
    XCTAssertFalse(visible.isEmpty, "Transcript scrolling content is offscreen: \(scroll.debugDescription)")
    guard visible.height >= 44 else {
      failScrollGeometry("No usable transcript swipe lane: \(visible)", app: app)
      return
    }
    // Transcript scroll views extend under both safe-area insets in either
    // orientation. Keep the entire stroke inside visible content.
    let start = scroll.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: visible.midX - frame.minX,
        dy: visible.minY + visible.height * (up ? 0.8 : 0.2) - frame.minY))
    let end = scroll.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: visible.midX - frame.minX,
        dy: visible.minY + visible.height * (up ? 0.2 : 0.8) - frame.minY))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
  }

  private func visibleScrollFrame(_ scroll: XCUIElement, in app: XCUIApplication) -> CGRect {
    let keyboardTop = unobscuredBottom(in: app)
    let unobscured = CGRect(x: app.frame.minX, y: app.frame.minY,
      width: app.frame.width, height: max(0, keyboardTop - app.frame.minY))
    let visible = scroll.frame.intersection(unobscured)
    let header = app.buttons.matching(
      NSPredicate(format: "label CONTAINS 'conversation actions'")).firstMatch
    guard !hasOwnScrollingChrome(scroll), header.exists else { return visible }
    let composer = app.descendants(matching: .any).matching(identifier: "conversation-composer")
      .allElementsBoundByIndex.first { $0.isHittable }
    let latest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Jump to latest'"))
      .allElementsBoundByIndex.first { $0.isHittable }
    let top = max(visible.minY, header.isHittable ? header.frame.maxY + 8 : visible.minY)
    let bottom = composer.map { min(visible.maxY, $0.frame.minY - 8) } ?? visible.maxY
    let notices = app.buttons["conversation-notices"]
    let overlays = [latest, notices.exists && notices.isHittable ? notices : nil].compactMap { $0 }
    // Floating pills obscure their own width, not the entire transcript.
    // Choose the longest vertical lane around their actual rectangles.
    let lanes = [0.7, 0.25, 0.9, 0.1].map { fraction -> CGRect in
      let x = visible.minX + visible.width * fraction
      var laneBottom = bottom
      for overlay in overlays {
        let obstruction = overlay.frame.insetBy(dx: -4, dy: -4)
        if x >= obstruction.minX && x <= obstruction.maxX,
          obstruction.maxY > top, obstruction.minY < laneBottom {
          laneBottom = min(laneBottom, obstruction.minY)
        }
      }
      return CGRect(x: x - 2, y: top, width: 4, height: max(0, laneBottom - top))
    }
    return lanes.max(by: { $0.height < $1.height }) ?? .zero
  }

  private func controlBelongsToScroll(_ control: XCUIElement, scroll: XCUIElement) -> Bool {
    let predicate = control.identifier.isEmpty
      ? NSPredicate(format: "label == %@", control.label)
      : NSPredicate(format: "identifier == %@", control.identifier)
    return scroll.descendants(matching: control.elementType).matching(predicate)
      .allElementsBoundByIndex.contains { $0.frame == control.frame }
  }

  private func failScrollGeometry(_ message: String, app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTFail(message + "\n" + app.debugDescription)
  }

  private func hasOwnScrollingChrome(_ scroll: XCUIElement) -> Bool {
    ["settings-scroll", "answer-more-scroll", "conversation-recovery-scroll", "browser-history-scroll",
      "conversation-notices-scroll", "conversation-export-scroll",
      "ui-test-support-bundle-fallback"].contains(scroll.identifier)
  }

  private func unobscuredBottom(in app: XCUIApplication) -> CGFloat {
    // XCTest's keyboard frame excludes the prediction row in landscape.
    // Keep gestures above that row rather than dragging its candidates.
    app.keyboards.firstMatch.exists
      ? app.keyboards.firstMatch.frame.minY - (app.frame.width > app.frame.height ? 44 : 0)
      : app.frame.maxY
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
      let composer = app.descendants(matching: .any).matching(identifier: "conversation-composer").firstMatch
      let bottom = composer.exists ? composer.frame.minY : app.frame.maxY - 120
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
