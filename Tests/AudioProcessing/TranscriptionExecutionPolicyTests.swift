@testable import AudioProcessing
import XCTest

final class TranscriptionExecutionPolicyTests: XCTestCase {
  func testResourceConstrainedPolicyReleasesAuxiliaryModelsAndRunsSequentially() {
    let policy = TranscriptionExecutionPolicy.resourceConstrained

    XCTAssertFalse(policy.keepsAuxiliaryModelsResident)
    XCTAssertFalse(policy.runsDiarizationAlongsideTranscription)
  }

  func testHighPerformancePolicyKeepsModelsResidentAndAllowsConcurrency() {
    let policy = TranscriptionExecutionPolicy.highPerformance

    XCTAssertTrue(policy.keepsAuxiliaryModelsResident)
    XCTAssertTrue(policy.runsDiarizationAlongsideTranscription)
  }

  func testAutomaticPolicyUsesResourceConstrainedExecutionOnIOS() {
    XCTAssertEqual(TranscriptionExecutionPolicy.automatic, .resourceConstrained)
  }
}
