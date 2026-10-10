# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.1] - 2026-10-09

### Added
- Full screen with the rooms in a column on the left and the live console
  (colours and all) on the right (⌃⌘F on macOS, F11 on Linux).
- Trapped room for Claude session limits: a caged hero rattles the bars over a
  countdown to the reset, also shown in the agent's chat.
- In full screen, type straight on the terminal's own prompt line, scroll back
  through its history, and set the console's text size on its own.
- A "/" menu listing the harness's commands.
- Drop files on the chat to add their paths to the message.
- In full screen, a spare "+" room to summon a new agent.
- Standalone viewer that runs without Herdr, with install/open buttons and a
  text-size setting.
- Badges count the rooms hidden above or below the scroll, and jump to them.

### Changed
- Strengthened the independence disclaimers across NOTICE, README and the guide:
  no affiliation, endorsement or sponsorship by Herdr, Inc., plus a trademarks note.
- The About dialog now shows the independent-project line in all five languages.

### Fixed
- Starting an agent retries while the new pane's shell is still booting.
- A background job's state follows its live tempo, not its sticky state field.
- Localized the "Reading project files…" status and the choose-options chat hint,
  which now uses "Enter" to match the existing localization key.

## [2.0.0]

- Initial public release of the Rust / egui rewrite.
