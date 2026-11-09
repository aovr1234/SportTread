# Andrew's SportTread: Plan

Status: milestones 0, 1, 2 passed (2026-11-09); milestone 5 (AI coach) built, testing; milestone 3 waits for the HR sensor; milestone 4 next. Last updated 2026-11-01.

## Name
- App name: **Andrew's SportTread** (in-app title, splash, settings, Health source name).
- Home-screen label: **SportTread**. iOS cuts off names longer than about 12 characters, so the full name would show as "Andrew's Spo…".
- Bundle ID: `com.andrew.sporttread`. Signulous signs it under its own shared ID, so Apple Health labels the app "Spotify" (cosmetic; see Decisions).

## Design: modern and sporty
- **Dark first**, near-black background, with a light mode available. Easy on the eyes, and readings stand out from a running distance.
- **One accent colour:** high-energy volt green `#C6FF00` for primary actions and progress. **STOP is always red** and never used for anything else.
- **Heart-rate zone colours**, used consistently on the live screen and charts: Z1 blue, Z2 green, Z3 yellow, Z4 orange, Z5 red.
- **Type:** SF Pro, heavy weight with tabular digits for live numbers (speed, HR, time) so they don't jitter; SF Pro Rounded for labels.
- **Glanceable live screen:** the most important number (HR in an HR workout, speed otherwise) huge in the centre, in a ring that fills toward the target and changes colour with the zone. Speed, incline, time and distance in large tiles around it. Current and next step in a bar at the bottom.
- **Big tap targets** (at least 60 pt during a workout) so you can hit them while moving.
- **Motion and feel:**
  - Smooth number roll-overs.
  - The ring pulses with each heartbeat.
  - Haptics on step changes, command confirmations and alerts.
  - A 3-2-1 countdown before the belt starts.
- **Live charts:** HR vs target line, speed/incline area chart (Swift Charts), on the live screen and in history.
- **Lock screen and Dynamic Island:** a Live Activity with HR, speed and time left, so the phone can stay locked on the treadmill tray.
- **App icon:** a stylised treadmill belt forming a pulse line, volt green on black.

## Goal
An iPhone app that runs a ProForm 505 CST treadmill without iFit: automated workouts, optional
heart-rate hold (e.g. 150 bpm), results saved to Apple Health, and app data kept where it survives
deleting the app. No watch app: Signulous signs for the iPhone only, so a watch app can't be installed.

## Architecture
```
Optional HR source ──▶ iPhone app ──Bluetooth LE──▶ ProForm 505 CST
 (Apple Health, or a      (control, workouts,
  Bluetooth HR monitor)    storage, Health)
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

### 2. Heart rate (optional add-on, deferred until the Bluetooth sensor arrives)
Removed from the app for now (2026-11). The Bluetooth monitor code is in git history (commit 12afdc8, `HeartRateMonitor.swift`) and comes back when the sensor arrives.
Setting: **Off** (default), **Apple Watch (via Health)**, or **Bluetooth monitor**. Treadmill workouts work with it off; HR workouts need a source.
- **Apple Watch (via Health):** tested 2026-11: the watch syncs heart rate only after the workout ends, so this can't be a live source. Kept only for reading HR afterwards; heart-rate hold requires a Bluetooth monitor.
- **Bluetooth monitor:** any standard BLE heart-rate monitor (service 0x180D), about 1 reading/s. A chest strap or armband works. Watch "broadcast" apps (HeartCast, Echo) relay through the iPhone, and an iPhone can't connect to its own Bluetooth broadcast, so they can't feed the app on the same phone.
- HR hold accepts a reading only if it's at most 15 s old (section 4); a source that's slower than that can show HR but not drive HR hold.

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
- The phone saves one workout per session (indoor walk/run) with treadmill-measured distance.
- Heart rate: from a Bluetooth monitor, the app writes the HR samples into its workout.
- One recorder per session: SportTread records the workout; don't also start one in Apple's Workout app. No custom duplicate guard. Health's data source priority already keeps daily totals (distance, energy) from double counting, but a second workout would still show in Fitness. Put SportTread (listed as "Spotify", see Decisions) at the top of the Walking + Running Distance sources so treadmill distance wins over the watch estimate.
- Also written: speed samples, elevation gained (incline × distance), active calories calculated from speed/incline/weight, segments per step, pause/resume events, metadata (indoor, workout name, HR target).
- Read: weight (calories), age / resting HR / max HR (zones, default max-HR limit), past workouts (history after reinstall).

### 6. App data storage
- The app creates its data folder itself; there is no folder picker (under Signulous signing the Files picker's Open never returns).
  - **iCloud Drive › SportTread** if the signing provides the app's iCloud container. Survives deleting the app.
  - Otherwise **On My iPhone › SportTread**, visible in the Files app but deleted with the app.
- **Back up to Files** exports a copy of the data to any location (e.g. iCloud Drive); **Restore from backup** imports one. Both use copy-mode pickers, which don't need folder access.
- Folder layout (plain JSON, readable in the Files app):
  ```
  SportTread/
    settings.json   limits, HR targets, controller tuning, treadmill info
    workouts/       custom programs
    history/        per-second logs (HR, target, speed, incline) per session
  ```
- Saves automatically after every settings change and at the end of every workout.
- Workouts themselves are also in Apple Health, which survives deleting the app.

### 7. Performance tracking and AI coach
**Performance tracking (on the phone, offline, free)**
- Aerobic efficiency: speed/incline held at a given HR, trended over weeks.
- HR drift: rise in HR during steady efforts.
- HR recovery: HR drop in the first 60 s after the main effort.
- Training load per workout (HR-based) and this week vs. the last 4 weeks.
- Readiness: resting HR, HRV and sleep read from Apple Health.
- Perceived effort: quick 1–10 rating after each workout.
- Stored with the workout logs in the data folder.

**AI coach (Apple Intelligence, on-device)**
- Runs on Apple's on-device model (Foundation Models framework, iOS 26+, Apple Intelligence on). The user's iPhone 17 Pro supports it. Free, private, works offline; nothing leaves the phone.
- Still to confirm: that the framework works in a Signulous-signed app (milestone 5 checks this first).
- What it does:
  - Creates workouts ("routes") from a short request plus the user's history: see **Workout creation** below.
  - Suggests the next workout after each one, from completion, perceived effort and readiness.
  - Writes a short post-workout debrief.
  - Multi-week plans in simple form (e.g. 3 workouts a week, building over 4–8 weeks), regenerated week by week since the model is small.
- **Safety:** the AI never controls the treadmill. Every AI workout is validated against the same caps and HR rules (section 4) before it can run. Anything outside them is rejected, and the user always sees and starts the workout themselves.
- If Apple Intelligence is off or unavailable: built-in templates plus rule-based progression (e.g. target hit easily 3 times, so +0.5% incline next time).
- Claude dropped from the plan (2026-11); could return later as an optional upgrade.

**Workout creation ("routes")**
1. **Ask:** the user picks **how long** first (quick 15/20/30/45/60 or any 10–90 min), then optionally type (**Recommend** lets the coach pick from recent history), intensity and a note. Or types what they want, e.g. "30-minute hill walk, moderate", "intervals, 20 min, push me", "easy recovery". Quick chips for duration, type (walk / jog / intervals / hills) and intensity (easy / moderate / hard).
2. **Context:** the app gives the model a compact summary: goal, last ~10 workouts (duration, distance, max speed/incline reached, perceived effort, completed or stopped early), the user's limits, and the treadmill's range.
3. **Structured output:** guided generation fills a fixed workout type (name, short description, steps: duration, speed, incline, label), so the model can only return a valid workout, never free text to parse. Speed, incline and duration are constrained to the allowed ranges.
4. **Validate:** the app checks every step against the caps, adds a warm-up and cool-down if missing, and limits jumps between steps (e.g. at most +1.5 mph or +3% incline at once).
5. **Preview:** a speed/incline chart, total time, estimated distance and calories. The user can tweak steps, regenerate, or save.
6. **Run and learn:** after the workout, a 1–10 effort rating plus what actually happened (completed, stopped early, manual speed changes on the console) feed the next suggestion.
- Saved workouts go to `workouts/` in the data folder as plain JSON; hand-made workouts use the same editor.

### 8. Screens
- **iPhone:** connect, workout list, workout editor, live workout (HR and target, speed, incline, time, distance, current/next step, STOP), history, settings.

## Build and install (no Mac)
- Project kept as text in a GitHub repo (XcodeGen or similar).
- GitHub Actions macOS runner builds an unsigned `.ipa` on every push.
- The user signs it with Signulous and installs it.
- Signulous signs for the iPhone only: HealthKit works, a watch app can't be installed, and the app's signing ID is shared with other sideloaded apps.

## Milestones
| # | Milestone | Done when |
|---|---|---|
| 0 | Signing and storage test | After a Signulous install: HR shows from the chosen source (and the Health delay is measured); a test workout with treadmill distance appears in Fitness; data survives delete and reinstall (iCloud folder or backup/restore) |
| 1 | Treadmill control | Phone does start, speed, incline and stop, with live readout matching the console |
| 2 | Workout engine | A preset interval workout runs by itself, start to finish |
| 3 | Heart-rate hold (after the Bluetooth sensor arrives) | Holds 150 ±5 bpm for 10+ minutes in a real session |
| 4 | Health and polish | Full Health write, history, workout editor, backup/restore |
| 5 | AI coach | Apple Intelligence works in the Signulous-signed app; it creates a workout from a short request that passes validation and runs; next-workout suggestions follow effort ratings; template fallback works when it's unavailable |

## Limits of testing
- No iOS build or simulator on Windows: every build is tested on the user's iPhone.
- iPhone Bluetooth timing may differ from Windows; milestone 1 checks it.
- HR controller settings need tuning on real runs.

## Decisions
- Limits and HR-hold behaviour: common-practice defaults (see section 4), adjustable in settings.
- Signing: Signulous. It signs for the iPhone only and under a signing ID shared with the user's sideloaded Spotify, so Health labels the app "Spotify" and Health permissions are shared with that app. "Match provisioning identifier" would replace Spotify, so it isn't used.
- No watch app (Signulous can't sign one); heart rate is an optional add-on (section 2).
- AI coach: Apple Intelligence on-device (Foundation Models), on top of on-device performance tracking (section 7, milestone 5). Claude dropped.
- Heart rate: removed from the app until the Bluetooth sensor arrives; HR hold (milestone 3) waits for it.

## Open questions
None. The plan is ready for milestone 0.
