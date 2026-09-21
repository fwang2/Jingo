import Foundation

// MARK: - SpeakerAttributionWord

struct SpeakerAttributionWord: Equatable, Sendable {
  let text: String
  let startTimeMS: Int64
  let endTimeMS: Int64
}

// MARK: - SpeakerAttributionInterval

struct SpeakerAttributionInterval: Equatable, Sendable {
  let speakerID: String
  let startTimeMS: Int64
  let endTimeMS: Int64
}

// MARK: - SpeakerAttributionTurn

struct SpeakerAttributionTurn: Equatable, Sendable {
  let speakerID: String?
  let startTimeMS: Int64
  let endTimeMS: Int64
  let text: String
  let words: [SpeakerAttributionWord]
}

// MARK: - SpeakerAttributionCore

enum SpeakerAttributionCore {
  private static let maximumSpeakerGapMS: Int64 = 750
  private static let longPauseMS: Int64 = 1200
  private static let minimumAlignmentCoverage = 0.70
  private static let sentenceEndingPunctuation: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
  private static let boundaryPunctuation: Set<Character> = [
    ".", ",", "!", "?", ";", ":", "…", "。", "，", "、", "！", "？", "；", "：",
  ]
  private static let closingCharacters: Set<Character> = [
    "\"", "'", "’", "”", ")", "]", "}", "）", "】", "》", "」", "』",
  ]

  static func merge(
    transcript: String,
    words: [SpeakerAttributionWord],
    speakerIntervals: [SpeakerAttributionInterval]
  ) -> [SpeakerAttributionTurn] {
    guard !words.isEmpty else { return [] }

    let projectedText = projectTranscriptText(transcript, onto: words)
    let attributedWords = restoreSparsePunctuation(
      in: fillUnassignedSpeakerIDs(in: zip(words, projectedText).map { word, displayText in
        let speakerID = speakerID(for: word, in: speakerIntervals)
        return AttributedWord(
          word: word,
          displayText: displayText,
          speakerID: speakerID,
          hasDirectSpeakerID: speakerID != nil
        )
      })
    )

    var groupedWords: [[AttributedWord]] = []
    for word in attributedWords {
      if !groupedWords.isEmpty, groupedWords.last?.last?.speakerID == word.speakerID {
        groupedWords[groupedWords.count - 1].append(word)
      } else {
        groupedWords.append([word])
      }
    }

    return groupedWords.compactMap { words in
      guard let first = words.first, let last = words.last else { return nil }
      let text = words.map(\.displayText)
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }

      return SpeakerAttributionTurn(
        speakerID: first.speakerID,
        startTimeMS: first.word.startTimeMS,
        endTimeMS: last.word.endTimeMS,
        text: text,
        words: words.map(\.word)
      )
    }
  }

  static func joinTranscript(_ turnTexts: [String]) -> String {
    turnTexts.reduce(into: "") { result, rawText in
      let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      guard !result.isEmpty else {
        result = text
        return
      }
      let separator = needsSpaceAtBoundary(between: result, and: text) ? " " : ""
      result += separator + text
    }
  }

  static func hasSufficientAlignmentCoverage(
    transcript: String,
    alignedWordTexts: [String]
  ) -> Bool {
    let transcriptCharacterCount = contentCharacterCount(in: transcript)
    guard transcriptCharacterCount > 0, !alignedWordTexts.isEmpty else { return false }

    var matchedCharacterCount = 0
    var searchStart = transcript.startIndex
    for rawWord in alignedWordTexts {
      let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !word.isEmpty,
            searchStart < transcript.endIndex,
            let range = transcript.range(
              of: word,
              options: [.caseInsensitive, .diacriticInsensitive],
              range: searchStart ..< transcript.endIndex
            )
      else {
        continue
      }
      matchedCharacterCount += contentCharacterCount(in: String(transcript[range]))
      searchStart = range.upperBound
    }

    return Double(matchedCharacterCount) / Double(transcriptCharacterCount)
      >= minimumAlignmentCoverage
  }

  private static func speakerID(
    for word: SpeakerAttributionWord,
    in speakerIntervals: [SpeakerAttributionInterval]
  ) -> String? {
    var bestInterval: SpeakerAttributionInterval?
    var bestOverlap: Int64 = 0
    var bestMidpointDistance = Double.greatestFiniteMagnitude
    let wordMidpoint = Double(word.startTimeMS + word.endTimeMS) / 2

    for interval in speakerIntervals {
      let overlap = max(
        0,
        min(word.endTimeMS, interval.endTimeMS) - max(word.startTimeMS, interval.startTimeMS)
      )
      let intervalMidpoint = Double(interval.startTimeMS + interval.endTimeMS) / 2
      let midpointDistance = abs(wordMidpoint - intervalMidpoint)

      if overlap > bestOverlap || (overlap == bestOverlap && overlap > 0 && midpointDistance < bestMidpointDistance) {
        bestInterval = interval
        bestOverlap = overlap
        bestMidpointDistance = midpointDistance
      }
    }

    if let bestInterval, bestOverlap > 0 {
      return bestInterval.speakerID
    }

    let nearestInterval = speakerIntervals.min { lhs, rhs in
      intervalDistance(from: word, to: lhs) < intervalDistance(from: word, to: rhs)
    }
    guard let nearestInterval,
          intervalDistance(from: word, to: nearestInterval) <= maximumSpeakerGapMS
    else {
      return nil
    }
    return nearestInterval.speakerID
  }

  private static func intervalDistance(
    from word: SpeakerAttributionWord,
    to interval: SpeakerAttributionInterval
  ) -> Int64 {
    if word.endTimeMS < interval.startTimeMS {
      return interval.startTimeMS - word.endTimeMS
    }
    if interval.endTimeMS < word.startTimeMS {
      return word.startTimeMS - interval.endTimeMS
    }
    return 0
  }

  private static func fillUnassignedSpeakerIDs(
    in words: [AttributedWord]
  ) -> [AttributedWord] {
    guard let firstIdentifiedIndex = words.firstIndex(where: { $0.speakerID != nil }) else {
      return words
    }

    var result = words
    let firstSpeakerID = result[firstIdentifiedIndex].speakerID
    for index in result.indices where index < firstIdentifiedIndex {
      result[index].speakerID = firstSpeakerID
    }

    var previousIdentifiedIndex = firstIdentifiedIndex
    for nextIdentifiedIndex in result.indices.dropFirst(firstIdentifiedIndex + 1)
      where result[nextIdentifiedIndex].speakerID != nil {
      if nextIdentifiedIndex > previousIdentifiedIndex + 1 {
        let previousMidpoint = wordMidpoint(result[previousIdentifiedIndex].word)
        let nextMidpoint = wordMidpoint(result[nextIdentifiedIndex].word)
        for index in (previousIdentifiedIndex + 1) ..< nextIdentifiedIndex {
          let midpoint = wordMidpoint(result[index].word)
          result[index].speakerID = midpoint - previousMidpoint <= nextMidpoint - midpoint
            ? result[previousIdentifiedIndex].speakerID
            : result[nextIdentifiedIndex].speakerID
        }
      }
      previousIdentifiedIndex = nextIdentifiedIndex
    }

    if previousIdentifiedIndex < result.index(before: result.endIndex) {
      for index in result.indices where index > previousIdentifiedIndex {
        result[index].speakerID = result[previousIdentifiedIndex].speakerID
      }
    }
    return result
  }

  private static func wordMidpoint(_ word: SpeakerAttributionWord) -> Double {
    Double(word.startTimeMS + word.endTimeMS) / 2
  }

  private static func restoreSparsePunctuation(
    in words: [AttributedWord]
  ) -> [AttributedWord] {
    guard !words.isEmpty else { return words }

    let boundaryIndices = words.indices.filter { index in
      guard index < words.index(before: words.endIndex) else { return true }
      let nextIndex = words.index(after: index)
      return words[index].speakerID != words[nextIndex].speakerID
        || (words[index].hasDirectSpeakerID
          && words[nextIndex].hasDirectSpeakerID
          && words[nextIndex].word.startTimeMS - words[index].word.endTimeMS >= longPauseMS)
    }
    let existingSentenceEndings = boundaryIndices.count { index in
      hasTrailingPunctuation(
        in: words[index].displayText,
        punctuation: sentenceEndingPunctuation
      )
    }

    // Only intervene when Qwen omitted most expected sentence boundaries.
    guard existingSentenceEndings * 2 < boundaryIndices.count else { return words }

    var result = words
    for index in boundaryIndices where !hasTrailingPunctuation(
      in: result[index].displayText,
      punctuation: boundaryPunctuation
    ) {
      let punctuation: Character = result[index].word.text.containsCJKCharacter ? "。" : "."
      result[index].displayText = insertingTerminalPunctuation(
        punctuation,
        into: result[index].displayText
      )
    }
    return result
  }

  private static func hasTrailingPunctuation(
    in text: String,
    punctuation: Set<Character>
  ) -> Bool {
    guard let contentEnd = trailingContentEnd(in: text), contentEnd > text.startIndex else {
      return false
    }
    return punctuation.contains(text[text.index(before: contentEnd)])
  }

  private static func insertingTerminalPunctuation(
    _ punctuation: Character,
    into text: String
  ) -> String {
    guard let insertionIndex = trailingContentEnd(in: text) else { return text }
    return String(text[..<insertionIndex]) + String(punctuation) + String(text[insertionIndex...])
  }

  private static func trailingContentEnd(in text: String) -> String.Index? {
    var index = text.endIndex
    while index > text.startIndex {
      let previousIndex = text.index(before: index)
      guard text[previousIndex].isWhitespace else { break }
      index = previousIndex
    }
    while index > text.startIndex {
      let previousIndex = text.index(before: index)
      guard closingCharacters.contains(text[previousIndex]) else { break }
      index = previousIndex
    }
    return index
  }

  private static func projectTranscriptText(
    _ transcript: String,
    onto words: [SpeakerAttributionWord]
  ) -> [String] {
    var ranges: [Range<String.Index>] = []
    var searchStart = transcript.startIndex

    for word in words {
      guard searchStart < transcript.endIndex,
            let range = transcript.range(
              of: word.text,
              options: [.caseInsensitive, .diacriticInsensitive],
              range: searchStart ..< transcript.endIndex
            )
      else {
        return fallbackProjectedText(for: words)
      }
      ranges.append(range)
      searchStart = range.upperBound
    }

    return ranges.indices.map { index in
      let range = ranges[index]
      let unmatchedPrefix = transcript[..<range.lowerBound]
      let start = index == ranges.startIndex && !containsContent(in: unmatchedPrefix)
        ? transcript.startIndex
        : range.lowerBound
      let limit = index + 1 < ranges.endIndex ? ranges[index + 1].lowerBound : transcript.endIndex
      let end = trailingNonContentEnd(
        in: transcript,
        after: range.upperBound,
        before: limit
      )
      return String(transcript[start ..< end])
    }
  }

  private static func trailingNonContentEnd(
    in text: String,
    after start: String.Index,
    before limit: String.Index
  ) -> String.Index {
    var index = start
    while index < limit {
      let nextIndex = text.index(after: index)
      guard !containsContent(in: text[index ..< nextIndex]) else { break }
      index = nextIndex
    }
    return index
  }

  private static func contentCharacterCount(in text: String) -> Int {
    text.unicodeScalars.count(where: CharacterSet.alphanumerics.contains)
  }

  private static func containsContent(in text: some StringProtocol) -> Bool {
    text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
  }

  private static func fallbackProjectedText(for words: [SpeakerAttributionWord]) -> [String] {
    words.indices.map { index in
      guard index + 1 < words.endIndex else { return words[index].text }
      let separator = needsSpace(between: words[index].text, and: words[index + 1].text) ? " " : ""
      return words[index].text + separator
    }
  }

  private static func needsSpace(between lhs: String, and rhs: String) -> Bool {
    !lhs.containsCJKCharacter && !rhs.containsCJKCharacter
  }

  private static func needsSpaceAtBoundary(between lhs: String, and rhs: String) -> Bool {
    guard let lhsCharacter = lhs.last(where: { !$0.isWhitespace }),
          let rhsCharacter = rhs.first(where: { !$0.isWhitespace })
    else {
      return false
    }
    return !String(lhsCharacter).containsCJKCharacter
      && !String(rhsCharacter).containsCJKCharacter
  }
}

// MARK: - AttributedWord

private struct AttributedWord {
  let word: SpeakerAttributionWord
  var displayText: String
  var speakerID: String?
  let hasDirectSpeakerID: Bool
}

// MARK: - String + CJK

private extension String {
  var containsCJKCharacter: Bool {
    unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2CEAF:
        true
      default:
        false
      }
    }
  }
}
