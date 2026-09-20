import ProjectDescription

let workspace = Workspace(
  name: "Jingo",
  projects: ["."],
  generationOptions: .options(
    lastXcodeUpgradeCheck: Version(15, 4, 0)
  )
)
