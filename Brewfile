# Brewfile — developer tools needed to build Ice Cube. Install with: brew bundle
#
# Expected versions: xcodegen 2.46.0 (verified 2026-07-23), swiftformat 0.62.1
# (verified 2026-08-02). Homebrew installs the latest formula and cannot pin, so
# these two are the only unpinned executables in the build.
#
# CI reads these numbers. Both workflows print the installed versions and emit a
# ::warning:: when they drift from the ones above — a warning, never a failure,
# so a formula bump cannot break the build or block a release. If one fires:
# check that release's notes against project.yml (xcodegen changes what gets
# generated) or against the codebase (swiftformat gates `--lint`, so a new rule
# fails untouched files), then update the version here in the same PR.
brew "xcodegen"
brew "swiftformat"
