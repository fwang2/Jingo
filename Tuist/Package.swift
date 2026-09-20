// swift-tools-version: 5.10
import PackageDescription

#if TUIST
  import ProjectDescription

  let packageSettings = PackageSettings(
    baseSettings: .settings(
      base: ["MACOSX_DEPLOYMENT_TARGET": "13.0"]
    )
  )
#endif

let package = Package(
  name: "JingoDependencies",
  dependencies: [
    .package(url: "https://github.com/krzysztofzablocki/Inject.git", branch: "main"),

    .package(url: "https://github.com/aheze/Popovers.git", from: "1.3.2"),
    .package(url: "https://github.com/AudioKit/AudioKit.git", from: "5.6.0"),
    .package(url: "https://github.com/dmrschmidt/DSWaveformImage.git", from: "14.2.2"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", exact: "1.26.2"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.17.1"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.5"),
    .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.1.2"),
    .package(url: "https://github.com/yannickl/DynamicColor.git", from: "5.0.1"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    .package(url: "https://github.com/Cindori/FluidGradient.git", from: "1.0.0"),
    .package(
      url: "https://github.com/Blaizzy/mlx-audio-swift.git",
      revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"
    ),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    .package(url: "https://github.com/kean/PulseLogHandler.git", from: "4.0.1"),
    .package(url: "https://github.com/EmergeTools/Pow.git", exact: "1.0.6"),
    .package(url: "https://github.com/rollbar/rollbar-apple", from: "3.2.0"),
  ]
)
