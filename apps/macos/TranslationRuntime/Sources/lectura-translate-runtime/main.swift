import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// Minimal CLI contract, mirrors the existing mlx-audio-swift-tts external runtime pattern
// (ModelServices.swift Process() invocation): --model <dir> --source-language <tag>
// --target-language <tag> --text <string> --output <path>. Writes translated UTF-8 text
// to --output, or exits non-zero with a message to stderr on failure.

struct Arguments {
  var modelDirectory: URL
  var sourceLanguage: String
  var targetLanguage: String
  var text: String
  var outputPath: URL
}

func parseArguments() -> Arguments? {
  var modelDirectory: String?
  var sourceLanguage: String?
  var targetLanguage: String?
  var text: String?
  var outputPath: String?

  var iterator = CommandLine.arguments.dropFirst().makeIterator()
  while let flag = iterator.next() {
    guard let value = iterator.next() else { return nil }
    switch flag {
    case "--model": modelDirectory = value
    case "--source-language": sourceLanguage = value
    case "--target-language": targetLanguage = value
    case "--text": text = value
    case "--output": outputPath = value
    default: return nil
    }
  }
  guard let modelDirectory, let sourceLanguage, let targetLanguage, let text, let outputPath
  else { return nil }
  return Arguments(
    modelDirectory: URL(fileURLWithPath: modelDirectory),
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
    text: text,
    outputPath: URL(fileURLWithPath: outputPath))
}

guard let arguments = parseArguments() else {
  FileHandle.standardError.write(
    Data(
      "usage: lectura-translate-runtime --model <dir> --source-language <tag> --target-language <tag> --text <string> --output <path>\n"
        .utf8))
  exit(64)
}

/// `MLXLMCommon.Tokenizer` requires an integration package to supply a concrete
/// implementation (see BenchmarkHelpers.NoOpTokenizerLoader upstream comment: "Integration
/// packages inject their own Downloader and TokenizerLoader"). This adapts swift-transformers'
/// `PreTrainedTokenizer`, loaded purely from local files (no network), to that protocol.
struct TransformersTokenizerLoader: TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let hub = HubApi.shared
    let tokenizerConfig = try hub.configuration(
      fileURL: directory.appending(path: "tokenizer_config.json"))
    let tokenizerData = try hub.configuration(fileURL: directory.appending(path: "tokenizer.json"))
    let tokenizer = try PreTrainedTokenizer(
      tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
    // Some repos (e.g. mlx-community/translategemma-4b-it-4bit) ship the chat template as a
    // standalone chat_template.jinja file rather than embedding it in tokenizer_config.json's
    // "chat_template" key; PreTrainedTokenizer only reads the embedded key, so it must be
    // passed explicitly per call when the standalone file is present.
    let chatTemplatePath = directory.appending(path: "chat_template.jinja")
    let chatTemplate = try? String(contentsOf: chatTemplatePath, encoding: .utf8)
    return TransformersTokenizerAdapter(tokenizer: tokenizer, chatTemplateOverride: chatTemplate)
  }
}

struct TransformersTokenizerAdapter: MLXLMCommon.Tokenizer {
  let tokenizer: PreTrainedTokenizer
  let chatTemplateOverride: String?

  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
  }
  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }
  func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
  func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }
  var bosToken: String? { tokenizer.bosToken }
  var eosToken: String? { tokenizer.eosToken }
  var unknownToken: String? { tokenizer.unknownToken }

  func applyChatTemplate(
    messages: [[String: any Sendable]],
    tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    if let chatTemplateOverride {
      return try tokenizer.applyChatTemplate(
        messages: messages, chatTemplate: .literal(chatTemplateOverride), addGenerationPrompt: true,
        truncation: false, maxLength: nil, tools: tools, additionalContext: additionalContext)
    }
    return try tokenizer.applyChatTemplate(
      messages: messages, tools: tools, additionalContext: additionalContext)
  }
}

func translate(arguments: Arguments) async throws -> String {
  let container = try await LLMModelFactory.shared.loadContainer(
    from: arguments.modelDirectory, using: TransformersTokenizerLoader())

  let content: [[String: any Sendable]] = [
    [
      "type": "text",
      "source_lang_code": arguments.sourceLanguage,
      "target_lang_code": arguments.targetLanguage,
      "text": arguments.text,
    ]
  ]
  let message: [String: any Sendable] = ["role": "user", "content": content]
  let tokenizer = await container.tokenizer
  let tokens = try tokenizer.applyChatTemplate(
    messages: [message], tools: nil, additionalContext: nil)

  let input = LMInput(tokens: MLXArray(tokens))
  let stopSequence = "<end_of_turn>"
  let parameters = GenerateParameters(maxTokens: 512, temperature: 0)
  let stream = try await container.generate(input: input, parameters: parameters)

  var output = ""
  for await event in stream {
    if case .chunk(let text) = event {
      output += text
      if let range = output.range(of: stopSequence) {
        return String(output[output.startIndex..<range.lowerBound])
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
  }
  return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

do {
  let translated = try await translate(arguments: arguments)
  try translated.write(to: arguments.outputPath, atomically: true, encoding: .utf8)
} catch {
  FileHandle.standardError.write(Data("translation_failed: \(error)\n".utf8))
  exit(1)
}
// MLX's GPU stream/command-buffer teardown crashes (observed SIGSEGV) during atexit/static
// destructor unwinding — exit(0) still runs that chain. _exit(0) terminates immediately,
// skipping it entirely; output is already flushed to disk by the write() call above.
_exit(0)
