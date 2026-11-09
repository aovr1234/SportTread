# Andrew's SportTread

iPhone app that runs a ProForm 505 CST treadmill without iFit. See [PLAN.md](PLAN.md).

## Current stage: milestone 2 (workout engine)
Milestone 0 (signing and storage) passed 2026-11-09; milestone 1 (treadmill control) passed 2026-11-09.

### Get the IPA
1. GitHub → **Actions** → latest **Build unsigned IPA** run → download **SportTread-ipa**.
2. Unzip it to get `SportTread-unsigned.ipa`.
3. Upload it to Signulous, sign (no extra options), and install.

### Test on the treadmill
Connect on the **Treadmill** tab first. Stand on the side rails with the safety key in for the first run.

| # | Test | Pass when |
|---|---|---|
| 1 | **Workouts** tab → **Engine test** → **Start workout** | Live screen opens; belt starts and changes speed/incline every 30 s; the countdown, progress bar and highlighted step follow along |
| 2 | During the engine test, tap **Pause**, wait, then **Resume** | Belt stops on Pause; on Resume it restarts and returns to the step's speed and incline; the timer continues where it left off |
| 3 | Tap **Skip** | Jumps to the next step and applies its speed and incline |
| 4 | Let it finish | Belt stops; "Workout complete" with time and distance; **Done** closes it |
| 5 | Start any workout, then press **Stop on the console** | The workout pauses within a few seconds with "The belt stopped…" |
| 6 | Start any workout, then tap **STOP** in the app | Belt stops; "Ended early" summary |
| 7 | During a step, change speed on the console | The new speed holds until the next step starts |

## Repo layout
- `project.yml`: XcodeGen project (the `.xcodeproj` is generated in CI)
- `SportTread/`: iPhone app
- `.github/workflows/build.yml`: macOS build → unsigned IPA
- `web/treadmill.html`: working Web Bluetooth controller (Chrome/Edge)
- `design/AppIcon.svg`: app icon source (render with `tools/render_icon.py`)
- `tools/`: Python BLE scripts used to work out the treadmill protocol
