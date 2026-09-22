# Repository Agent Instructions

## Tuist and Testing

- Do not run `tuist test` in the working checkout. It regenerates the Xcode workspace around the selected test graph and can temporarily remove unrelated schemes such as `JingoMac`.
- Generate the complete workspace with `make project_file` or `mise exec -- tuist generate --no-open`.
- Run tests against the existing generated workspace with plain `xcodebuild test` or `mise exec -- tuist xcodebuild test`. These commands preserve the complete workspace and its schemes.
- If a command unexpectedly changes the generated workspace, immediately restore it with `mise exec -- tuist generate --no-open` and verify that the `JingoMac` scheme is present before handing the workspace back to the user.
