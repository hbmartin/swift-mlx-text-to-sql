import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import Foundation
import SwiftUI

/// Deterministic, side-effect-free fixtures for the named design previews.
/// Fixed identifiers and dates, an inert reducer, and stub dependencies —
/// no pipeline, history store, network, or clock access.
enum PreviewFixtures {
  /// 2026-07-01 12:00:00 UTC — aligned with the Portfolio As-of Date.
  static let now = Date(timeIntervalSince1970: 1_782_907_200)

  static func id(_ digit: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-00000000000\(digit)")!
  }

  static let fundValueResult = QueryResult(
    columns: ["fund", "current_market_value"],
    rows: [
      [.text("Meridian Core Fund I"), .real(412_500_000)],
      [.text("Meridian Value-Add II"), .real(268_900_000)],
      [.text("Harborline Opportunistic"), .real(154_300_000)],
      [.text("Coastal Core-Plus III"), .real(98_750_000)],
    ],
    isTruncated: false,
    elapsedMicroseconds: 5_800)

  static let loanMaturityResult = QueryResult(
    columns: ["property", "lender", "current_balance", "maturity_date"],
    rows: [
      [
        .text("Harbor Point Tower"), .text("Bay Bank"), .real(25_000_000),
        .text("2027-04-01"),
      ],
      [
        .text("Eastgate Industrial"), .text("Union Credit"), .real(18_500_000),
        .text("2027-11-15"),
      ],
      [
        .text("Meridian Plaza"), .text("Pacific Trust"), .real(40_700_000),
        .text("2028-02-15"),
      ],
    ],
    isTruncated: false,
    elapsedMicroseconds: 7_200)

  static let leaseListingResult: QueryResult = {
    let tenants = ["Northwind Logistics", "Cascade Legal Group", "Béa Café", "Atlas Data"]
    let properties = ["Harbor Point Tower", "Meridian Plaza", "Eastgate Industrial"]
    var rows: [[SQLValue]] = []
    for index in 1...48 {
      var row: [SQLValue] = []
      row.append(.integer(Int64(4000 + index)))
      row.append(.text(tenants[index % 4]))
      row.append(.text(properties[index % 3]))
      row.append(.text("Suite \(100 + index)"))
      row.append(.text("2026-\(String(format: "%02d", (index % 12) + 1))-15"))
      row.append(.text(index % 5 == 0 ? "Holdover" : "Active"))
      rows.append(row)
    }
    return QueryResult(
      columns: ["lease_id", "tenant", "property", "suite", "expiration_date", "status"],
      rows: rows,
      isTruncated: false,
      elapsedMicroseconds: 12_400)
  }()

  static let truncatedResult: QueryResult = {
    var rows: [[SQLValue]] = []
    for index in 0..<500 {
      var row: [SQLValue] = []
      row.append(.text("Property \(index % 40)"))
      row.append(.text("Tenant \(index)"))
      row.append(.real(Double(48_000 + index * 250)))
      rows.append(row)
    }
    return QueryResult(
      columns: ["property", "tenant", "annual_base_rent"],
      rows: rows,
      isTruncated: true,
      elapsedMicroseconds: 48_200)
  }()

  static var answeredTelemetry: TurnTelemetry {
    var telemetry = TurnTelemetry(
      originalQuestion: "What's the current market value of the portfolio by fund?")
    telemetry.queryOrigin = .freeForm
    telemetry.executionPath = .generated
    telemetry.gateDecision = .proceed
    var timings = StageTimings(totalMicroseconds: 8_432_000)
    timings.rewriteMicroseconds = 412_000
    timings.gateMicroseconds = 128_000
    timings.groundingMicroseconds = 61_000
    timings.votingMicroseconds = 22_000
    timings.narrationMicroseconds = 540_000
    telemetry.stageTimings = timings
    telemetry.generatedCount = 3
    telemetry.voteTrigger = "always"
    telemetry.voteOutcome = .consensus(
      resultDigest: "3f2a9c1d", agreement: 3, candidateCount: 3)
    telemetry.selectionReason = .majorityVote
    telemetry.confidence = .confirmed

    let model = ModelReference(
      key: "creg-sql-xiyansql-3b",
      repository: "creg/xiyansql-qwencoder-3b",
      revision: "aa11bb22cc33dd44",
      quantization: "4bit")
    telemetry.candidates = [
      CandidateID(rawValue: "anchor-0"),
      CandidateID(rawValue: "sample-1"),
      CandidateID(rawValue: "sample-2"),
    ].enumerated().map { index, candidateID in
      var candidate = CandidateTelemetry(
        request: SQLGenerationRequest(
          candidateID: candidateID,
          role: index == 0 ? .deterministicAnchor : .consistencySample(index: index),
          model: model,
          question: telemetry.originalQuestion,
          gcd: .on,
          temperature: index == 0 ? 0 : 0.6,
          seed: UInt64(41 + index)))
      candidate.sql = starterSQL
      candidate.tokensPerSecond = 38.2
      candidate.tokenCount = 61
      candidate.generationMicroseconds = 1_920_000
      candidate.executionMicroseconds = 5_800
      candidate.result = fundValueResult
      candidate.resultDigest = "3f2a9c1d"
      candidate.selected = index == 0
      return candidate
    }
    telemetry.selectedCandidateID = CandidateID(rawValue: "anchor-0")
    return telemetry
  }

  static let starterSQL = StarterQueryID.portfolioValueByFundV1.sql

  static let answeredNarration =
    "Across your four active funds, held properties total $934.5M in current market value, led by Meridian Core Fund I at $412.5M."

  static var conversationMessages: IdentifiedArrayOf<ChatMessage> {
    [
      ChatMessage(
        id: id("1"), role: .user,
        body: .text("What's the current market value of the portfolio by fund?"),
        createdAt: now.addingTimeInterval(-320)),
      ChatMessage(
        id: id("2"), role: .assistant,
        body: .answer(
          result: fundValueResult,
          narration: answeredNarration,
          sql: starterSQL,
          notice: nil),
        traceSteps: [
          "Understanding your question",
          "Checking the question is clear enough",
          "Generating the initial lookup",
          "Running the numbers",
          "Looking through the results (4 rows)",
          "Reading the question a few ways to be sure",
          "3 of 3 readings agreed",
          "Summarizing what I found",
        ],
        createdAt: now.addingTimeInterval(-300),
        devInfo: answeredTelemetry),
    ]
  }

  static func chatState(
    messages: IdentifiedArrayOf<ChatMessage> = [],
    title: String = ""
  ) -> ChatFeature.State {
    ChatFeature.State(
      conversationID: id("9"),
      title: title,
      messages: messages)
  }

  static func answeredChatState() -> ChatFeature.State {
    chatState(
      messages: conversationMessages,
      title: "Current market value by fund")
  }

  static func preparedFollowUps(count: Int = 3) -> [PreparedFollowUp] {
    let questions = [
      "How does current market value compare with acquisition cost by fund?",
      "Which held properties contribute the most value to Meridian Core Fund I?",
      "What is the outstanding loan balance by fund?",
    ]
    return Array(questions.prefix(count)).enumerated().map { offset, question in
      let sql = "SELECT \(offset + 1)"
      return PreparedFollowUp(
        id: id(String(6 + offset)),
        sourceAssistantMessageID: id("2"),
        rank: offset + 1,
        question: question,
        sql: sql,
        result: fundValueResult,
        preparationTelemetry: answeredTelemetry,
        provenance: PreparedQueryProvenance(
          modelKey: "creg-sql-xiyansql-3b",
          modelRevision: "aa11bb22cc33dd44",
          runtimeMode: .evaluated,
          preparationPolicyVersion: "prepared-follow-up-v1|binding-repair-v2",
          databaseFingerprint: "preview-database",
          sqlFingerprint: PreparedFollowUpIntegrity.fingerprint(sql: sql),
          resultFingerprint: PreparedFollowUpIntegrity.fingerprint(
            result: fundValueResult)),
        createdAt: now.addingTimeInterval(Double(offset)))
    }
  }

  static func followUpChatState(count: Int) -> ChatFeature.State {
    var state = answeredChatState()
    state.followUpBatch = PreparedFollowUpBatch(
      sourceAssistantMessageID: id("2"),
      status: count == 3 ? .completed : .preparing,
      suggestions: preparedFollowUps(count: count),
      updatedAt: now)
    return state
  }

  static func summarizingPreparedChatState() -> ChatFeature.State {
    var state = answeredChatState()
    let prepared = preparedFollowUps(count: 1)[0]
    state.messages.append(
      ChatMessage(
        id: id("5"), role: .user, body: .text(prepared.question),
        createdAt: now.addingTimeInterval(1)))
    state.messages.append(
      ChatMessage(
        id: id("6"), role: .assistant,
        body: .preparedAnswer(prepared),
        traceSteps: ["Showing the prepared result (4 rows)"],
        createdAt: now.addingTimeInterval(2)))
    state.processing = ChatFeature.ProcessingState(
      questionID: id("7"),
      question: prepared.question,
      startedAt: now.addingTimeInterval(1),
      trace: [
        "Showing the prepared result (4 rows)",
        "Summarizing what I found",
      ])
    return state
  }

  static func processingChatState() -> ChatFeature.State {
    var state = answeredChatState()
    state.processing = ChatFeature.ProcessingState(
      questionID: id("3"),
      question: "Which of those funds grew the most since acquisition?",
      startedAt: now.addingTimeInterval(-6),
      trace: [
        "Understanding your question",
        "Rephrasing your follow-up as a standalone question",
        "Generating the initial lookup",
      ],
      isTimelineExpanded: true)
    state.messages.append(
      ChatMessage(
        id: id("4"), role: .user,
        body: .text("Which of those funds grew the most since acquisition?"),
        createdAt: now.addingTimeInterval(-6)))
    state.queued = [
      QueuedQuestion(
        id: id("5"),
        conversationID: id("9"),
        question: "And what's the total debt service across them?",
        submittedAt: now.addingTimeInterval(-2))
    ]
    return state
  }

  static func recoveryChatState() -> ChatFeature.State {
    var state = answeredChatState()
    state.interruptedTurn = InterruptedTurn(
      question:
        "Compare every property’s debt maturity with its lease expiration schedule.",
      interruptedAt: now.addingTimeInterval(-30))
    state.correctionContext = ChatFeature.CorrectionContext(
      messageID: id("2"),
      answerNarration: answeredNarration)
    state.composerText = "The Harborline total should exclude sold properties."
    return state
  }

  static let presentationFailure = FailurePresentation(
    code: "preview_history_unavailable",
    title: "History unavailable",
    message:
      "CREG couldn’t load the saved conversation. You can continue, but changes may not be saved until the app reconnects to its local history store.",
    diagnostic: "Deterministic preview failure")

  static var summaries: [ConversationSummary] {
    [
      ConversationSummary(
        id: id("9"),
        title: "Current market value by fund",
        startedAt: now.addingTimeInterval(-320),
        lastActivityAt: now.addingTimeInterval(-300),
        latestMessagePreview: answeredNarration,
        messageCount: 2),
      ConversationSummary(
        id: id("8"),
        title: "Lease expirations this year",
        startedAt: now.addingTimeInterval(-86_400),
        lastActivityAt: now.addingTimeInterval(-7_200),
        latestMessagePreview:
          "12 active leases at held properties expire before July 2027.",
        isUnread: true,
        messageCount: 6),
      ConversationSummary(
        id: id("7"),
        title: "Debt maturities",
        startedAt: now.addingTimeInterval(-260_000),
        lastActivityAt: now.addingTimeInterval(-172_800),
        latestMessagePreview:
          "Three loans mature in the next 24 months, totaling $84.2M.",
        messageCount: 4),
    ]
  }

  static func appState(
    revealed: Bool,
    chat: ChatFeature.State
  ) -> AppFeature.State {
    var state = AppFeature.State(
      debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    state.conversations = IdentifiedArray(uniqueElements: summaries)
    state.chat = chat
    state.isBrowserRevealed = revealed
    state.modelReadiness = .ready
    return state
  }

  /// Settings with the icon picker visible. `supportsAlternateIcons` is false
  /// by default because the system answers it, and the preview store never
  /// runs the effect that would.
  static func settingsState(
    icon: AppIconVariant = .midnight
  ) -> AppFeature.State {
    var state = AppFeature.State(
      debugModelIdentity: nil, launchBenchmarkQuestion: nil)
    state.isSettingsPresented = true
    state.supportsAlternateIcons = true
    state.appIcon = icon
    return state
  }

  static func transientAppState() -> AppFeature.State {
    var state = appState(revealed: false, chat: answeredChatState())
    state.answerReadyBanner = AppFeature.AnswerReadyBanner(
      conversationID: summaries[1].id,
      title: summaries[1].displayTitle)
    state.pendingDeletion = AppFeature.PendingDeletion(
      summary: summaries[2], index: 2)
    return state
  }

  static var chrome: ChatChrome {
    ChatChrome(
      modelReadiness: .ready,
      modelPreparationReport: nil,
      developerMode: false,
      resultTableTextSize: .constant(.standard),
      hasUnreadElsewhere: true,
      debugModelIdentity: nil,
      presentedFailure: nil,
      dismissFailure: {},
      retryPreparation: {},
      retryCompatibilityPreparation: {})
  }

  /// An inert store: state renders, every action is ignored, and no
  /// dependency is ever touched.
  @MainActor
  static func chatStore(_ state: ChatFeature.State) -> StoreOf<ChatFeature> {
    Store(initialState: state) {}
  }

  @MainActor
  static func appStore(_ state: AppFeature.State) -> StoreOf<AppFeature> {
    Store(initialState: state) {}
  }
}
