import Darwin
import Foundation
import SpeakerProfileBenchmarkCore

// MARK: - SpeakerProfileBenchmarkCommand

enum SpeakerProfileBenchmarkCommand {
  static func run() {
    do {
      let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
      if options.showsHelp {
        write(Self.usage, to: .standardOutput)
        return
      }
      let dataset = try options.loadDataset()
      if let datasetOutputPath = options.datasetOutputPath {
        try encode(dataset).write(
          to: URL(fileURLWithPath: datasetOutputPath),
          options: .atomic
        )
        write("Wrote pseudonymized dataset to \(datasetOutputPath)\n", to: .standardError)
      }
      let report = try SpeakerProfileBenchmarkEngine.run(
        dataset: dataset,
        thresholds: options.thresholds,
        margin: options.margin
      )
      write(SpeakerProfileBenchmarkRenderer.markdown(report), to: .standardOutput)

      if let jsonOutputPath = options.jsonOutputPath {
        try encode(report).write(to: URL(fileURLWithPath: jsonOutputPath), options: .atomic)
        write("Wrote JSON report to \(jsonOutputPath)\n", to: .standardError)
      }
    } catch {
      write("Error: \(error.localizedDescription)\n\n\(usage)", to: .standardError)
      exit(EXIT_FAILURE)
    }
  }

  private static let usage = """
  Usage:
    SpeakerProfileBenchmark <dataset.json> [options]

  Options:
    --recordings-index <path>
                           Import Jingo recordings with manually confirmed speakers.
                           Names and meeting IDs are replaced with pseudonyms.
    --export-dataset <path>
                           Save the imported pseudonymized embedding dataset.
    --thresholds <values>  Comma-separated similarity thresholds.
                           Default: 0.60,0.70,0.75,0.80,0.82,0.85,0.90
    --margin <value>       Minimum separation from the runner-up. Default: 0.05
    --json-output <path>   Also write the complete machine-readable report.
    --help                 Show this help.

  The input contains embeddings and pseudonymous labels only; raw audio is not required.
  """

  private static func write(_ text: String, to handle: FileHandle) {
    guard let data = text.data(using: .utf8) else {
      return
    }
    handle.write(data)
  }

  private static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

// MARK: - Options

private struct Options {
  var datasetPath: String?
  var recordingsIndexPath: String?
  var datasetOutputPath: String?
  var thresholds = SpeakerProfileBenchmarkEngine.defaultThresholds
  var margin = SpeakerProfileMatcher.defaultMinimumMargin
  var jsonOutputPath: String?
  var showsHelp = false

  init(arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--help", "-h":
        showsHelp = true

      case "--thresholds":
        index += 1
        guard index < arguments.count else {
          throw CommandError.missingValue(argument)
        }
        thresholds = try Self.parseThresholds(arguments[index])

      case "--recordings-index":
        index += 1
        guard index < arguments.count else {
          throw CommandError.missingValue(argument)
        }
        recordingsIndexPath = arguments[index]

      case "--export-dataset":
        index += 1
        guard index < arguments.count else {
          throw CommandError.missingValue(argument)
        }
        datasetOutputPath = arguments[index]

      case "--margin":
        index += 1
        guard index < arguments.count, let value = Float(arguments[index]) else {
          throw CommandError.invalidValue(argument)
        }
        margin = value

      case "--json-output":
        index += 1
        guard index < arguments.count else {
          throw CommandError.missingValue(argument)
        }
        jsonOutputPath = arguments[index]

      default:
        guard !argument.hasPrefix("-") else {
          throw CommandError.unknownOption(argument)
        }
        guard datasetPath == nil else {
          throw CommandError.multipleDatasets
        }
        datasetPath = argument
      }
      index += 1
    }
  }

  func loadDataset() throws -> SpeakerProfileBenchmarkDataset {
    if datasetPath == nil, recordingsIndexPath == nil {
      throw CommandError.missingDataset
    }
    guard (datasetPath == nil) != (recordingsIndexPath == nil) else {
      throw CommandError.invalidDatasetSource
    }
    if let recordingsIndexPath {
      let data = try Data(contentsOf: URL(fileURLWithPath: recordingsIndexPath))
      return try SpeakerProfileBenchmarkRecordingImporter.dataset(from: data)
    }
    guard let datasetPath else {
      throw CommandError.missingDataset
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: datasetPath))
    return try JSONDecoder().decode(SpeakerProfileBenchmarkDataset.self, from: data)
  }

  private static func parseThresholds(_ value: String) throws -> [Float] {
    let parsed = value.split(separator: ",").compactMap {
      Float($0.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard !parsed.isEmpty, parsed.count == value.split(separator: ",").count else {
      throw CommandError.invalidValue("--thresholds")
    }
    return parsed
  }
}

// MARK: - CommandError

private enum CommandError: LocalizedError {
  case invalidDatasetSource
  case invalidValue(String)
  case missingDataset
  case missingValue(String)
  case multipleDatasets
  case unknownOption(String)

  var errorDescription: String? {
    switch self {
    case .invalidDatasetSource:
      "Provide either one dataset path or --recordings-index, but not both."

    case let .invalidValue(option):
      "Invalid value for \(option)."

    case .missingDataset:
      "Provide a benchmark dataset path."

    case let .missingValue(option):
      "Missing value for \(option)."

    case .multipleDatasets:
      "Provide exactly one benchmark dataset."

    case let .unknownOption(option):
      "Unknown option \(option)."
    }
  }
}

SpeakerProfileBenchmarkCommand.run()
