# Andrew's SportTread

iPhone app that runs a ProForm 505 CST treadmill without iFit. See [PLAN.md](PLAN.md).

## Current stage: build 0.7 (everything that doesn't need the heart-rate sensor)
Passed: milestones 0, 1, 2, 5, Live Activity, first field test. On hold: saving to Apple Health,
heart rate (waits for the Bluetooth sensor).

### Get the IPA
1. GitHub → **Actions** → latest **Build unsigned IPA** run → download **SportTread-ipa**.
2. Unzip it to get `SportTread-unsigned.ipa`.
3. Upload it to Signulous, sign (no extra options), and install.

### Test
| # | Test | Pass when |
|---|---|---|
| 1 | Workout screen: tap the Speed/Incline ▲▼ | ±0.1 mph / ±0.5%; the number stays green until the treadmill confirms |
| 2 | Hold a tile, slide up/down, let go | Value scrolls with haptic ticks (faster the further you slide); one change when you let go |
| 3 | Change speed in two steps in a row | Offer: "Lower/Raise the rest of the workout by … mph?" |
| 4 | STOP during a workout | Belt stops, incline stays, Resume / End workout appear |
| 5 | End workout (workout screen or Treadmill tab) | Incline goes to 0%, belt stops, summary shows, session appears in History |
| 6 | Treadmill tab: Start, leave the app | Treadmill Live Activity (speed, incline, time, distance); it ends 2 min after the belt stops |
| 7 | Workout screen → Coach → Easier / Shorter | Applies at once with "Applied: …" |
| 8 | Coach → Harder / Longer, or type/say "add a hill" | Shows an offer you confirm with Apply |
| 9 | Hold the mic, speak, let go | Your words appear in the box to check before sending (asks for mic/speech permission the first time) |
| 10 | Coach tab → Check-ins every 5 min, run a workout | "How's it feeling?" appears; Hard eases off at once |
| 11 | History tab | Sessions with effort and "What changed"; swipe to delete one; Delete all asks first |
| 12 | Workouts tab → + / Edit / Edit a copy | Editor saves to My workouts; out-of-range values block Save |
| 13 | Coach tab → Readiness | Shows Ready / Moderate / Take it easy from watch/Oura data (asks for Health read access) |
| 14 | Coach tab → Start a plan → Create this workout | Week and progress show; the created workout follows the plan |

## Repo layout
- `project.yml`: XcodeGen project (the `.xcodeproj` is generated in CI)
- `SportTread/`: iPhone app (Treadmill, Workouts, Coach, History folders; DesignSystem.swift for the look)
- `SportTreadLiveActivity/`: widget extension for the Lock Screen / Dynamic Island Live Activity
- `Shared/`: code used by both (Live Activity data)
- `.github/workflows/build.yml`: macOS build → unsigned IPA
- `web/treadmill.html`: working Web Bluetooth controller (Chrome/Edge)
- `design/AppIcon.svg`: app icon source (render with `tools/render_icon.py`)
- `tools/`: Python BLE scripts used to work out the treadmill protocol
