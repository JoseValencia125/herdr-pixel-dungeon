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

### Changed
- Strengthened the independence disclaimers across NOTICE, README and the guide:
  no affiliation, endorsement or sponsorship by Herdr, Inc., plus a trademarks note.
- The About dialog now shows the independent-project line in all five languages.

### Fixed
- Localized the "Reading project files…" status and the choose-options chat hint,
  which now uses "Enter" to match the existing localization key.

## [2.0.0]

- Initial public release of the Rust / egui rewrite.
