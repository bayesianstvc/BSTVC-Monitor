# Contributing to BSTVC Monitor

Thank you for helping improve a small, local-first research tool.

## Before opening an issue

Please check the README and [Accuracy and interpretation](docs/accuracy-and-interpretation.md). In particular, distinguish the Task Manager-aligned whole-machine CPU curve from advanced logical-core counters.

## Bug reports

Include:

- Windows version and PowerShell version;
- browser and display scaling, if the issue is visual;
- sampling interval and page refresh interval;
- whether the issue affects the main curve, a PID card, an export, or an advanced diagnostic;
- a short reproduction sequence and the relevant error text.

Remove model data, usernames, private paths, and sensitive screenshots before attaching files. Do not attach raw CSV files unless they contain no confidential information.

## Pull requests

Keep changes focused and explain the user-facing effect. Preserve the local-only design, avoid adding telemetry, and keep the portable launcher usable on a normal Windows installation. Test both the English default interface and the Chinese toggle when changing dashboard text.

For monitoring changes, state the metric definition, its Windows counter basis, and how it was checked against Task Manager. Do not silently change the primary CPU scale.
