import Foundation
import ProjectDescription

public let version = "0.2"

public let deploymentTargetString = "18.0"
public let appDeploymentTargets: DeploymentTargets = .iOS(deploymentTargetString)
public let appDestinations: Destinations = [.iPhone, .iPad]
public let devTeam = "8A76N862C8"
private let personalDevelopmentTeam = "QRCC3F73AC"
private let personalDevelopmentBundleID = "com.feiyiwang.Jingo.Dev"
private let iCloudContainerIdentifier = "iCloud.me.igortarasenko.Jingo"

let isAppStore = Environment.isAppStore.getBoolean(default: false)
let additionalCondition = isAppStore ? "APPSTORE" : ""

let isRevealSupported = FileManager.default.fileExists(atPath: "App/Support/Reveal/RevealServer.xcframework") && !isAppStore
print("RevealServer.xcframework is \(isRevealSupported ? "supported" : "not supported")")
let isEttraceSupported = FileManager.default.fileExists(atPath: "App/Support/ETTrace.xcframework") && !isAppStore
print("ETTrace.xcframework is \(isEttraceSupported ? "supported" : "not supported")")

var appInfoPlist: [String: Plist.Value] = [
  "CFBundleDisplayName": "Jingo",
  "CFBundleShortVersionString": Plist.Value(stringLiteral: version),
  "CFBundleURLTypes": [
    [
      "CFBundleTypeRole": "Editor",
      "CFBundleURLName": .string("Jingo"),
      "CFBundleURLSchemes": [
        .string("whisperboard"),
      ],
    ],
  ],
  "UIApplicationSceneManifest": [
    "UIApplicationSupportsMultipleScenes": false,
    "UISceneConfigurations": [],
  ],
  "ITSAppUsesNonExemptEncryption": false,
  "UILaunchScreen": [
    "UILaunchScreen": [:],
  ],
  "UISupportedInterfaceOrientations": [
    "UIInterfaceOrientationPortrait",
  ],
  "UISupportedInterfaceOrientations~ipad": [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
  ],
  "NSMicrophoneUsageDescription": "Jingo uses the microphone to record voice and later transcribe it.",
  "UIUserInterfaceStyle": "Dark",
  "UIBackgroundModes": [
    "audio",
    "processing",
  ],
  "BGTaskSchedulerPermittedIdentifiers": [
    "$(PRODUCT_BUNDLE_IDENTIFIER)",
  ],
  "NSUbiquitousContainers": [
    iCloudContainerIdentifier: [
      "NSUbiquitousContainerIsDocumentScopePublic": true,
      "NSUbiquitousContainerName": "Jingo",
      "NSUbiquitousContainerSupportedFolderLevels": "Any",
    ],
  ],
]

if !isAppStore {
  appInfoPlist["NSLocalNetworkUsageDescription"] = Plist.Value.string("Network usage required for debugging purposes")
  appInfoPlist["NSBonjourServices"] = [Plist.Value.string("_pulse._tcp")]
}

let macInfoPlist: [String: Plist.Value] = [
  "CFBundleDisplayName": "Jingo",
  "CFBundleIconFile": "AppIcon",
  "CFBundleShortVersionString": Plist.Value(stringLiteral: version),
  "LSApplicationCategoryType": "public.app-category.productivity",
  "LSMultipleInstancesProhibited": true,
  "NSMicrophoneUsageDescription": "Jingo uses the microphone for offline live transcription.",
  "NSScreenCaptureUsageDescription": "Jingo captures audio played by this Mac for local meeting recording and transcription.",
]

let storeKitScheme: Scheme = .scheme(
  name: "Jingo",
  shared: true,
  buildAction: .buildAction(targets: ["Jingo"]),
  runAction: .runAction(
    configuration: "Debug",
    executable: "Jingo",
    options: .options(
      storeKitConfigurationPath: "App/Support/Jingo.storekit"
    )
  ),
  archiveAction: .archiveAction(configuration: "Release"),
  profileAction: .profileAction(configuration: "Release", executable: "Jingo"),
  analyzeAction: .analyzeAction(configuration: "Debug")
)

let macUITestScheme: Scheme = .scheme(
  name: "JingoMacUITests",
  shared: true,
  buildAction: .buildAction(targets: ["JingoMac", "JingoMacUITests"]),
  testAction: .targets(
    ["JingoMacTests", "JingoMacUITests"],
    configuration: .debug
  ),
  runAction: .runAction(
    configuration: .debug,
    executable: "JingoMac"
  )
)

let speakerProfileBenchmarkScheme: Scheme = .scheme(
  name: "SpeakerProfileBenchmark",
  shared: true,
  buildAction: .buildAction(targets: ["SpeakerProfileBenchmark"]),
  testAction: .targets(
    ["SpeakerProfileBenchmarkTests"],
    configuration: .debug
  ),
  runAction: .runAction(
    configuration: .debug,
    executable: "SpeakerProfileBenchmark"
  )
)

func createAppTarget(suffix: String = "", isDev: Bool = false, scripts: [TargetScript] = [], dependencies: [TargetDependency] = []) -> Target {
  var targetInfoPlist = appInfoPlist
  if isDev {
    targetInfoPlist.removeValue(forKey: "NSUbiquitousContainers")
  }

  return .target(
    name: "Jingo" + suffix,
    destinations: appDestinations,
    product: .app,
    bundleId: isDev ? personalDevelopmentBundleID : "com.feiyiwang.Jingo",
    deploymentTargets: appDeploymentTargets,
    infoPlist: .extendingDefault(with: targetInfoPlist),
    sources: "App/Sources/**",
    resources: .resources(
      ["App/Resources/**"],
      privacyManifest: .privacyManifest(
        tracking: false,
        trackingDomains: [],
        collectedDataTypes: [
          [
            "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeName",
            "NSPrivacyCollectedDataTypeLinked": false,
            "NSPrivacyCollectedDataTypeTracking": false,
            "NSPrivacyCollectedDataTypePurposes": [
              "NSPrivacyCollectedDataTypePurposeAppFunctionality",
            ],
          ],
        ],
        accessedApiTypes: [
          [
            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPITypeReasons": [
              "CA92.1",
            ],
          ],
        ]
      )
    ),
    entitlements: isDev ? nil : "App/Support/app.entitlements",
    scripts: scripts,

    dependencies: [.target(name: "JingoKit")]
      + (suffix.isEmpty ? [.target(name: "ShareExtension")] : [])
      + dependencies,

    settings: .settings(
      base: [
        "CODE_SIGN_STYLE": "Automatic",
        "MARKETING_VERSION": SettingValue(stringLiteral: version),
        "CODE_SIGN_IDENTITY": isDev ? "Apple Development" : "iPhone Developer",
        "CODE_SIGNING_REQUIRED": "YES",
        "DEVELOPMENT_TEAM": SettingValue(stringLiteral: isDev ? personalDevelopmentTeam : devTeam),
      ],
      debug: [
        "OTHER_SWIFT_FLAGS": "-D DEBUG $(inherited) -Xfrontend -warn-long-function-bodies=500 -Xfrontend -warn-long-expression-type-checking=500 -Xfrontend -debug-time-function-bodies -Xfrontend -debug-time-expression-type-checking -Xfrontend -enable-actor-data-race-checks",
        "OTHER_LDFLAGS": "-Xlinker -interposable $(inherited)",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "\(additionalCondition) \(isDev ? "DEV" : "") DEBUG",
      ],
      release: [
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "\(additionalCondition) \(isDev ? "DEV" : "")",
      ]
    )
  )
}

let macTargets: [Target] = [
  .target(
    name: "JingoMac",
    destinations: [.mac],
    product: .app,
    bundleId: "com.feiyiwang.Jingo",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .extendingDefault(with: macInfoPlist),
    sources: [
      "MacApp/Sources/**",
      "Sources/AudioProcessing/QwenStreamingTextCleaner.swift",
      "Sources/SharedTranscription/**",
    ],
    resources: ["MacApp/Resources/**"],
    entitlements: "MacApp/Support/JingoMac.entitlements",
    dependencies: [
      .external(name: "FluidAudio"),
      .external(name: "HuggingFace"),
      .external(name: "MLX"),
      .external(name: "MLXAudioCore"),
      .external(name: "MLXAudioSTT"),
      .external(name: "MLXAudioVAD"),
      .external(name: "MLXHuggingFace"),
      .external(name: "MLXLLM"),
      .external(name: "MLXLMCommon"),
      .external(name: "Tokenizers"),
      .target(name: "MeetingSummaryCore"),
      .target(name: "SpeakerProfileBenchmarkCore"),
    ],
    settings: .settings(
      base: [
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        // A certificate-backed identity lets macOS privacy grants survive local rebuilds.
        "CODE_SIGN_IDENTITY": "Apple Development",
        "CODE_SIGNING_REQUIRED": "YES",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": SettingValue(stringLiteral: personalDevelopmentTeam),
        "MARKETING_VERSION": SettingValue(stringLiteral: version),
        "OTHER_LDFLAGS": "$(inherited) -lc++",
        "PRODUCT_NAME": "Jingo",
      ]
    )
  ),
  .target(
    name: "JingoMacTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "com.feiyiwang.Jingo.MacTests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: [
      "Tests/MacAppTests/**",
      "MacApp/Sources/MacAudioCapture.swift",
      "MacApp/Sources/MacAudioInputDevice.swift",
      "MacApp/Sources/MacSpeechPhraseSegmenter.swift",
      "MacApp/Sources/MacICloudSettings.swift",
      "MacApp/Sources/MacMeetingDetector.swift",
      "MacApp/Sources/MacRecordingBackup.swift",
      "MacApp/Sources/MacRecordingRestore.swift",
      "MacApp/Sources/MacSyncFolderAccess.swift",
    ],
    dependencies: []
  ),
  .target(
    name: "JingoMacUITests",
    destinations: [.mac],
    product: .uiTests,
    bundleId: "com.feiyiwang.Jingo.MacUITests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: "Tests/MacAppUITests/**",
    dependencies: [
      .target(name: "JingoMac"),
    ]
  ),
  .target(
    name: "SpeakerProfileBenchmarkCore",
    destinations: [.mac],
    product: .staticFramework,
    bundleId: "com.feiyiwang.Jingo.SpeakerProfileBenchmarkCore",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: [
      "Sources/SpeakerProfileBenchmark/**",
      "Sources/SharedTranscription/SpeakerProfile.swift",
      "Sources/SharedTranscription/SpeakerProfileLearning.swift",
    ],
    dependencies: []
  ),
  .target(
    name: "SpeakerProfileBenchmark",
    destinations: [.mac],
    product: .commandLineTool,
    bundleId: "com.feiyiwang.Jingo.SpeakerProfileBenchmark",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: "Tools/SpeakerProfileBenchmark/**",
    dependencies: [
      .target(name: "SpeakerProfileBenchmarkCore"),
    ]
  ),
  .target(
    name: "SpeakerProfileBenchmarkTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "com.feiyiwang.Jingo.SpeakerProfileBenchmarkTests",
    deploymentTargets: .macOS("14.0"),
    infoPlist: .default,
    sources: "Tests/SpeakerProfileBenchmarkTests/**",
    resources: "TestResources/SpeakerProfileBenchmark/**",
    dependencies: [
      .target(name: "SpeakerProfileBenchmarkCore"),
    ]
  ),
]

let project = Project(
  name: "Jingo",

  options: .options(
    disableShowEnvironmentVarsInScriptPhases: true,
    textSettings: .textSettings(
      indentWidth: 2,
      tabWidth: 2
    )
  ),

  // packages: isAppStore ? [.package(url: "https://github.com/rollbar/rollbar-apple", from: "3.2.0")] : [],

  settings: .settings(
    base: [
      "GCC_TREAT_WARNINGS_AS_ERRORS": "YES",
      "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
      "IPHONEOS_DEPLOYMENT_TARGET": SettingValue(stringLiteral: deploymentTargetString),
      "ENABLE_BITCODE": "NO",
      "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
      "CODE_SIGN_IDENTITY": "",
      "CODE_SIGNING_REQUIRED": "NO",
      "DEVELOPMENT_TEAM": SettingValue(stringLiteral: devTeam),
      "MTL_FAST_MATH": "YES",
    ],
    debug: [
      "OTHER_SWIFT_FLAGS": "-D DEBUG $(inherited) -Xfrontend -warn-long-function-bodies=500 -Xfrontend -warn-long-expression-type-checking=500 -Xfrontend -debug-time-function-bodies -Xfrontend -debug-time-expression-type-checking -Xfrontend -enable-actor-data-race-checks",
      "OTHER_LDFLAGS": "-Xlinker -interposable $(inherited)",
      "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "\(additionalCondition) DEBUG",
    ],
    release: [
      "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "\(additionalCondition)",
    ]
  ),

  targets:

  // MARK: - App

  // Main Target
  [createAppTarget()]
    + (isAppStore
      ? []
      : [
        // Additional Dev target with various extra scripts and debug settings
        createAppTarget(
          suffix: "Dev",
          isDev: true,
          scripts:
          [
            .post(
              path: "ci_scripts/post_build_checks.sh",
              name: "Additional Checks",
              basedOnDependencyAnalysis: false
            ),
            // .post(
            //   script: "periphery scan",
            //   name: "Periphery",
            //   basedOnDependencyAnalysis: false
            // ),
            .post(
              script: """
              export REVEAL_SERVER_FILENAME="RevealServer.xcframework"
              export REVEAL_SERVER_PATH="${SRCROOT}/App/Support/Reveal/${REVEAL_SERVER_FILENAME}"
              [ -d "${REVEAL_SERVER_PATH}" ] && "${REVEAL_SERVER_PATH}/Scripts/integrate_revealserver.sh" || echo "Reveal Server not loaded into ${TARGET_NAME}: ${REVEAL_SERVER_FILENAME} could not be found."
              """,
              name: "Reveal Server",
              basedOnDependencyAnalysis: false
            ),
            .post(
              script: "xclogparser parse --workspace Jingo.xcworkspace --reporter html || true",
              name: "XCLogParser",
              basedOnDependencyAnalysis: false
            ),
          ],
          dependencies: []
            // Check if RevealServer framework exists at this path and only then include it in this array of dependencies
            + (isRevealSupported ? [.xcframework(path: "//App/Support/Reveal/RevealServer.xcframework", status: .optional)] : [])
            + (isEttraceSupported ? [.xcframework(path: "//App/Support/ETTrace.xcframework", status: .optional)] : [])
        ),
      ])

    + macTargets
    + [
      // MARK: - ShareExtension

      .target(
        name: "ShareExtension",
        destinations: appDestinations,
        product: .appExtension,
        bundleId: "com.feiyiwang.Jingo.ShareExtension",
        infoPlist: .extendingDefault(with: [
          "CFBundleDisplayName": "Jingo",
          "CFBundleShortVersionString": Plist.Value(stringLiteral: version),
          "NSExtension": [
            "NSExtensionPointIdentifier": "com.apple.share-services",
            "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
            "NSExtensionAttributes": [
              "NSExtensionActivationRule": """
              SUBQUERY (
                  extensionItems,
                  $extensionItem,
                  SUBQUERY (
                      $extensionItem.attachments,
                      $attachment,
                      ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.audio" ||
                      ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.mpeg-4-audio" ||
                      ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.mp3" ||
                      ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "com.microsoft.windows-media-wma" ||
                      ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.aifc-audio" ||
                      ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.aiff-audio" ||
                      ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.midi-audio" ||
                      ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.ac3-audio" ||
                      ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "com.microsoft.waveform-audio"
                  ).@count == $extensionItem.attachments.@count
              ).@count == 1
              """,
            ],
          ],
        ]),
        sources: "App/ShareExtension/ShareViewController.swift",
        entitlements: "App/Support/ShareExtension.entitlements",
        dependencies: [
          .external(name: "AudioKit"),
        ]
      ),

      // MARK: - AppKit

      .target(
        name: "JingoKit",
        destinations: appDestinations,
        product: .staticFramework,
        bundleId: "com.feiyiwang.Jingo.Kit",
        deploymentTargets: appDeploymentTargets,
        infoPlist: .extendingDefault(with: [:]),
        sources: "Sources/AppKit/**",
        resources: "Resources/AppKit/**",
        dependencies: [
          .external(name: "AudioKit"),
          .external(name: "ComposableArchitecture"),
          .external(name: "DSWaveformImage"),
          .external(name: "DSWaveformImageViews"),
          .external(name: "DynamicColor"),
          .external(name: "FluidGradient"),
          .external(name: "Inject"),
          .external(name: "Logging"),
          .external(name: "Popovers"),
          .external(name: "PulseLogHandler"),
          .external(name: "PulseUI"),
          .external(name: "Pow"),
          .external(name: "XCTestDynamicOverlay"),
          .target(name: "Common"),
          .target(name: "AudioProcessing"),
        ] + (isAppStore ? [.external(name: "RollbarNotifier")] : []),
        settings: .settings(
          base: [
            "SWIFT_OBJC_BRIDGING_HEADER": "$SRCROOT/Support/AppKit/Bridging.h",
          ]
        )
      ),
      .target(
        name: "JingoKitTests",
        destinations: appDestinations,
        product: .unitTests,
        bundleId: "com.feiyiwang.Jingo.KitTests",
        infoPlist: .default,
        sources: "Tests/AppKit/**",
        dependencies: [
          .target(name: "JingoKit"),
          .external(name: "SnapshotTesting"),
        ]
      ),

      .target(
        name: "AudioProcessing",
        destinations: appDestinations,
        product: .staticFramework,
        bundleId: "com.feiyiwang.Jingo.AudioProcessing",
        infoPlist: .default,
        sources: [
          "Sources/AudioProcessing/**",
          "Sources/SharedTranscription/**",
        ],
        dependencies: [
          .external(name: "FluidAudio"),
          .external(name: "HuggingFace"),
          .external(name: "MLX"),
          .external(name: "MLXAudioCore"),
          .external(name: "MLXAudioSTT"),
          .external(name: "Dependencies"),
          .external(name: "ComposableArchitecture"),
          .target(name: "Common"),
        ]
      ),
      .target(
        name: "AudioProcessingTests",
        destinations: appDestinations,
        product: .unitTests,
        bundleId: "com.feiyiwang.Jingo.AudioProcessingTests",
        infoPlist: .default,
        sources: "Tests/AudioProcessing/**",
        resources: "TestResources/AudioProcessing/**",
        dependencies: [
          .target(name: "AudioProcessing"),
          .external(name: "FluidAudio"),
        ]
      ),
      .target(
        name: "AudioProcessingDeviceTests",
        destinations: appDestinations,
        product: .unitTests,
        bundleId: "com.feiyiwang.Jingo.AudioProcessingDeviceTests",
        infoPlist: .default,
        sources: "Tests/AudioProcessingDevice/**",
        resources: "TestResources/AudioProcessing/**",
        dependencies: [
          .target(name: "AudioProcessing"),
          .target(name: "Common"),
          .target(name: "JingoDev"),
          .external(name: "FluidAudio"),
        ],
        settings: .settings(
          base: [
            "CODE_SIGN_IDENTITY": "Apple Development",
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGNING_REQUIRED": "YES",
            "DEVELOPMENT_TEAM": SettingValue(stringLiteral: personalDevelopmentTeam),
            "OTHER_LDFLAGS": "$(inherited) -framework FastClusterWrapper -framework MachTaskSelfWrapper -lc++",
          ]
        )
      ),
      .target(
        name: "MeetingSummaryCore",
        destinations: [.iPhone, .iPad, .mac],
        product: .staticFramework,
        bundleId: "com.feiyiwang.Jingo.MeetingSummaryCore",
        deploymentTargets: .multiplatform(iOS: deploymentTargetString, macOS: "14.0"),
        infoPlist: .default,
        sources: "Sources/MeetingSummaryCore/**",
        dependencies: []
      ),
      .target(
        name: "Common",
        destinations: appDestinations,
        product: .staticFramework,
        bundleId: "com.feiyiwang.Jingo.Common",
        infoPlist: .default,
        sources: "Sources/Common/**",
        dependencies: [
          .external(name: "PulseLogHandler"),
          .external(name: "ComposableArchitecture"),
          .target(name: "MeetingSummaryCore"),
        ]
      ),
      .target(
        name: "CommonTests",
        destinations: appDestinations,
        product: .unitTests,
        bundleId: "com.feiyiwang.Jingo.CommonTests",
        infoPlist: .default,
        sources: "Tests/Common/**",
        dependencies: [
          .target(name: "Common"),
          .target(name: "MeetingSummaryCore"),
        ]
      ),
    ],

  schemes: [storeKitScheme, macUITestScheme, speakerProfileBenchmarkScheme],

  resourceSynthesizers: [
    .files(extensions: ["bin"]),
    .assets(),
    .fonts(),
    .strings(),
  ]
)
