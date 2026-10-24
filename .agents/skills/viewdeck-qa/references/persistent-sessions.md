# Persistent ViewDeck sessions

Use a session when you need to see a page, choose an action, then inspect the
result without restarting the game. Confirm `capabilities --json` advertises
`sessions.persistent` before using these commands. Run `viewdeck session help`
for the installed command syntax. Results and errors are JSON; nonzero exit
status and `ok: false` mean the operation failed.

## Start and observe

```bash
viewdeck session start http://localhost:5173 \
  --device iphone-17-pro-max --wait-for canvas --json
```

Keep the returned top-level `session` ID. Start also accepts `--file`, or
`--project` with `--npm-script`/`--command`, and the normal device, orientation,
HTML-layer, readiness, and network flags. Sessions are hidden and muted by
default and require functioning offscreen rendering and audio muting. Do not
open the GUI as a substitute for starting a session.

```bash
viewdeck session status SESSION_ID
viewdeck session screenshot SESSION_ID --output /tmp/viewdeck-qa.UNIQUE/before.png
viewdeck session inspect SESSION_ID
```

Read the screenshot with the image tool and use the audit when selecting a DOM
target or checking failures. `result.preview` reports hidden rendering, frame
inclusion, and the page's position within the screenshot. Validate
`windowIntersectsDisplay: false`, `offscreenRenderingEnabled: true`, and
`audio.muteApplied: true` in session status. Screenshots cover the whole device
viewport; input coordinates are CSS pixels in the main page. With Safari or
HTML layers enabled, account for `preview.pageFrame` before using screenshot
coordinates, or resolve a selector with JavaScript.

## Act on the same page

```bash
viewdeck session click SESSION_ID --selector '#play'
viewdeck session click SESSION_ID --x 150 --y 300
viewdeck session type SESSION_ID --selector '#name' --text 'Player'
viewdeck session key SESSION_ID --key ArrowRight --hold 0.2
viewdeck session drag SESSION_ID --from-x 60 --from-y 300 --to-x 280 --to-y 300
viewdeck session scroll SESSION_ID --y 400
viewdeck session wait SESSION_ID --js 'window.gameReady === true' --timeout 20
viewdeck session screenshot SESSION_ID --output /tmp/viewdeck-qa.UNIQUE/after.png
```

Click, pointer, drag, key, and type use native WebKit input in the hidden helper.
They do not move the system pointer or use desktop accessibility. Scroll and
eval explicitly use JavaScript. Selectors scroll their target into view and
use its center; coordinate actions are useful for canvas games. Native events
give pages trusted events, but APIs requiring an active visible window (for
example system prompts) still have their normal platform restrictions.

Hold keys across commands with `key --action down`, inspect the game, then
release with `key --action up`. `pointer --action down|move|up` supports custom
gestures. Always release inputs, including after an unsuccessful action.
`session stop` releases any remaining inputs automatically.

## Evaluate and navigate

```bash
viewdeck session eval SESSION_ID --js '({title:document.title, width:innerWidth})'
viewdeck session eval SESSION_ID --script-file /absolute/helper.js
viewdeck session navigate SESSION_ID --url http://localhost:5173/settings
viewdeck session reload SESSION_ID
viewdeck session configure SESSION_ID --orientation landscape
```

Eval accepts expressions/statements and awaits returned promises. Use
`globalThis` for helpers that must persist across eval calls. Return JSON-sized
values, not large image strings; screenshots have their own command. A selector
wait checks presence; JavaScript waits handle application-specific readiness.
Wait failures leave the session alive and must not be treated as success.

Commands preserve the page and its in-memory state. Navigation/reload naturally
replace the document, while session cookies/local storage remain available.
Changing device/viewport/DPR can reload the page. Sessions have independent,
ephemeral website stores, so they do not alter the open GUI's cookies or save
data. They cannot attach to an already-running GUI page.

## Record without restarting

```bash
viewdeck session record start SESSION_ID --output /tmp/viewdeck-qa.UNIQUE/game.mp4
viewdeck session click SESSION_ID --selector '#play'
viewdeck session wait SESSION_ID --js 'window.roundComplete === true'
viewdeck session record stop SESSION_ID
```

Recording defaults to device DPR, 30 FPS, high-quality H.264, and the session's
frame setting. `--scale` and `--fps` override those values. Record stop waits for
MP4 finalization; inspect the resulting file. Do not navigate, resize, or change
device settings during recording. Use `--overwrite` only when replacing an
existing artifact is intended. If a recording fails asynchronously, status
reports `recording.state: failed` and its error.

## Cleanup and generic requests

```bash
viewdeck session list
viewdeck session stop SESSION_ID
```

Stop releases inputs, saves active video, closes WebKit, and stops any server
started by that session. Idle sessions expire after 30 minutes; `session start
--idle-timeout SECONDS` changes that limit (5 through 86400 seconds). No command
should rely on keeping a session indefinitely. A stale or expired session must
be replaced with a new one. Do not terminate arbitrary PIDs from a status file.

For programmatic clients, write a JSON request such as
`{"method":"click","params":{"selector":"#play"}}` and pass it to
`viewdeck session request SESSION_ID --input /absolute/request.json`. Methods
use the names above; recording methods are `record.start` and `record.stop`.
Requests execute serially within a session, expire before execution if their
deadline passes, and are bounded by `--timeout` (0.1 through 120 seconds).
The private control directory is an implementation detail; use the CLI rather
than writing its queue files directly.

Return relevant screenshots, video, audit results, and failures to the user.
Do not leave temporary sessions running after the task is complete.
