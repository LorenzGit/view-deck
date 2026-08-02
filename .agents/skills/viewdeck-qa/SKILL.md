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

When the task requests slow, constrained, or offline networking, require a
`networkShaping` capability containing round-trip latency, jitter, download and
upload bandwidth, offline mode, and deterministic seeds. Do not substitute a
fixed replay delay for network shaping.

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
- Use the interactive ViewDeck UI for recording only when the user explicitly
  asks to watch or drive it. Otherwise use hidden CLI `record` or author a
  scenario from `qa template`.
- Use `qa replay` when a `.viewdeck.json` scenario already exists.

Recording and replay automatically clear data for the tested site before the
run. Do not add a second cache-reset mechanism.

## Keep agent runs invisible

CLI previews are hidden by default. ViewDeck keeps the ordered WKWebView panel
outside every connected display and disables WebKit window-occlusion detection
for that preview so animation and GPU rendering remain active. Artifacts use
the app's own-window compositor, so agents can replay input and collect
screenshots or video without exposing a mini preview to the user. Do not pass
`--show-preview` unless the user explicitly asks to watch the run. Rendering
diagnostics do not authorize an agent to expose the preview; use hidden
screenshots, video, reports, and page diagnostics instead.

Pass `--audio verify-silent` for every hidden `capture`, `inspect`, `record`,
and `qa replay` run. This mutes the WebKit page output while its media timeline
and Web Audio graph continue running, allowing the report to capture native
audio activity without playing sound through the user's speakers. Do not use
this option with `--show-preview`.

For `capture`, `inspect`, `record`, and `qa replay`, confirm the report contains:

```json
{
  "preview": {
    "visibility": "hidden",
    "windowIntersectsDisplay": false,
    "captureBackend": "windowCompositor",
    "offscreenRenderingEnabled": true
  },
  "audio": {
    "mode": "verify-silent",
    "output": "muted",
    "muteApplied": true
  }
}
```

Treat an unexpected visible preview, display intersection, or disabled
offscreen rendering as a failed hidden run. Hidden video may contain fewer
frames than the requested FPS when compositor capture cannot keep up; inspect
actual MP4 duration and representative frames rather than requiring every
scheduled frame.

## Choose and verify orientation

Portrait is the CLI default. When the requested experience is landscape, pass
`--orientation landscape` to every direct `capture`, `inspect`, or `record`
command and when generating a `qa template`:

```bash
dist/native/viewdeck capture \
  --project /absolute/path/to/game \
  --npm-script dev \
  --device iphone-17-pro-max \
  --orientation landscape \
  --wait-js 'innerWidth > innerHeight && screen.width > screen.height && matchMedia("(orientation: landscape)").matches && screen.orientation.type.startsWith("landscape")' \
  --audio verify-silent \
  --output /tmp/viewdeck-qa.example/landscape.png \
  --report /tmp/viewdeck-qa.example/landscape.json \
  --json
```

Landscape swaps the selected profile's portrait screen width and height before
the isolated WKWebView loads. The page receives `window.orientation` of `90`
and `screen.orientation.type` of `landscape-primary` with angle `90`. Its CSS
orientation media query follows the page-content viewport's aspect ratio, which
is normally landscape but can become portrait-like when wide side layers
reserve most of the screen. ViewDeck is a web/device-geometry simulator, not an
iOS or Android OS emulator; it exercises the isolated website or game in
WKWebView rather than launching its native app container.

Treat orientation as immutable for one CLI run:

- A direct command takes orientation from `--orientation`.
- `qa template` embeds the chosen orientation and all derived geometry in
  `configuration`.
- `qa replay` takes orientation from the scenario's
  `configuration.orientation`; a replay-time `--orientation` argument does not
  override it.
- An interactively recorded scenario captures the active ViewDeck orientation.
- To test both orientations, create and replay separate portrait and landscape
  scenarios. There is no mid-replay rotate event.

Never convert a portrait scenario by changing only the orientation string or
swapping two numbers. Regenerate the template with `--orientation landscape`,
then adapt the events and checkpoints. The generated configuration also
contains oriented CSS and physical resolutions, page-content geometry, safe
areas, Safari chrome, layers, and orientation-specific pointer coordinates.

For a direct `capture`, `inspect`, or `record`, verify:

```text
device.orientation == "landscape"
device.viewport.width > device.viewport.height
preview.visibility == "hidden"
preview.windowIntersectsDisplay == false
```

For `qa replay`, verify the equivalent scenario-backed fields:

```text
configuration.orientation == "landscape"
configuration.resolution.orientedScreenCSS.width >
  configuration.resolution.orientedScreenCSS.height
preview.visibility == "hidden"
preview.windowIntersectsDisplay == false
```

Use the `--wait-js` landscape predicate above when orientation-sensitive
layout must be ready before capture and the page content is expected to remain
wider than tall. Combine it with any application-owned readiness condition in
the same expression. If side layers intentionally make the page content narrow,
verify `screen.orientation` and the configured oriented screen instead of
requiring a landscape CSS media query. Do not infer orientation from a
filename, screenshot appearance, or width alone when the report can prove it.

Account for orientation-dependent geometry:

- Portrait safe-area edges rotate clockwise: portrait top becomes landscape
  left, and portrait bottom becomes landscape right. The sensor moves to the
  left edge and the home indicator to the right edge.
- iOS app status-bar chrome is hidden in landscape. Safari profiles use their
  compact landscape top and bottom chrome measurements.
- Header and footer layers work in both orientations. Left and right layers
  reserve page width only in landscape, so include them when generating the
  scenario rather than adding them later.
- `--show-safe-area` draws a guide only. `--apply-safe-area` changes page
  layout. In either case, inspect the report's oriented and page-exposed safe
  areas rather than assuming the portrait inset values.
- Mobile WebKit views deliberately overscan the trailing edge by up to four CSS
  pixels to avoid capture seams; modern iOS app profiles also overscan the
  bottom edge. Consequently, `audit.viewport` or `innerWidth`/`innerHeight` may
  be up to four pixels larger than the scenario's configured page content.
  Use the configured geometry and captured pixel dimensions as the device
  target, and report the overscan if it crosses a responsive breakpoint.

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
  --audio verify-silent \
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
  --audio verify-silent \
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

## Shape network conditions

Use explicit values rather than names such as "3G" or "poor Wi-Fi" unless the
user supplied the exact profile values. Any network option enables the
per-preview network transport:

```bash
dist/native/viewdeck inspect https://example.com \
  --network-rtt-ms 400 \
  --network-jitter-ms 40 \
  --network-down-kbps 1500 \
  --network-up-kbps 500 \
  --network-seed 42 \
  --timeout 60 \
  --audio verify-silent \
  --report /tmp/viewdeck-qa.example/network.json \
  --json
```

- `--network-rtt-ms` is added round-trip latency and is split across upload and
  download traffic.
- `--network-jitter-ms` is seeded one-way plus-or-minus jitter. Always set
  `--network-seed` when reproducibility matters.
- `--network-down-kbps` and `--network-up-kbps` use kilobits per second; `0`
  means unlimited.
- `--network-offline` blocks proxy connections. On a direct command it is
  expected to produce a navigation failure, so use it when that failure itself
  is the test.
- Increase `--timeout` enough to cover the deliberately slower navigation,
  application readiness, and artifact capture.

Pass the same network options to `qa template` to embed them in
`configuration.network`. A replay restores the embedded conditions before the
existing site-data reset and initial load. Network options passed directly to
`qa replay` temporarily override the scenario for that run without rewriting
the source JSON.

Use `--speed 1` when wall-clock response under latency is part of the test.
Smart replay may still be used when the assertion is semantic and input idle
time is irrelevant; semantic waits continue to block on the shaped response.

Require the report's top-level `network` object to match the requested values.
For an online HTTP(S) run, also require `implementation` to be either
`loopbackSOCKSv5Proxy` or `loopbackTCPBridge+SOCKSv5Proxy`,
`trafficObserved: true`, `acceptedConnectionCount` to be greater than zero, and
the relevant transferred byte count to be greater than zero. Inspect
`network.activity`: require lifecycle `progress` to reach `1`, `pendingCount`
to reach `0`, and explain every failed entry in `resources`. Treat resource
duration and transfer-size fields as WebKit Resource Timing observations, not
proxy measurements. For a local HTTP run, require
`localOriginRemapped: true` and return its `requestedURL` and `transportURL` so
origin-sensitive behavior is not hidden. Report the
configured conditions and measured total run or wait time; do not describe the
proxy's byte counters as per-request timing.

Network shaping covers TCP traffic from the primary WKWebView without
decrypting HTTPS. It does not shape HTTP/3/QUIC and does not simulate packet
loss, radio scheduling, RF conditions, or cellular handoff. State those limits
when they matter to the requested conclusion. WebKit bypasses its proxy for
literal loopback destinations, so ViewDeck remaps local HTTP traffic through a
loopback TCP bridge. Page code can observe that internal origin. Local HTTPS
cannot use the bridge because changing its origin would invalidate the
certificate; do not claim it was shaped unless the report counters prove that
its traffic traversed the SOCKSv5 proxy.

## Author a scenario

Generate the scenario before adding inputs. Never invent or copy the device
configuration by hand. Choose the requested orientation explicitly; the
following example creates a landscape scenario.

```bash
dist/native/viewdeck qa template \
  --project /absolute/path/to/game \
  --npm-script dev \
  --device iphone-17-pro-max \
  --orientation landscape \
  --name "gameplay smoke test" \
  --output /tmp/viewdeck-qa.example/gameplay.viewdeck.json \
  --overwrite \
  --json
```

The generated file contains the exact source, device, orientation, resolution,
DPR, safe area, Safari, network shaping, header, footer, and side-layer
configuration. Confirm `.configuration.orientation`,
`.configuration.resolution`, and `.configuration.network` before adding events.
Read
`authoring.eventExamples` from that file and adapt those current examples into
the top-level `events` array:

```bash
jq '{orientation: .configuration.orientation, resolution: .configuration.resolution, network: .configuration.network, authoring: .authoring}' \
  /tmp/viewdeck-qa.example/gameplay.viewdeck.json
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
  --audio verify-silent \
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
- `preview.visibility`, `preview.windowIntersectsDisplay`,
  `preview.captureBackend`, and `preview.offscreenRenderingEnabled`
- `audit.pageErrors`
- `network`, including the effective conditions, proxy implementation,
  `trafficObserved`, connection and byte counts, and every
  `activity.resources[]` lifecycle
- `audit.consoleMessages` and `audit.issues`
- `audio.muteApplied`, `audio.everActive`, and every `audio.activeIntervals[]`
- `audit.audio.mediaElements`, media errors/events, and Web Audio source starts
- `playback` and every `timingPlan.entries[].adjustment`
- `artifacts` paths and whether every requested file exists

Visually inspect the final PNG and checkpoint images. Inspect the MP4 when the
test concerns animation or frame pacing. A successful process with page errors,
replay errors, a wrong visual state, or missing artifacts is not a passing
test.

When sound is expected, require native `audio.everActive: true` and correlate
its activity intervals with the responsible replay event. Treat a media error,
an absent expected playback event, or no native audio activity as a failure.
Native activity proves that WebKit produced audio while its page output was
muted; it does not prove subjective properties such as pitch, mix, or
distortion.

When a scenario is flaky, replace arbitrary timing with selector or JavaScript
waits first. Then verify selectors, coordinates, focus, and input pairs. Do not
change the tested application merely to make QA pass unless the user asked for
a fix.

## Complete the task

Return:

1. The tested source, device, orientation, Safari/header/footer state, and
   preview visibility.
2. The effective network conditions and the proxy's TCP/HTTP3 scope.
3. The scenario and report paths.
4. Every screenshot, checkpoint folder, and video path.
5. Original and effective replay duration when smart timing was used.
6. Concise failures or warnings with the responsible event/checkpoint.

Keep all temporary artifacts until the user has received their paths.
