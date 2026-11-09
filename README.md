# Andrew's SportTread

iPhone app that runs a ProForm 505 CST treadmill without iFit. See [PLAN.md](PLAN.md).

## Current stage: milestone 5 (AI coach)
Passed so far: milestone 0 (signing and storage), 1 (treadmill control), 2 (workout engine, engine test).
Milestone 3 (heart-rate hold) waits for the Bluetooth sensor; milestone 4 (Health and polish) comes next.

### Get the IPA
1. GitHub → **Actions** → latest **Build unsigned IPA** run → download **SportTread-ipa**.
2. Unzip it to get `SportTread-unsigned.ipa`.
3. Upload it to Signulous, sign (no extra options), and install.

### Test
| # | Test | Pass when |
|---|---|---|
| 1 | **Setup** tab → **About this build** → **Apple Intelligence** | Says "available" (if not, the coach uses its built-in rules; note what it says) |
| 2 | **Coach** tab → pick **20** minutes, **Recommend**, **Moderate** → **Create workout** | A preview opens; the green note says "Created with Apple Intelligence" (or why the built-in rules were used); total time is 20 min with a warm-up and cool-down |
| 3 | Try a few requests: different minutes, **Hills** / **Intervals**, **Hard**, a note like "knees are sore" | Each workout matches the request and stays within sensible speeds |
| 4 | Tap **Save** on a created workout | It appears under **My workouts** on the Workouts tab (swipe left to delete) |
| 5 | Connect, **Start workout** on a created one, finish or STOP it, and rate the effort | The rating buttons highlight; the next **Recommend** takes it into account |

## Repo layout
- `project.yml`: XcodeGen project (the `.xcodeproj` is generated in CI)
- `SportTread/`: iPhone app
- `.github/workflows/build.yml`: macOS build → unsigned IPA
- `web/treadmill.html`: working Web Bluetooth controller (Chrome/Edge)
- `design/AppIcon.svg`: app icon source (render with `tools/render_icon.py`)
- `tools/`: Python BLE scripts used to work out the treadmill protocol
