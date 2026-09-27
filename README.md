# CannyGit

English | [한국어](README.ko.md)

A macOS app for managing Git repositories and worktrees in one place.

When you have a dev server running for each branch, it's easy to lose track of which terminal belongs to which folder. CannyGit keeps terminals and tasks attached to their worktrees. You can check what changed, run a build or test, and remove a worktree when you're done with it.

Built with SwiftUI and AppKit, with [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the embedded terminal. The app's interface is currently in Korean.

## What it does

- **Repository management:** Add folders through the file picker or drag and drop. Find them with favorites and search. Adding a linked worktree won't create a duplicate repository entry.
- **Worktree creation and removal:** Create a new branch or use an existing local branch. Before removing a worktree, the app checks for changed files, untracked files, and locks.
- **Git status and diffs:** See staged, unstaged, untracked, and conflicted files, plus ahead/behind counts. Read-only diffs and untracked file previews are available per file.
- **Embedded terminals:** Open multiple tabs for each worktree. Sessions stay alive when you switch worktrees or hide the terminal panel.
- **Tasks:** Read scripts from `package.json`, with support for npm, pnpm, yarn, and bun. Rust, Go, and Swift projects get suggested build and test commands. You can also add your own commands and override shared repository settings for individual worktrees.
- **Task groups:** Run tasks in order, for example by installing dependencies, building, and then starting servers. Tasks within a stage run in parallel; the next stage starts after the previous one succeeds. Servers go in the final stage.
- **Activity view:** Check running tasks, recent results, logs, and listening ports. Open a port or a configured URL in your browser.

There is no UI for Git commit, push, pull, PR management, or conflict resolution yet. Use the embedded terminal or your usual tools for those.

## Build and run

You'll need macOS 14 or later, a full Xcode installation, and Git. Builds and tests have been verified with Xcode 27.0 on macOS 26.6.2, running on Apple Silicon. The commands below target Apple Silicon too.

Run these from the project root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -project CannyGit.xcodeproj \
  -scheme CannyGit \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  -skipPackagePluginValidation build

open DerivedData/Build/Products/Debug/CannyGit.app
```

If the build reports a missing Metal Toolchain, install it and try again:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -downloadComponent MetalToolchain
```

You can also open `CannyGit.xcodeproj` in Xcode and run the `CannyGit` scheme. If Xcode asks for permission to run a package plugin, allow SwiftTerm's build-info plugin. SwiftTerm is pinned to version 1.19.0.

## Getting started

1. Choose **저장소 등록** (Add Repository) and select an existing local Git repository, or drop a folder onto the sidebar.
2. Select a worktree to see its branch and changes. Use **워크트리 생성** (Create Worktree) when you want a separate folder for another branch.
3. Open **작업** (Tasks) and review the detected commands. Adjust the runner, arguments, working directory, or expected ports before running them.
4. Choose **터미널 열기** (Open Terminal) to enter commands yourself. **실행 현황** (Activity) brings together tasks from all your worktrees.
5. When you're finished, stop the sessions and remove the worktree. Its branch is kept.

Detecting a command doesn't run it. CannyGit also doesn't copy `.env` files or dependency folders into new worktrees, so you'll need to do any project-specific setup yourself.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘O` | Add a repository |
| `⌘R` | Refresh |
| `⌘K` | Open the command palette |
| `⌘,` | Open settings |

## A few things to know

- Closing the window leaves terminals and tasks running. Quitting the app normally stops the sessions it started and their child processes. Restoring sessions after a force quit or crash is not supported.
- Git ahead/behind counts use the last local fetch result. The app doesn't fetch automatically.
- A listening port doesn't mean the app has checked the server's HTTP response.
- Task logs are held in memory, up to 5 MiB per run and 50 MiB in total. Use log export if you want to keep a file.
- Repository registrations and task settings are stored in `~/Library/Application Support/CannyGit/settings.json`. Task environment settings reference variable names in the app's environment rather than storing their values.
- An app launched from Finder may have a different `PATH` from your terminal. If a tool can't be found, check the Git and shell paths and run the diagnostics in settings.

## Tests

Run these from the project root. Tests also require a full Xcode installation.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift test

xcodebuild -project CannyGit.xcodeproj \
  -scheme CannyGit-UI \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  -skipPackagePluginValidation test
```

The current test run passes 59 integration tests and 2 UI scenarios. They cover worktree creation and removal, settings restoration, process cleanup, task groups, diffs, and more. UI tests interact with real windows and keyboard input.

Manual verification is still needed for Korean IME composition, the full VoiceOver flow, and recovery after disconnecting an external drive. Release builds contain both arm64 and x86_64 binaries, but execution on macOS 14 and Intel hardware has not yet been verified.

## Release package

```sh
bash Scripts/package-release.sh
```

This builds the Release app and creates `Artifacts/CannyGit-<version>-macOS.zip`. The default uses an ad-hoc signature for local use. Developer ID signing and notarization for public distribution have not been completed yet.

## Source layout

```text
CannyGit/
  App/          App startup and shutdown
  Models/       Repositories, worktrees, tasks, and run state
  Features/     Dashboard and other screens
  Services/     Git, PTY execution, task detection, and settings storage
  Resources/    Icons, strings, and license notices
CannyGitTests/   Unit and integration tests
CannyGitUITests/ UI tests
Scripts/        Packaging and development tools
```

The Xcode project and `Package.swift` use the same sources. SwiftTerm handles terminal rendering; the app manages PTY execution and process lifetimes.
