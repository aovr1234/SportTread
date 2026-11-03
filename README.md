# Andrew's SportTread

iPhone + Apple Watch app that runs a ProForm 505 CST treadmill without iFit. See [PLAN.md](PLAN.md).

## Current stage: milestone 0 (signing and storage test)
A small test app that checks that Signulous signing keeps everything the real app needs.

### Get the IPA
1. GitHub → **Actions** → latest **Build unsigned IPA** run → download **SportTread-ipa**.
2. Unzip it to get `SportTread-unsigned.ipa`.
3. Upload it to Signulous, sign, and install.

### Test on the iPhone
| # | Test | Pass when |
|---|---|---|
| 1 | Tap **Request Health access**, allow everything | Status says "Granted: can save workouts" |
| 2 | Install the watch app (Watch app on iPhone → SportTread → Install), then tap **Start workout on watch** | The watch opens a workout and the phone shows your bpm, updating every few seconds |
| 3 | Tap **Save test workout (0.50 mi)** | A 10-min indoor walk with 0.50 mi shows in the Fitness app |
| 4 | Tap **Choose folder** → go to iCloud Drive → tap **Open** | "Set up iCloud Drive/SportTread. Test data saved." and `SportTread/settings.json` is visible in the Files app |
| 5 | Delete the app, reinstall, tap **Choose folder** → iCloud Drive → **Open** | "Restored data saved …" with the earlier time |

On the watch, **End** saves the workout to Health and **Discard** throws it away.
On the phone, **Delete test workouts** removes the test workouts the phone app saved.

## Repo layout
- `project.yml`: XcodeGen project (the `.xcodeproj` is generated in CI)
- `SportTread/`: iPhone app
- `SportTreadWatch/`: Apple Watch app
- `.github/workflows/build.yml`: macOS build → unsigned IPA
- `web/treadmill.html`: working Web Bluetooth controller (Chrome/Edge)
- `tools/`: Python BLE scripts used to work out the treadmill protocol
