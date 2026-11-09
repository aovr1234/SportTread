# Andrew's SportTread

iPhone app that runs a ProForm 505 CST treadmill without iFit. See [PLAN.md](PLAN.md).

## Current stage: milestone 1 (treadmill control)
Milestone 0 (signing and storage) passed on 2026-11-09. The app now controls the treadmill; the
milestone 0 checks live on in the **Setup** tab.

### Get the IPA
1. GitHub → **Actions** → latest **Build unsigned IPA** run → download **SportTread-ipa**.
2. Unzip it to get `SportTread-unsigned.ipa`.
3. Upload it to Signulous, sign (no extra options), and install.

### Test on the treadmill
Stand on the side rails with the safety key clipped in for the first runs.

| # | Test | Pass when |
|---|---|---|
| 1 | Treadmill on, other apps closed; tap **Connect** | After about 20 s: "Connected, belt stopped", readings show 0.0 mph |
| 2 | Tap **Start at 1.0 mph** | Belt starts; app and console both show 1.0 mph; moving time counts up |
| 3 | Tap **+0.5** a few times, then **3 mph** | Belt follows within a second or two; app matches the console |
| 4 | Tap **Incline +1** twice, then **−1** twice | Deck rises to 2% and back; the app's incline follows |
| 5 | Change speed on the console | The app shows the new speed and "Speed changed on the console" |
| 6 | Tap **STOP** | Belt stops within about a second |
| 7 | Start again, then **Disconnect** | The app stops the belt first, then disconnects |

## Repo layout
- `project.yml`: XcodeGen project (the `.xcodeproj` is generated in CI)
- `SportTread/`: iPhone app
- `.github/workflows/build.yml`: macOS build → unsigned IPA
- `web/treadmill.html`: working Web Bluetooth controller (Chrome/Edge)
- `design/AppIcon.svg`: app icon source (render with `tools/render_icon.py`)
- `tools/`: Python BLE scripts used to work out the treadmill protocol
