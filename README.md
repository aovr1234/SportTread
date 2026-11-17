# Andrew's SportTread

iPhone app that runs a ProForm 505 CST treadmill without iFit. See [PLAN.md](PLAN.md).

## Current stage: build 0.7.2 (command pacing, resume fix, summary, Live Activity buttons)
Passed so far: milestones 0, 1, 2, 5, the Live Activity and two field tests. On hold: saving to Apple Health,
heart rate (waits for the Bluetooth sensor), autosave/recovery and speed guards (proposed, not agreed).

### Get the IPA
1. GitHub → **Actions** → latest **Build unsigned IPA** run → download **SportTread-ipa**.
2. Unzip it to get `SportTread-unsigned.ipa`.
3. Upload it to Signulous, sign (no extra options), and install.

Every build first runs the length tests (`Tests/LengthTests`): every workout length from 10 to 90 minutes,
simulated AI workouts, live edits and reading a length from text must come out exact, or the build fails.

### Test (0.7.2)
| # | Test | Pass when |
|---|---|---|
| 1 | Treadmill: tap Speed ▼ 10 times quickly | The belt slows in steps, the connection never times out, the status keeps updating |
| 2 | Workout: Pause, wait, Resume (5 times) | The incline returns to the step's value every time; if the console drops it the app sends it again; if it can't, an orange "Incline didn't take" card shows |
| 3 | Coach tab → Start a plan | The Goal list shows four rows with a description each; tapping one selects it with a check mark; the sheet stays open until Start or Cancel |
| 4 | Finish a workout | One screen, no scrolling: distance, time, average speed, pace, feet climbed, calories (estimate), average incline, a chart, last-time comparison |
| 5 | Treadmill: End workout after a few minutes | A summary sheet opens on the Treadmill tab; Done closes it |
| 6 | History → a new session | The same numbers, a larger chart, mile splits (after a mile) and "What changed"; old sessions still open |
| 7 | Setup → Body weight | Changing it changes the calories on the next summary |
| 8 | Lock the phone during a workout | The Live Activity shows − + ⏸ ⏹ buttons; − and + change the speed by 0.5 mph, ⏸ pauses and resumes, ⏹ stops the belt |
| 9 | Same, in treadmill mode (no workout) | − + ⏹ work the same |
| 10 | Watch the Live Activity icon | Standing when stopped, walking, running from 4 mph, hiking at 5% incline or more at walking speed |

Still to check from 0.7: the treadmill-mode Live Activity (ends 2 min after stopping), readiness, goal plans,
the workout editor, and deleting history.

## Repo layout
- `project.yml`: XcodeGen project (the `.xcodeproj` is generated in CI)
- `SportTread/`: iPhone app (Treadmill, Workouts, Coach, History folders; DesignSystem.swift for the look)
- `SportTreadLiveActivity/`: widget extension for the Lock Screen / Dynamic Island Live Activity
- `Shared/`: code used by both (Live Activity data)
- `Tests/LengthTests/`: the length and summary tests run on every build
- `.github/workflows/build.yml`: macOS build → unsigned IPA
- `web/treadmill.html`: working Web Bluetooth controller (Chrome/Edge)
- `design/AppIcon.svg`: app icon source (render with `tools/render_icon.py`)
- `tools/`: Python BLE scripts used to work out the treadmill protocol
