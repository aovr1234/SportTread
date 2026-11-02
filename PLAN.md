# Andrew's SportTread: Plan

Status: planning, nothing built yet. Last updated 2026-11-01.

## Name
- App name: **Andrew's SportTread** (in-app title, splash, settings, Health source name).
- Home-screen label: **SportTread**. iOS cuts off names longer than about 12 characters, so the full name would show as "Andrew's Spo…".
- Bundle ID: `com.andrew.sporttread` (watch app: `com.andrew.sporttread.watchkitapp`).

## Design: modern and sporty
- **Dark first**, near-black background, with a light mode available. Easy on the eyes, and readings stand out from a running distance.
- **One accent colour:** high-energy volt green `#C6FF00` for primary actions and progress. **STOP is always red** and never used for anything else.
- **Heart-rate zone colours**, used consistently on phone, watch and charts: Z1 blue, Z2 green, Z3 yellow, Z4 orange, Z5 red.
- **Type:** SF Pro, heavy weight with tabular digits for live numbers (speed, HR, time) so they don't jitter; SF Pro Rounded for labels. On the watch, SF Compact.
- **Glanceable live screen:** the most important number (HR in an HR workout, speed otherwise) huge in the centre, in a ring that fills toward the target and changes colour with the zone. Speed, incline, time and distance in large tiles around it. Current and next step in a bar at the bottom.
- **Big tap targets** (at least 60 pt during a workout) so you can hit them while moving.
- **Motion and feel:**
  - Smooth number roll-overs.
  - The ring pulses with each heartbeat.
  - Haptics on step changes, command confirmations and alerts.
  - A 3-2-1 countdown before the belt starts.
- **Live charts:** HR vs target line, speed/incline area chart (Swift Charts), on the live screen and in history.
- **Lock screen and Dynamic Island:** a Live Activity with HR, speed and time left, so the phone can stay locked on the treadmill tray.
- **Watch:** the same zone-coloured ring, HR huge, and Pause / End as full-width buttons.
- **App icon:** a stylised treadmill belt forming a pulse line, volt green on black.

## Goal
An iPhone app plus an Apple Watch companion that runs a ProForm 505 CST treadmill without iFit:
automated workouts, heart-rate hold (e.g. 150 bpm) from the Apple Watch, results saved to Apple Health,
and app data kept in a Files/iCloud Drive folder that survives deleting the app.

## Architecture
```
Apple Watch app ──HR ~1/s (WatchConnectivity)──▶ iPhone app ──Bluetooth LE──▶ ProForm 505 CST
 (HKWorkoutSession, records the Health workout)    (control, workouts, storage)
```

### 1. Treadmill connection (iPhone, CoreBluetooth)
Verified on the user's treadmill, 2026-11-01:
- BLE name `I_TL`, iFit service `00001533-1412-efde-1523-785feabcd123` (TX `…1534`, RX `…1535`). Never write to the firmware-update (DFU) service.
- Handshake: QZ profile `proform_treadmill_cst_505_pftl59420_0` (the plain 505 CST profile's unlock key is refused).
- Polls: 3-packet messages, sent continuously. Never split a message; commands go only between messages.
- Start: QZ 505 CST start1–5 (belt starts at 1.0 mph, no console button needed).
- Speed / incline: single write message, checksum = sum of bytes 6–13. Value ×100 (km/h, %).
- Stop: workout mode 3 (pause). Speed 0 and mode 1 are refused.
- Status replies give actual speed and incline (the deck position is tracked live) and show console changes.
- Reference implementation: `treadmill.html` (Web Bluetooth version, working).
- Not done: fan control (not needed).

### 2. Heart rate
- Watch app runs an indoor run/walk `HKWorkoutSession` and sends HR to the phone about once a second; the phone shows how old the latest reading is.
- Fallback: any standard Bluetooth heart-rate strap.

### 3. Workout engine
- A workout is a list of steps: duration plus either a fixed speed/incline or a heart-rate target.
- Built-in: steady, intervals, hills, heart-rate hold.
- Controls: pause, skip, extend step; STOP always on screen.

### 4. Heart-rate hold
Defaults follow common practice: ACSM intensity guidance, the Tanaka max-HR formula, and how commercial gym treadmill HR programs behave. All of them can be changed in settings.

**Max heart rate (HRmax)**
- Tanaka formula: 208 − 0.7 × age, with age read from Apple Health (asked at setup if missing). It's more accurate than 220 − age, especially over 40.
- A measured max HR entered by the user replaces the formula.

**Target range**
| Zone | % HRmax | Use |
|---|---|---|
| Moderate | 64–76% | default suggestions |
| Vigorous | 77–85% | allowed |
| Above 85% | > 85% | needs an explicit confirmation |
- Example, age 35: HRmax 184. 150 bpm is 82%, in the vigorous range, so no confirmation needed.

**How it adjusts** (incline first, like commercial HR programs)
- The user picks a comfortable walking/jogging speed. The app holds that speed and changes incline first, because incline changes don't alter stride and are easier on the joints.
- Speed changes only when incline is at 0% and HR is still too high, or at its maximum and HR is still too low.
- Warm-up: no adjustments for the first 3 minutes while HR settles.
- Then every 30 s, compare the 15-second average HR with the target:
  - More than 10 bpm off: incline ±1% (speed ±0.2 mph)
  - 3–10 bpm off: incline ±0.5% (speed ±0.1 mph)
  - Within ±3 bpm: no change
- Cool-down at the end: 3–5 minutes stepping down to 0% incline and an easy walking speed, then stop.

**Safety limits**
- Treadmill limits: 0.5–10 mph and 0–10% incline (505 CST rated range). Automatic adjustments are also capped at 2 mph above the starting speed unless the user raises it.
- HR at or above 90% of HRmax: drop incline to 0% and slow down at once.
- HR at or above 95% of HRmax for 30 s, or above 100%: start the cool-down, then stop.
- No HR for 15 s: hold speed and incline. No HR for 45 s: slow to an easy walk and show an alert.
- Never increases effort without a fresh HR reading.
- If the belt stops (console Stop, safety key), the workout ends cleanly.

### 5. Apple Health
- One workout per session, recorded by the watch's workout session (indoor run/walk).
- Heart rate: recorded by the watch. The app does not write it again (avoids duplicates).
- Distance: the watch's arm-swing estimate is switched off. Treadmill-measured distance is written into the same workout.
- Also written: speed samples, elevation gained (incline × distance), active calories calculated from speed/incline/weight (watch estimate switched off), segments per step, pause/resume events, metadata (indoor, workout name, HR target).
- Read: weight (calories), age / resting HR / max HR (zones, default max-HR limit), past workouts (history after reinstall).

### 6. App data storage (survives app deletion)
- Data stays outside the app's own folder, so deleting the app never deletes it.
- **First-launch setup, before anything else:**
  1. The app explains that it needs a folder for settings and workout history, and recommends iCloud Drive.
  2. "Choose or create folder" opens the standard Files folder picker at iCloud Drive. The user taps New Folder (suggested name: `Treadmill`) or picks an existing one. A folder under On My iPhone also works, but stays on that phone only.
  3. If the folder already has app data (e.g. after a reinstall), the app offers to restore it. Otherwise it creates the folder layout below.
  4. The app remembers the folder (security-scoped bookmark), so this only happens once per install.
- Folder layout (plain JSON, readable in the Files app):
  ```
  Treadmill/
    settings.json   limits, HR targets, controller tuning, treadmill info
    workouts/       custom programs
    history/        per-second logs (HR, target, speed, incline) per session
  ```
- Saves automatically after every settings change and at the end of every workout.
- Settings screen shows the current folder, the last-saved time, and "Change folder".
- If the folder is unreachable (e.g. iCloud offline), the app keeps a local copy, shows a warning, and syncs when it's back.
- Manual "Export backup" (one file via the share sheet) as an extra safety net.
- Not used: CloudKit / iCloud key-value sync. They need the signing account's iCloud setup, which Signulous controls.

### 7. Performance tracking and AI coach
**Performance tracking (on the phone, offline, free)**
- Aerobic efficiency: speed/incline held at a given HR, trended over weeks.
- HR drift: rise in HR during steady efforts.
- HR recovery: HR drop in the first 60 s after the main effort.
- Training load per workout (HR-based) and this week vs. the last 4 weeks.
- Readiness: resting HR, HRV and sleep read from Apple Health.
- Perceived effort: quick 1–10 rating after each workout.
- Stored with the workout logs in the data folder.

**AI coach (Claude via the Anthropic API)**
- What it does:
  - Writes the next workout from recent performance, readiness and the user's goal (e.g. "jog a 5K in 8 weeks").
  - Builds multi-week plans and adapts them to missed days or faster progress.
  - Writes a short post-workout debrief; the user can ask follow-up questions.
- What it receives: a compact summary (metrics above, recent workouts, goal, limits). Never raw Health exports, never the API key.
- What it returns: workouts in the app's step format (structured JSON) plus a short coaching note.
- **Safety:** the AI never controls the treadmill. Every AI workout is validated against the same caps and HR rules (section 4) before it can run. Anything outside them is rejected, and the user always sees and starts the workout themselves.
- Setup:
  - The user's own Anthropic API key, entered in settings and stored in the iOS Keychain (not in the data folder).
  - Opt-in, with a clear note that workout summaries are sent to Anthropic.
- Offline or API unavailable: falls back to rule-based progression (e.g. target hit easily 3 times, so +0.5% incline next time).

### 8. Screens
- **iPhone:** first-launch folder setup, connect, workout list, workout editor, live workout (HR and target, speed, incline, time, distance, current/next step, STOP), history, settings.
- **Watch:** HR and target, current step and time left, plus controls:
  - **Pause:** one tap stops the belt at once (pause mode) and pauses the workout and the Health recording.
  - **Resume:** a 3-second countdown, then the belt restarts and returns to the speed and incline from before the pause.
  - **End:** asks for confirmation, then stops the belt, ends the workout and saves it to Health and the data folder.
  - Commands go to the phone over WatchConnectivity (usually under 1 s). The watch shows whether the phone is reachable. If it isn't, it shows "Use the console Stop button" instead of buttons that would do nothing.
  - Haptic tap when a command is confirmed by the treadmill.

## Build and install (no Mac)
- Project kept as text in a GitHub repo (XcodeGen or similar).
- GitHub Actions macOS runner builds an unsigned `.ipa` on every push.
- The user signs it with Signulous and installs it.
- Biggest risk: whether Signulous keeps HealthKit and the embedded watch app when it re-signs.

## Milestones
| # | Milestone | Done when |
|---|---|---|
| 0 | Signing and storage test | After a Signulous install: watch HR shows on the phone; a test workout with treadmill distance appears in Fitness; data saved to a newly created iCloud Drive folder is restored after delete and reinstall |
| 1 | Treadmill control | Phone does start, speed, incline and stop, with live readout matching the console |
| 2 | Workout engine | A preset interval workout runs by itself, start to finish |
| 3 | Heart-rate hold | Holds 150 ±5 bpm for 10+ minutes in a real session |
| 4 | Health and polish | Full Health write, history, workout editor, export, watch controls |
| 5 | AI coach | Performance metrics trend correctly over several workouts; Claude proposes a next workout that passes the safety checks and runs; offline fallback works |

## Limits of testing
- No iOS build or simulator on Windows: every build is tested on the user's iPhone.
- iPhone Bluetooth timing may differ from Windows; milestone 1 checks it.
- HR controller settings need tuning on real runs.

## Decisions
- Limits and HR-hold behaviour: common-practice defaults (see section 4), adjustable in settings.
- Signing: Signulous, most likely on a paid developer account. Paid accounts can sign apps with HealthKit and an embedded watch app, but whether Signulous's re-signing keeps them is only confirmed by milestone 0.

- Watch: pause, resume and end controls (see section 8).
- AI coach: Claude via the user's Anthropic API key, on top of on-device performance tracking (section 7, milestone 5).

## Open questions
None. The plan is ready for milestone 0.
