# Andrew's SportTread

iPhone app that runs a ProForm 505 CST treadmill without iFit. See [PLAN.md](PLAN.md).

## Current stage: build 0.7.3 (diagnostics log, workout recovery, better workouts)
Passed so far: milestones 0, 1, 2, 5, the Live Activity and two field tests. On hold: saving to Apple Health,
heart rate (waits for the Bluetooth sensor), plan reminders and speed guards.

### Get the IPA
1. GitHub → **Actions** → latest **Build unsigned IPA** run → download **SportTread-ipa**.
2. Unzip it to get `SportTread-unsigned.ipa`.
3. Upload it to Signulous, sign (no extra options), and install.

Every build first runs the length tests (`Tests/LengthTests`): every workout length from 10 to 90 minutes,
simulated AI workouts, live edits and reading a length from text must come out exact, or the build fails.

### Test (0.7.3; the 0.7.2 list still applies: pacing, resume, summary, Live Activity buttons)
| # | Test | Pass when |
|---|---|---|
| 1 | Setup → Diagnostics | Lines appear as you use the app (connects, commands, steps); Share log sends `diagnostics.log`; Clear empties it |
| 2 | Coach tab → type in the notes box | A **Done** button sits above the keyboard and hides it; dragging the list also hides it |
| 3 | Create a 60-min walk | Warm-up and cool-down each ramp over two steps; the middle is several blocks (about 7 min) with different speeds; steps are whole 30 s marks (no 5:25); the total is 60:00; no flat 3.0 mph |
| 4 | Edit workout screen | Edit sits in the top bar; the time, speed and incline − / + pills have space between them; a 5:25 step goes to 5:30 on the first tap |
| 5 | Setup → Calories | Off hides the kcal figure (top speed takes its place) on the finished screen and in History; the weight field hides |
| 6 | Start a workout, swipe the app away or let iOS close it, reopen within 4 hours | The workout screen is back with "Welcome back" (belt still running) or paused with a Resume button; time and step are right; the Diagnostics log shows the recovery |
| 7 | Same, then look at the Lock Screen | One Live Activity (the workout's), not two |
| 8 | End a workout | No treadmill-mode session or second Live Activity appears afterwards |
| 9 | A check-in comes up during a workout (Coach tab: every 5 min) | The Lock Screen / Dynamic Island show Easy / Good / Hard buttons; tapping one answers it like the in-app card |

Still to check from 0.7: the treadmill-mode Live Activity (ends 2 min after stopping), readiness, goal plans,
the workout editor, and deleting history.

## Repo layout
- `project.yml`: XcodeGen project (the `.xcodeproj` is generated in CI)
- `SportTread/`: iPhone app (Treadmill, Workouts, Coach, History folders; DesignSystem.swift for the look)
- `SportTreadLiveActivity/`: widget extension for the Lock Screen / Dynamic Island Live Activity
- `Shared/`: code used by both (Live Activity data)
- `Tests/LengthTests/`: the length, summary, workout shape and treadmill command tests run on every build
- `.github/workflows/build.yml`: macOS build → unsigned IPA
- `web/treadmill.html`: working Web Bluetooth controller (Chrome/Edge)
- `design/AppIcon.svg`: app icon source (render with `tools/render_icon.py`)
- `tools/`: Python BLE scripts used to work out the treadmill protocol
