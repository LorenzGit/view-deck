---
name: viewdeck-qa
description: Run deterministic visual and interaction QA with the ViewDeck CLI. Use when an agent needs to inspect, record, author, replay, accelerate, debug, or collect screenshots, checkpoint images, videos, and reports for PixiJS, Three.js, canvas, Vite, React, or HTML sites and games; or when working with .viewdeck.json scenarios.
---

# ViewDeck QA

Use ViewDeck as the source of truth for device geometry, clean-site startup,
input replay, and visual artifacts. Prefer semantic readiness conditions and
smart replay over timing derived from agent reasoning or screenshot processing.

## Resolve ViewDeck and artifacts

1. Prefer a ViewDeck executable path supplied by the user.
2. Otherwise use `dist/native/viewdeck` from a ViewDeck checkout.
3. If that executable is absent, build it from the ViewDeck repository:

```bash
zsh scripts/build-native-app.sh
```

Run these preflight commands and use only supported device IDs and capabilities:

```bash
dist/native/viewdeck capabilities --json
dist/native/viewdeck devices list --json
```

Use absolute source and output paths. Create a uniquely named temporary
directory outside the tested repository, keep all generated scenarios and
artifacts there, and report that directory to the user. Do not commit QA
artifacts.

```bash
mktemp -d /tmp/viewdeck-qa.XXXXXX
```

## Choose the workflow

- Use `capture` or `inspect` for a one-state smoke test or layout audit.
- Use `qa template` when an agent will author a new scripted interaction.
- Record through the ViewDeck UI when exploration, FTUE, or precise human
  gestures are easier to demonstrate, then edit and replay the result.
- Use `qa replay` when a `.viewdeck.json` scenario already exists.

Recording and replay automatically clear data for the tested site before the
run. Do not add a second cache-reset mechanism.

## Run a one-state audit

Use `--project` for a Vite or other managed development server, `--file` for
static HTML, or a URL as the positional source. Tie initial readiness to a
selector or JavaScript state whenever possible.

```bash
dist/native/viewdeck capture \
  --project /absolute/path/to/game \
  --npm-script dev \
  --device iphone-17-pro-max \
  --wait-for canvas \
  --output /tmp/viewdeck-qa.example/smoke.png \
  --report /tmp/viewdeck-qa.example/smoke.json \
  --json
```

Use `inspect` instead when no screenshot is required. Add
`--fail-on-page-error` for runtime errors. Add `--fail-on-issues` only when
every layout warning should fail the run.

## Wait for application readiness

WebKit navigation completion means the main document loaded. It does not prove
that React effects, API requests, asset decoding, canvas rendering, or
animations have completed. ViewDeck does not infer generic network-idle or
visual-stability state.

For `capture`, `inspect`, and `record`, use `--wait-for` for a durable CSS
selector and/or `--wait-js` for persistent application-owned state:

```bash
dist/native/viewdeck capture \
  --project /absolute/path/to/game \
  --npm-script dev \
  --wait-for '[data-viewdeck-ready="true"]' \
  --wait-js 'window.gameReady === true' \
  --output /tmp/viewdeck-qa.example/ready.png \
  --json
```

When both are supplied, both must become true. ViewDeck polls them after
navigation and captures only after readiness plus the configured settle delay.
Prefer persistent level-triggered state such as `window.gameReady === true` or
`data-viewdeck-ready="true"` over a one-time event that a poller could miss.
The existence of `canvas` proves only that the element was mounted, not that
the game rendered its first usable frame.

For replay, place a semantic `wait` event immediately after the input that
starts asynchronous work and before every action or checkpoint that depends on
its result. Adapt `authoring.eventExamples.waitForSelector` or
`authoring.eventExamples.waitForJavaScript` from the generated template rather
than inventing the event shape. Replay blocks subsequent timeline items while
the condition remains false.

A timed-out replay wait is reported as an error, but replay currently continues
and may still write later screenshots or other artifacts. Never trust or act on
dependent artifacts unless the replay report has top-level `ok: true` and no
wait error in `errors`.

## Author a scenario

Generate the scenario before adding inputs. Never invent or copy the device
configuration by hand.

```bash
dist/native/viewdeck qa template \
  --project /absolute/path/to/game \
  --npm-script dev \
  --device iphone-17-pro-max \
  --name "gameplay smoke test" \
  --output /tmp/viewdeck-qa.example/gameplay.viewdeck.json \
  --overwrite \
  --json
```

The generated file contains the exact source, device, resolution, DPR, safe
area, Safari, header, and footer configuration. Read
`authoring.eventExamples` from that file and adapt those current examples into
the top-level `events` array:

```bash
jq '.authoring' /tmp/viewdeck-qa.example/gameplay.viewdeck.json
```

Preserve the generated schema and configuration. While authoring:

- Give every event a stable, unique ID.
- Sort events by `atMilliseconds`.
- Set `intervalSincePreviousMilliseconds` to the difference from the previous
  event.
- Update `timing.durationMilliseconds`, `timing.eventCount`, and
  `timing.checkpointCount` to match the authored timeline.
- Express a click as `pointerdown`, `pointerup`, and `click`.
- Express a key press or hold as matching `keydown` and `keyup` events. Smart
  replay preserves the interval between them.
- Add a click before keyboard events when the game must receive focus.
- Use a `wait` event with `selector` and/or `javascript` for actual readiness.
  Use `delayMilliseconds` only when the passage of time is itself under test.
- Do not encode time spent interpreting screenshots or reasoning as an idle
  delay.

For critical-moment screenshots, add entries to top-level `checkpoints` and
replay with `--artifacts`. Use this minimal shape:

```json
{
  "id": "after-start",
  "name": "After start",
  "atMilliseconds": 1500,
  "intervalSincePreviousInputMilliseconds": 150,
  "screenshotPath": "",
  "screenshotPixelSize": { "width": 0, "height": 0 },
  "captureScale": 3
}
```

## Apply framework-specific guidance

- For PixiJS, Three.js, and canvas games, wait for `canvas` plus a game-owned
  JavaScript readiness signal when available. Target canvas input with both CSS
  and normalized coordinates from the generated examples.
- For React and ordinary DOM apps, prefer durable selectors such as
  `data-testid` or stable IDs. Wait for the post-action DOM state instead of
  sleeping.
- For keyboard-only games, author explicit down/up pairs with the real `key`,
  `code`, modifiers, and hold duration. Do not replace a hold with a click.
- For animation-sensitive checks, capture video and checkpoints. Use a fixed
  delay only when a visual transition must complete and no semantic state is
  exposed.

## Replay and collect artifacts

Use smart timing by default for agent-authored or agent-observed scenarios:

```bash
dist/native/viewdeck qa replay \
  /tmp/viewdeck-qa.example/gameplay.viewdeck.json \
  --speed smart \
  --artifacts /tmp/viewdeck-qa.example/checkpoints \
  --video /tmp/viewdeck-qa.example/replay.mp4 \
  --fps 30 \
  --screenshot /tmp/viewdeck-qa.example/final.png \
  --report /tmp/viewdeck-qa.example/replay.json \
  --overwrite \
  --json
```

Smart replay preserves short gaps, pointer and mouse down-to-up gestures, and
keyboard holds. It caps long idle gaps and writes the original/effective
timestamp mapping to `timingPlan`; it does not rewrite the source scenario.

Omit `--video` for quick logic and layout iterations. Include it for animation,
rendering, or visual-regression investigation and prefer `--fps 30`. Use
`--speed 1` only when recorded wall-clock timing is part of the test. Use
`--speed max` only when input timing has no meaning.

## Evaluate and iterate

Treat the command exit status and JSON report as evidence, not the screenshot
alone. Check:

- top-level `ok` and `errors`
- `audit.pageErrors`
- `audit.consoleMessages` and `audit.issues`
- `playback` and every `timingPlan.entries[].adjustment`
- `artifacts` paths and whether every requested file exists

Visually inspect the final PNG and checkpoint images. Inspect the MP4 when the
test concerns animation or frame pacing. A successful process with page errors,
replay errors, a wrong visual state, or missing artifacts is not a passing
test.

When a scenario is flaky, replace arbitrary timing with selector or JavaScript
waits first. Then verify selectors, coordinates, focus, and input pairs. Do not
change the tested application merely to make QA pass unless the user asked for
a fix.

## Complete the task

Return:

1. The tested source, device, orientation, and Safari/header/footer state.
2. The scenario and report paths.
3. Every screenshot, checkpoint folder, and video path.
4. Original and effective replay duration when smart timing was used.
5. Concise failures or warnings with the responsible event/checkpoint.

Keep all temporary artifacts until the user has received their paths.
