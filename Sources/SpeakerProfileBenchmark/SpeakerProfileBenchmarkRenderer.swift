import Foundation

public enum SpeakerProfileBenchmarkRenderer {
  public static func markdown(_ report: SpeakerProfileBenchmarkReport) -> String {
    var lines = [
      "# Speaker profile benchmark",
      "",
      "Observations: \(report.dataset.observations) · Evaluations: \(report.dataset.evaluations) · "
        + "Enrollments: \(report.dataset.enrollments) · Speakers: \(report.dataset.speakers) · "
        + "Meetings: \(report.dataset.meetings)",
      "",
      "Matching margin: \(decimal(report.margin))",
      "",
      "| Threshold | Legacy known ID | Bank known ID | Change | Legacy wrong name | Bank wrong name | Legacy false accept | Bank false accept |",
      "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for run in report.runs {
      let legacy = run.legacyAverage.metrics
      let bank = run.representativeBank.metrics
      lines.append(
        "| \(decimal(run.threshold)) "
          + "| \(percent(legacy.knownIdentificationRate)) "
          + "| \(percent(bank.knownIdentificationRate)) "
          + "| \(signedPercent(bank.knownIdentificationRate - legacy.knownIdentificationRate)) "
          + "| \(percent(legacy.misidentificationRate)) "
          + "| \(percent(bank.misidentificationRate)) "
          + "| \(percent(legacy.falseAcceptanceRate)) "
          + "| \(percent(bank.falseAcceptanceRate)) |"
      )
    }

    if let highlightedRun = report.runs.min(by: {
      abs($0.threshold - SpeakerProfileMatcher.defaultMinimumSimilarity)
        < abs($1.threshold - SpeakerProfileMatcher.defaultMinimumSimilarity)
    }) {
      appendDetails(highlightedRun, to: &lines)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func appendDetails(
    _ run: SpeakerProfileBenchmarkRun,
    to lines: inout [String]
  ) {
    let legacy = run.legacyAverage
    let bank = run.representativeBank
    lines.append(contentsOf: [
      "",
      "## Detail at threshold \(decimal(run.threshold))",
      "",
      "| Method | Correct known | Wrong known | Rejected known | Rejected unknown | Accepted unknown | Active samples | Pending samples |",
      "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
      detailRow("Legacy average", result: legacy),
      detailRow("Representative bank", result: bank),
      "",
      "Representative-bank learning: \(bank.learning.created) created, "
        + "\(bank.learning.addedCoverage) added coverage, \(bank.learning.duplicate) duplicates ignored, "
        + "\(bank.learning.pending) held pending.",
    ])

    guard !run.conditionSlices.isEmpty else {
      return
    }
    lines.append(contentsOf: [
      "",
      "## Conditions at threshold \(decimal(run.threshold))",
      "",
      "| Condition | Evaluations | Legacy known ID | Bank known ID | Legacy wrong name | Bank wrong name |",
      "| --- | ---: | ---: | ---: | ---: | ---: |",
    ])
    for slice in run.conditionSlices {
      lines.append(
        "| \(slice.condition) "
          + "| \(slice.legacyAverage.evaluations) "
          + "| \(percent(slice.legacyAverage.knownIdentificationRate)) "
          + "| \(percent(slice.representativeBank.knownIdentificationRate)) "
          + "| \(percent(slice.legacyAverage.misidentificationRate)) "
          + "| \(percent(slice.representativeBank.misidentificationRate)) |"
      )
    }
  }

  private static func detailRow(
    _ name: String,
    result: SpeakerProfileBenchmarkAlgorithmResult
  ) -> String {
    let metrics = result.metrics
    return "| \(name) | \(metrics.correctKnown) | \(metrics.wrongKnown) | \(metrics.rejectedKnown) "
      + "| \(metrics.rejectedUnknown) | \(metrics.acceptedUnknown) | \(result.finalActiveSamples) "
      + "| \(result.finalPendingSamples) |"
  }

  private static func decimal(_ value: Float) -> String {
    String(format: "%.2f", value)
  }

  private static func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
  }

  private static func signedPercent(_ value: Double) -> String {
    String(format: "%+.1f pp", value * 100)
  }
}
