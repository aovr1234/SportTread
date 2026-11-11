# Andrew's SportTread

iPhone app that runs a ProForm 505 CST treadmill without iFit. See [PLAN.md](PLAN.md).

## Current stage: build 0.7.1 (fixes from the field tests + no-scroll screens)
Passed so far: milestones 0, 1, 2, 5, the Live Activity and two field tests. On hold: saving to Apple Health,
heart rate (waits for the Bluetooth sensor), autosave/recovery and speed guards (proposed, not agreed).

### Get the IPA
1. GitHub → **Actions** → latest **Build unsigned IPA** run → download **SportTread-ipa**.
2. Unzip it to get `SportTread-unsigned.ipa`.
3. Upload it to Signulous, sign (no extra options), and install.

Every build first runs the length tests (`Tests/LengthTests`): every workout length from 10 to 90 minutes,
simulated AI workouts, live edits and reading a length from text must come out exact, or the build fails.

### Test
| # | Test | Pass when |
|---|---|---|
| 1 | Treadmill tab | Everything fits on one screen, no scrolling: status row, Speed and Incline tiles, time and miles, bottom bar |
| 2 | Tap **Start** | A 3-2-1 countdown ("tap to cancel"), then the belt starts at 1.0 mph; tapping during the countdown cancels |
| 3 | STOP, End workout | STOP only shows while the belt runs; **End workout** stops the belt, then 2 s later lowers the deck to 0%, and shows "Session saved" |
| 4 | Coach tab: pick **60**, **Create 60-min workout** | The preview says exactly 60 min; the button says "Create 60-min workout" |
| 5 | Type "1 hr" (or "an hour") in the notes | "Using 60 min from your note", and the picker moves to 60 |
| 6 | Start a workout | Fits one screen, no scrolling; the profile chart has a marker that moves; the step ring, Speed and Incline tiles, one bottom bar |
| 7 | ✦ Coach → **−5 min** | Applies at once; a card says "Workout length 55:00, was 60:00" with **Undo** for 10 s; Undo restores it |
| 8 | ✦ Coach → **+5 min** / **Harder** | An Apply card appears (nothing changes until you tap Apply); then the length card shows 65:00 |
| 9 | ✦ Coach → type "add 5 minutes", then "make it an hour total" | The workout is exactly 5 minutes longer, then exactly 60:00 in total |
| 10 | Check-ins (Coach tab: every 5 min) during a workout | "How's it feeling?" floats over the top without moving anything |
| 11 | During a workout: STOP, then Resume / End workout | STOP pauses (belt stops, incline stays); End workout stops, then lowers the deck |
| 12 | History tab → the workout | "Planned at start" and "at the end", top speed and incline you actually reached, and "What changed" with before/after lengths; rapid incline taps are one entry |

Still to check from 0.7: the treadmill-mode Live Activity (ends 2 min after stopping), readiness, goal plans,
the workout editor, and deleting history.

## Repo layout
- `project.yml`: XcodeGen project (the `.xcodeproj` is generated in CI)
- `SportTread/`: iPhone app (Treadmill, Workouts, Coach, History folders; DesignSystem.swift for the look)
- `SportTreadLiveActivity/`: widget extension for the Lock Screen / Dynamic Island Live Activity
- `Shared/`: code used by both (Live Activity data)
- `Tests/LengthTests/`: the length tests run on every build
- `.github/workflows/build.yml`: macOS build → unsigned IPA
- `web/treadmill.html`: working Web Bluetooth controller (Chrome/Edge)
- `design/AppIcon.svg`: app icon source (render with `tools/render_icon.py`)
- `tools/`: Python BLE scripts used to work out the treadmill protocol
