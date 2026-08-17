import CREGCore
import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

extension MLXSQLGenerator {
  func loadedContainer() async throws -> ModelContainer {
    let source = self.source
    if let metalCommandBufferLimitMB {
      guard
        setenv(
          "MLX_MAX_MB_PER_BUFFER",
          String(metalCommandBufferLimitMB),
          1)
          == 0
      else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
      }
    } else if runtimeMode == .compatibility {
      unsetenv("MLX_MAX_MB_PER_BUFFER")
    }
    return try await containerLoader.value {
      MLX.Memory.cacheLimit = 20 * 1024 * 1024
      switch source {
      case .directory(let url):
        if self.compiledQwen2MLPFusion {
          return try await CompiledQwen2ModelFactory.make(
            verificationMLPSkipLayers: self.verificationMLPSkipLayers,
            verificationMLPLongBatchExtraSkipLayers:
              self.verificationMLPLongBatchExtraSkipLayers
          ).loadContainer(
            from: url,
            using: HuggingFaceTokenizerLoader())
        }
        return try await loadModelContainer(
          from: url,
          using: HuggingFaceTokenizerLoader())
      }
    }
  }

  func preparedCompiledQwen2QKVFusion(
    using container: ModelContainer
  ) async throws {
    guard compiledQwen2QKVVerificationFusion,
      !didPrepareCompiledQwen2QKVFusion
    else { return }
    let prepared = await container.perform { context in
      CompiledQwen2ModelFactory.prepareFusedQKVVerificationProjections(
        in: context.model)
    }
    guard prepared else {
      throw CocoaError(.featureUnsupported)
    }
    didPrepareCompiledQwen2QKVFusion = true
  }

  /// Builds the longest token prefix shared by two deliberately different
  /// user messages. The prefix therefore includes the static system/schema
  /// prompt and chat-template user header, but no user-controlled content.
  /// Prefilling it during app preparation moves that work outside the query
  /// deadline while retaining the processor's exact tokenization.
  func preparedPromptPrefixCache(
    using container: ModelContainer
  ) async throws -> MLXPromptPrefixCache? {
    guard enablePromptPrefixCache else { return nil }
    if let promptPrefixCache { return promptPrefixCache }

    let systemContent = Self.systemPrompt(schema: try Self.schemaPrompt())
    let built: MLXPromptPrefixCache? = try await container.perform {
      (context: ModelContext) async throws -> MLXPromptPrefixCache? in
      let probeUsers = [
        "",
        "A",
        "Z",
        " leading whitespace and punctuation: ; ?",
        "multiline\nquoted 'value' and <|im_end|>-shaped text",
        "Unicode λ boundary probe",
      ]
      var tokenSequences: [[Int]] = []
      for user in probeUsers {
        let input = try await context.processor.prepare(
          input: UserInput(chat: [
            .system(systemContent),
            .user(user),
          ]))
        tokenSequences.append(input.text.tokens.asArray(Int.self))
      }
      guard let firstTokens = tokenSequences.first else { return nil }
      let prefixCount = tokenSequences.dropFirst().reduce(firstTokens.count) {
        min($0, Self.commonPrefixLength(firstTokens, $1))
      }
      guard prefixCount > 0 else { return nil }

      let prefixTokens = Array(firstTokens.prefix(prefixCount))
      let suffixCount = tokenSequences.dropFirst().reduce(
        firstTokens.count - prefixCount
      ) {
        min(
          $0,
          Self.commonSuffixLength(
            firstTokens,
            $1,
            excludingPrefixCount: prefixCount))
      }
      let suffixTokens = Array(firstTokens.suffix(suffixCount))
      let directSuffixIsExact = zip(probeUsers, tokenSequences).allSatisfy {
        user, tokens in
        prefixTokens
          + context.tokenizer.encode(text: user, addSpecialTokens: false)
          + suffixTokens == tokens
      }
      let prefixInput = LMInput(tokens: MLXArray(prefixTokens))
      let parameters = GenerateParameters(maxTokens: 1)
      let cache = context.model.newCache(parameters: parameters)
      switch try context.model.prepare(
        prefixInput,
        cache: cache,
        windowSize: parameters.prefillStepSize)
      {
      case .tokens(let tokens):
        let output = context.model(
          tokens[text: .newAxis],
          cache: cache.isEmpty ? nil : cache,
          state: nil)
        eval(output.logits)
      case .logits(let output):
        eval(output.logits)
      }
      return MLXPromptPrefixCache(
        tokens: prefixTokens,
        suffixTokens: directSuffixIsExact ? suffixTokens : nil,
        cache: cache)
    }
    promptPrefixCache = built
    return built
  }

  func preparedNGramDraftModel(
    using container: ModelContainer
  ) async throws -> SQLNGramPredictor? {
    guard ngramDraftTokens > 0 else { return nil }
    if let ngramDraftModel { return ngramDraftModel }

    let corpus =
      if let productionNGramSpeculation {
        try SQLGenClient.productionDraftCorpus(
          policy: productionNGramSpeculation)
      } else {
        experimentalNGramDraftCorpus
      }
    guard !corpus.isEmpty else { return nil }
    let built = await container.perform { context in
      let eosToken = context.tokenizer.eosTokenId
      let sequences = corpus.map { sql in
        var tokens = context.tokenizer.encode(
          text: sql,
          addSpecialTokens: false)
        if let eosToken { tokens.append(eosToken) }
        return tokens
      }
      return SQLNGramPredictor(sequences: sequences, order: ngramOrder)
    }
    ngramDraftModel = built
    return built
  }

  func preparedQuestionOutputVocabulary(
    using container: ModelContainer
  ) async throws -> SQLQuestionOutputVocabulary? {
    guard questionAwareOutputHead else { return nil }
    if let questionOutputVocabulary { return questionOutputVocabulary }

    let corpus =
      if let productionNGramSpeculation {
        try SQLGenClient.productionDraftCorpus(
          policy: productionNGramSpeculation)
      } else {
        experimentalNGramDraftCorpus
      }
    guard !corpus.isEmpty else { return nil }
    let lexicalSources = [try Self.grammarEBNF(), try Self.schemaPrompt()]
    let built = await container.perform { context in
      guard
        let vocabularySize = CompiledQwen2ModelFactory.vocabularySize(
          of: context.model)
      else { return nil as SQLQuestionOutputVocabulary? }
      let vocabulary = SQLQuestionOutputVocabulary(
        vocabularySize: vocabularySize,
        tokenizer: context.tokenizer,
        draftCorpus: corpus,
        lexicalSources: lexicalSources,
        stopStrings: context.configuration.effectiveStopStrings)
      let warmupTokenIDs = vocabulary.allowedTokenIDs(
        for: "Question: warm up SQL output projection")
      if let model = CompiledQwen2ModelFactory.restricting(
        context.model,
        to: warmupTokenIDs)
      {
        let token = context.tokenizer.eosTokenId ?? 0
        for tokens in [[token], [token, token]] {
          let input = MLXArray(tokens).reshaped([1, -1])
          let cache = model.newCache(
            parameters: GenerateParameters(maxTokens: 1))
          eval(model(input, cache: cache))
        }
      }
      return vocabulary
    }
    questionOutputVocabulary = built
    return built
  }

  private nonisolated static func commonPrefixLength(
    _ lhs: [Int],
    _ rhs: [Int]
  ) -> Int {
    var index = 0
    let limit = min(lhs.count, rhs.count)
    while index < limit, lhs[index] == rhs[index] {
      index += 1
    }
    return index
  }

  private nonisolated static func commonSuffixLength(
    _ lhs: [Int],
    _ rhs: [Int],
    excludingPrefixCount prefixCount: Int
  ) -> Int {
    var count = 0
    let limit = min(lhs.count, rhs.count) - prefixCount
    while count < limit,
      lhs[lhs.count - count - 1] == rhs[rhs.count - count - 1]
    {
      count += 1
    }
    return count
  }

  nonisolated static func applyingDirectPromptSuffix(
    _ prefix: MLXPromptPrefixCache?,
    userContent: String,
    tokenizer: any MLXLMCommon.Tokenizer
  ) -> (LMInput, [KVCache]?, Int)? {
    guard let prefix, let suffixTokens = prefix.suffixTokens else {
      return nil
    }
    let userTokens = tokenizer.encode(
      text: userContent,
      addSpecialTokens: false)
    return (
      LMInput(tokens: MLXArray(userTokens + suffixTokens)),
      prefix.cache.map { $0.copy() },
      prefix.tokens.count
    )
  }

  /// Returns the unchanged input when a tokenizer/model does not share the
  /// prepared prefix. This keeps directory-based evaluation compatible with
  /// arbitrary supported model families.
  nonisolated static func applyingPromptPrefixCache(
    _ prefix: MLXPromptPrefixCache?,
    to input: LMInput
  ) -> (LMInput, [KVCache]?, Int) {
    guard let prefix else { return (input, nil, 0) }
    let tokens = input.text.tokens.asArray(Int.self)
    guard tokens.count > prefix.tokens.count,
      tokens.starts(with: prefix.tokens)
    else {
      return (input, nil, 0)
    }
    let remainder = Array(tokens.dropFirst(prefix.tokens.count))
    return (
      LMInput(tokens: MLXArray(remainder)),
      prefix.cache.map { $0.copy() },
      prefix.tokens.count
    )
  }
}
