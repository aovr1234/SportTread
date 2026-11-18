# Andrew's SportTread: Plan

Status: 0.7.5 (fixes 27 and 28: warm-up and cool-down only at the ends, the chosen type is checked) built 2026-11-17; 0.7.4 (fix 26, shorter and distinct warm-up and cool-down) built 2026-11-17; 0.7.3 (fixes 16-22, 24, 25: calories switch, keyboard, proportionate workouts, workout recovery, check-in on the Live Activity, editor layout, diagnostics log, command and shape tests) built 2026-11-17, untested; 0.7.2 (fixes 10-15: command pacing, plan goal picker, workout summary, Live Activity buttons and figure, resume reliability) built 2026-11-17, untested; 0.7.1 built 2026-11-11; milestones 0, 1, 2 passed (2026-11-09); milestone 5 (AI coach) passed, Live Activity works; connection reliability built, testing; milestone 3 waits for the HR sensor; milestone 4 next. Last updated 2026-11-01.

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
- **Lock screen and Dynamic Island:** a Live Activity during workouts (built 2026-11): step, countdown, speed, incline, progress, next step; HR added with the sensor. Runs in a widget extension, which Signulous must sign.
  - **Treadmill mode** (manual use, no workout; built in 0.7): its own Live Activity.
    - **Shows:** speed, incline, moving time (counting up on its own), distance; HR once the sensor arrives.
    - **Starts and ends:** starts when the belt starts. A stop shows "Stopped", and it ends after **2 minutes** stopped (or on End workout / Disconnect), with a summary (time, distance) for a minute.
    - **Dynamic Island:** compact shows a runner icon and the current speed; long-press shows speed, incline, time and distance.
    - **Workouts:** starting a workout replaces it with the workout Live Activity (only one at a time).
    - **Updates:** same rate limits as workouts (changes at once, readings every 3 s, a refresh every 60 s).
  - **Two Live Activities at once** (reported 2026-11-17; two causes found in the code; the user confirmed it happened while the workout was still running, so **the relaunch cause is the one that hit**, and workout recovery (fix 19c) is the priority):
  - **After a workout ends**, the belt still reports moving for a second or two while the Stop is on its way. Treadmill mode is no longer paused by then, so it starts a session and its own Live Activity next to the workout's "finished" card (which stays 60 s). The Treadmill tab then shows an open session.
  - **If iOS closed and relaunched the app** during the workout (Bluetooth restores the connection), the running workout was lost: nothing is saved, so the belt looked like a manual session and started a treadmill Live Activity while the old workout one stayed on the Lock Screen. This is the autosave/recovery proposal, now planned as fix 19.
  - **Recovery details** (decided 2026-11-17): the save holds wall-clock times, not just elapsed seconds. On relaunch, if the belt is reading speed above 0 the gap is counted as running time (saved time + now minus the save time, exact if the belt ran the whole time); if the workout was paused at the last save, nothing is added; if the belt may have been stopped and restarted in between, the recovered time is marked "about" and shown for the user to check. Distance for the gap is estimated from the last speed. The Live Activity countdown is date-based, so it stays right on its own.
  - **Background App Refresh: not doing it** (user decision 2026-11-17; not shown in Settings, and not shown to help). No `fetch` mode and no Setup status line. Motion & Fitness is not used either (the treadmill has no step sensor and it doesn't keep the app alive).
  - **Check-in buttons** (fix 20): Easy / Good / Hard on the Live Activity while a check-in is waiting.
- **Interactive buttons** (requested 2026-11-17; built in 0.7.2, untested: speed -/+ 0.5 mph, pause/resume (workouts), STOP): tappable buttons on both Live Activities, using App Intents (`LiveActivityIntent`) that run inside the app, so they reach the live treadmill connection (kept alive by the background mode).
    - **Buttons:** workout: − and + speed, Pause / Resume, STOP. Treadmill mode: − and + speed, STOP. Skip and incline stay in the app.
    - **Where:** the Lock Screen card (about four buttons) and the expanded Dynamic Island (about two). The compact and minimal Island only open the app. No sliders: buttons and toggles only.
    - **Speed step:** ±0.5 mph on the Lock Screen (small steps are fiddly there); 0.1 like the in-app tiles is the alternative, to be confirmed.
    - **Locked phone:** Pause and STOP work without unlocking (the safe direction); the speed buttons need the phone unlocked, so a pocket tap can't speed you up.
    - **Feedback:** each press updates the card at once with the new speed or "Paused".
    - **Depends on fix 10 (command cooldown):** speed presses go through the same throttle as the in-app tiles, so rapid taps are merged instead of flooding the treadmill.
    - **Risks:** buttons that run code in the app are untested under Signulous signing (the Live Activity itself works); if the app is swiped away the treadmill connection is gone and the buttons do nothing. The intents live in `Shared/` so the app and the widget extension both compile them.
    - Effort: about a day.
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

**Connection reliability (no random disconnects)** — built 2026-11:
- **Background:** `bluetooth-central` background mode, so polling and workouts keep running with the screen locked or in another app.
- **Auto-reconnect:** an unexpected drop keeps the same treadmill and reconnects by itself ("Reconnecting…"), retrying until it's back in range. Only Disconnect ends the connection for good.
- **Watchdog:** no status for 10 s while "connected" resets the link and reconnects.
- **State restoration:** if iOS relaunches the app in the background, the connection is picked back up (CoreBluetooth restore identifier).
- **Workouts during a drop:** the workout pauses with "Reconnecting…"; when the link is back it continues by itself if the belt kept running, or waits for Resume if the belt stopped.
- **Clear UI:** wherever the treadmill is needed but not connected, the app says "Treadmill disconnected" and shows a Connect button (no greyed-out buttons).
- The console Stop button and the safety key always work, connected or not.
- **Command pacing** (built in 0.7.2, untested; found 2026-11-17: tapping speed down in bulk timed the connection out):
  - Root cause: each tap queued its own command, and the session loop ran queued commands back to back without sending any status poll in between. About 25 queued commands take ~14 s, longer than the 10-second silence watchdog, so the app reset the connection.
  - **Cooldown:** speed and incline each send at most one command per second. The first tap goes out at once; taps during the cooldown only update the target, and the latest value is sent when the cooldown ends. (5.0 → 2.5 mph in 25 taps over 4 s sends about 5 commands, the last one within a second of the final tap.)
  - **Merge:** a new speed (or incline) command replaces one of the same kind still waiting in the queue.
  - **Never starve polling:** at most one command per poll message, so status replies keep arriving.
  - **Safe on stop:** a delayed command is dropped if the belt has stopped, on STOP, End workout, and disconnect. The tiles still show the target at once (green) until the treadmill reports it.
- **Resume reliability** (built in 0.7.2, untested; reported 2026-11-17: sometimes the incline doesn't execute after a workout is resumed):
  - **What Resume does today:** it sends the Start sequence (5 frames) and an extra "speed 1.0 mph" 1.5 s later, then as soon as the belt reports moving it queues the step's incline and speed. All of that goes out back to back with no status polls in between (about 3 s of silence), and a command that isn't due yet holds up the ones behind it. Nothing checks that the incline arrived, and a refusal (status 04) only shows as a toast on the Treadmill tab, never during a workout.
  - **Reproduced 2026-11-17 on the treadmill (PC copy of the app's exact queue):** a first start with the incline sent 6 s after Start worked (1.0%). After pause then Resume, the incline was sent ~1.5 s after Start: the console echoed 3.0% once, then went back to 0.0% and stayed there. No refusal (status 04) came back, so the console accepted the command and then wiped it. Cause: Start resets the incline to 0%, and it does so a few seconds after the Start frames, which erases any incline sent too early.
  - **Timing test 2026-11-17 (incline sent 2, 3, 4, 5, 6 s after Start, 2%):** 2 to 5 s held; 6 s was wiped back to 0.0% (and the earlier 1.5 s case was wiped too). So there is no clean safe delay: the console sometimes drops the incline, with no refusal. The only reliable cure is checking the reading and resending, so step 3 below is the key part.
  - **Fix:**
    1. Resume doesn't send the redundant "speed 1.0".
    2. After Start, wait until the belt reports moving plus a short settle (a fixed wait alone does not fix it: see the timing test above); then the incline first (the motor is slow), the speed 1 s later; one command per poll message (fix 10).
    3. Each speed and incline command is checked against the treadmill's next readings (the incline reading follows a commanded value within about 2 s) and resent up to 3 times; a "refused" reply also triggers a retry.
    4. If it still fails, the workout screen says so ("Incline didn't take. Tap ▲ to retry") and the deviation notes record it.
    5. A command that isn't due yet no longer blocks later ones.
  - **To check first:** a PC test of pause then resume that logs refusals and the incline reading.

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

**Live speed and incline controls on the workout screen** (planned, from the 2026-11 field test; not built yet)
- Two tiles under the progress section: **Speed** and **Incline**, each with ▲, the current value, ▼.
- **Tap:** speed ±0.1 mph, incline ±0.5%.
- **Press and hold, then slide up/down:** the value scrolls in the same steps (0.1 mph / 0.5%), with a haptic tick per step. Slow slide = precise; longer or faster slide = faster ticks; holding near the tile's top/bottom edge keeps counting and speeds up the longer you hold.
- **Send on release:** one command with the shown value; no flood of in-between commands. The value shows in volt green until the treadmill reports it, then white.
- **Limits:** 0.5–10 mph, 0–10%; scrolling stops at the edges.
- **Scope of a change:** lasts until the next step (default). After manual changes in two steps in a row, offer "Adjust the rest of the workout by the same amount?".

**End workout, with the incline back to 0%** (built in 0.7, sequence fix pending)
- **Treadmill mode** (manual use): an **End workout** button on the Treadmill tab, shown once the belt has run.
- **Workouts:** finishing or **End workout** on the live screen ends the workout.
- **What ending does, in order:**
  1. Stop the belt.
  2. Lower the incline to 0%.
  3. Save the session (history now; Apple Health in milestone 4).
  4. Show the summary (time, distance, effort rating).
  5. End the Live Activity with the summary.
- **STOP vs End workout:** STOP is the instant emergency stop. It stops the belt and **leaves the incline where it is**; during a workout it pauses the workout with **Resume** and **End workout**. The incline only goes back to 0% when the workout is ended.
- **Fix (bug found 2026-11):** 0.7 sends incline 0% and then Stop half a second later; the Stop (pause) freezes the incline motor, so the deck stays up.
  - **Sequence to use (user's choice):** Stop the belt, wait 2 s, send incline 0%. No waiting for readings.
  - Tested from the PC 2026-11: the console accepts incline 0% with the belt stopped, and the user confirmed the deck lowers to flat.
  - Readings while running show the *target* incline; after Stop they show the deck's real position.

**STOP button only when the belt is running** (note from 2026-11, not built yet)
- The red STOP shows only while the belt is moving (and during a workout's starting phase); hidden when connected but stopped.

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
- **Deviation notes** (planned, not built): whenever a workout departs from its plan, the app logs it with the step and time. The log is saved with the workout in history and summarized for the AI coach's context, e.g. "lowered speed in 3 of 8 fast intervals by 0.3 mph on average; skipped the cool-down".
  - Manual speed/incline changes (from/to), on the console or in the app
  - Skipped steps, pauses (length, reason), ending early
  - Console Stop/safety key, reconnects
  - "Adjust the rest" accepted or ignored, AI live edits
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

**Workout length guarantee** (hard requirement from the user, 2026-11: "if I ask for 60 minutes I'm expecting 60 minutes"; planned, not built)
- **One length, everywhere:** the requested minutes are the workout's total, including warm-up and cool-down, to the second (60 min = 60:00).
- **Text counts:** a length in the request text ("1 hr", "an hour", "45 minutes", "hour and a half") sets the length and moves the picker, so text and picker can't disagree. The Create button states it ("Create 60-min workout") and the preview shows the exact total.
- **Enforced, not trusted:** after the AI (or rules) make a workout, the app checks the total. If it's off it adjusts the steps (keeping each at least 30 s, merging the shortest steps if it must); if it still can't match, it falls back to the built-in rules. A workout that misses never reaches the preview.
- **Found 2026-11 in a test of the scaling logic:** 60-min requests always came out exact (0 of 300 misses), but short requests with many tiny steps could overshoot (a 30-min request missed 3 of 300 times, longer than asked) because of the 30 s minimum step. The fix above closes this.
- **Live edits:** Shorter / Longer become fixed −5 / +5 min (stated on the buttons). A typed or spoken length request ("make it an hour total") is enforced against the real remaining time the same way.
  - **Visible and reversible:** after every live edit the screen shows the new total next to the original ("Workout length 55:00, was 60:00") with an **Undo** button for 10 s (or until the next step starts).
  - **What the user's history file showed (2026-11-17):** a 60-min request ended at 33:30. No Shorter was used. The AI's "easier" edit at 22:30 is the only edit that could have cut time, and nothing checked the remaining length. The three Longer taps (24:50, 28:07, 32:45) added nothing: the AI said it "extended to match the total time" but the workout still ended at 33:30, and the last tap came with only the cool-down left, which Longer never touches. History stored only the final length, so the original is unknown.
  - **Rule:** every AI edit is checked against the remaining time. Easier/Harder and typed requests must leave the remaining duration unchanged (±5 s); Shorter/Longer must change it by exactly 5 min. An edit that misses is repaired or replaced by the fixed rules. What the AI says it did is never trusted.
  - **Longer with little left** adds a block of the last main step before the cool-down, so it always adds time.
  - Each logged edit records the total length before and after. Rapid taps on one tile (e.g. four incline taps in a second) are merged into one logged change.
  - **History** records the original planned length as well as the final one, plus each length change with its time. Top speed and incline show what was actually reached, not the plan's.
- **Proportion** (planned, fix 18; reported 2026-11-17: everything came out as 3.0 mph): a workout's shape is checked as well as its length. The main part needs several blocks that differ in speed or incline (more for longer workouts); warm-up and cool-down ramp over two steps; a flat result from Apple Intelligence is thrown away for the rules version. The rules version gets the same shape (today a walk is one flat step). Step lengths round to whole minutes, with the last main block absorbing the rest.
- **Plans** use the same path (the plan's minutes).
- **Checked automatically:** a test run on every build creates workouts for every length from 10 to 90 min (rules and simulated AI outputs) and fails the build if any total is off by even a second.
- Time actually spent: the workout is the planned running time; paused time doesn't count toward it. History shows planned vs. actual.

**Apple Intelligence during the workout** (planned, not built; chosen 2026-11)
- **A. Live editing on request**
  - Quick buttons on the live screen: **Easier**, **Harder**, **Shorter**, **Longer**, plus requests like "skip the hills", "my knees hurt", "add 5 minutes at the end", **typed or spoken**.
  - Speaking: a hold-to-talk mic button; speech is recognised on the device (Apple's Speech framework, on-device mode), shown as text before it's sent, so a misheard request can be corrected. Needs microphone and speech-recognition permission.
  - Apple Intelligence rewrites only the **remaining steps**; the current step can change only if the request is about now ("easier now").
  - The result goes through SafetyCheck, then shows a short preview, e.g. "Next 3 steps: −0.3 mph, hills capped at 4%".
  - Easing off applies right away; anything harder needs one tap to confirm.
  - Every edit is logged in the deviation notes.
- **B. Coaching from behaviour**
  - Watches the deviation notes as they happen. Repeated manual slow-downs, repeated stops at the same point, or skipped steps lead to an offer to adjust the rest ("You've eased off the last 3 intervals. Lower the remaining ones by 0.3 mph?").
  - Optional check-in every 5–10 minutes: "How's it feeling?" with **Easy / Good / Hard**, which nudges the upcoming steps the same way.
  - Offers only: nothing changes without a tap, except easing off on an explicit "Hard".
- **C. Spoken/on-screen coach messages:** skipped for now.
- Built on the existing pieces: the workout format, SafetyCheck, and the on-device model from milestone 5. If Apple Intelligence is unavailable, the quick buttons fall back to fixed rules (e.g. Easier = −0.3 mph and −1% on the remaining steps).

### 8. Screens
- **iPhone:** connect, workout list, workout editor, live workout (HR and target, speed, incline, time, distance, current/next step, STOP), history, settings.

### 8b. No-scroll layout (decided 2026-11, from the second field test: "too cluttered, I don't have to scroll in a session")
Both session screens fit on one phone screen with no scrolling. Each thing appears once; everything occasional lives in an overlay or sheet.
- **Treadmill screen**
  - Top: status dot and text, plus a ••• menu (Disconnect, "The console Stop button and the safety key always work").
  - Middle: the Speed and Incline tiles are the big readout *and* the controls (tap ▲▼, or hold and slide). They fill the height; numbers scale up.
  - One slim line: moving time and miles.
  - Bottom bar, always in the same place: **End workout** + **STOP** while the belt runs; **Start** (alone, or beside End workout in an open session) when stopped.
  - Messages (console changes, "Session saved") are toasts at the top that fade; no fine print on the screen.
  - The quick-speed chips are gone (hold-and-slide covers them).
- **Workout screen**
  - Top: name, elapsed / total, and the **profile chart as the progress bar**, with a marker for where you are.
  - Middle: the step ring is the hero (countdown, step name, "Next: …"); Speed and Incline tiles below.
  - Bottom bar: ✦ **Coach**, **Pause**, **Skip**, **STOP** in one row (paused: ✦, **Resume**, **End workout**).
  - **Coach sheet** (slides up from ✦): Easier / Harder / −5 min / +5 min, the text box and mic, and the "Workout length 33:00 (was 33:00)" line with Undo.
  - **Check-ins, offers and the length notice** float over the top as a slim card, so they never push the layout.
  - A connection loss shows a compact Connect button in the status row.
- **Start has a cancellable 3-2-1 countdown** in the same spot as STOP, so a double-tap on STOP can't restart the belt.
- Everything is sized to fit one screen, including smaller iPhones (numbers scale down; nothing scrolls).

### 8c. Workout summary (requested 2026-11-17; built in 0.7.2, untested)
**As built in 0.7.2:** distance, time, average speed, pace, elevation gain, calories (estimate from a body weight set in Setup, not read from Health), average incline, a speed and incline chart, comparison with the last session of the same name and personal-best badges, on the finished workout screen, in a sheet after a treadmill session, and in History (plus mile splits). The 5-second samples (thinned to at most 120) are stored inside each history entry, not in a separate file. **Planned (fix 16, 2026-11-17): a Setup switch to hide calories** (the user uses Apple Fitness on the Apple Watch for those). When off, the sixth tile shows something else (the top speed) so the grid stays even. **Not built yet:** the Apple Intelligence debrief, the per-step table, reading body weight from Health, heart rate.
Shown when a workout or a treadmill-mode session ends, and again in History (the full version).
- **Finished screen** (one screen, no scrolling): distance as the hero number; six tiles; a small speed and incline chart; the effort rating; Done.
- **Numbers and how they're worked out** (all by code from the treadmill's readings, sampled every 5 s):
  - **Distance:** belt speed added up over time (what the treadmill reports).
  - **Time:** moving time as the main figure; total time including pauses beside it when they differ.
  - **Average speed and pace:** distance ÷ moving time, with pace in min per mile.
  - **Top speed, average incline, top incline** actually reached (not the plan's).
  - **Elevation gain:** for each sample, distance × incline %, added up (in feet). It comes from the incline setting, so it's the climb you simulated.
  - **Calories (estimate):** the ACSM walking/running equations from speed, incline and body weight, shown as "~200 kcal (estimate)", typically within about 15%. Body weight is read from Apple Health (a new read permission for body mass); if it's missing, Setup asks for it once.
  - **Plan vs actual:** steps completed, planned vs actual length, and how many changes you made (from the deviation notes).
  - **Heart rate** (when the sensor is in): average, top, and time in each zone.
  - **Compared with last time:** against your previous similar workout (faster, farther, longer) and personal bests (longest, farthest, fastest average), all computed by code. Apple Intelligence writes a two-sentence debrief from those facts; it never supplies the numbers.
- **History detail** adds per-mile splits, a table per step (time, average speed, incline, distance), the chart, and the deviation notes.
- **Stored:** the totals in the history entry, and the 5-second samples in one small file per session in the data folder (`history/<id>.json`), so history.json stays small and backups carry everything.
- **Not shown:** steps (the treadmill has no step sensor).
- **Apple Health** (still on hold): when saving is built, distance, elevation, calories and speed samples come from the same numbers.

### 8d. Live runner (requested 2026-11-17; Live Activity figure built in 0.7.2, untested; the rest deferred)
A stick figure that matches the treadmill.
- **Scope decided 2026-11-17: no motion for now.** Only the dynamic Live Activity icon (below) is planned. The animated in-app runner and the flip-book experiment are deferred; they stay here as ideas for later.
- **Limit:** iOS draws a Live Activity outside the app and doesn't play continuous animation there. Only a few things tick by themselves (the timer text and a timer-driven progress bar), and a view changes when the app sends an update, which the system rate-limits. So a smoothly running figure on the Lock Screen isn't possible; the two parts below are.
- **Deferred: in the app (smooth, real animation):** a slim strip (about 60 pt) on the Treadmill and Workout screens: a stick figure on a belt whose marks move at the belt speed.
  - Walking gait below about 4 mph; above that a run, with a flight phase and a forward lean.
  - Stride rate rises with speed (about 1.1 strides per second at 3 mph, 1.4 at 6 mph). The ground tilts with the incline. At 0 mph the figure stands and breathes.
  - Drawn with Canvas and a 60 fps timeline from the live speed and incline: low battery cost. A switch in Setup turns it off, and Reduce Motion turns it off too.
- **Planned: Live Activity (Lock Screen and Dynamic Island):** the figure changes with pace and slope whenever an update arrives (already sent on speed changes):
  - stopped (standing), walking, running, and hiking when the incline is steep (about 5% and up);
  - bands (adjustable): stopped under 0.1 mph, walking up to 3.9 mph, running from 4.0 mph;
  - SF Symbols: `figure.stand`, `figure.walk`, `figure.run`, `figure.hiking`. A wrong symbol name only shows as a blank at runtime, so the names get checked on the phone first.
- **Deferred experiment, only if wanted later:** a one-frame-per-second flip-book on the Lock Screen: a custom font whose digits are stick-figure poses, shown through the timer text that ticks by itself. It moves without any updates, but only at 1 frame per second, and it's a hack that an iOS update could break.
- Effort: the Live Activity icons a couple of hours (the in-app runner, deferred, about a day).

## Build and install (no Mac)
- Project kept as text in a GitHub repo (XcodeGen or similar).
- GitHub Actions macOS runner builds an unsigned `.ipa` on every push.
- The user signs it with Signulous and installs it.
- Signulous signs for the iPhone only: HealthKit works, a watch app can't be installed, and the app's signing ID is shared with other sideloaded apps.

## Next build (0.7): everything that doesn't need the heart-rate sensor
Scope agreed 2026-11 after the first field test. **Built 2026-11-10** (plus deleting workout history: swipe one, or Delete all), testing.

| Included | Details |
|---|---|
| Speed and Incline tiles on the workout screen | §3 "Live speed and incline controls" |
| End workout (incline to 0%), STOP pauses with Resume / End | §3 "End workout" |
| Treadmill-mode Live Activity (ends 2 min after stopping) | §8 Screens |
| Deviation notes for the AI | §7 Performance tracking |
| AI during workouts: Easier/Harder/Shorter/Longer, typed and spoken requests, behaviour-based offers, check-ins | §7 "Apple Intelligence during the workout" |
| History screen and workout editor | from milestone 4 |
| Readiness from Apple Health (reading resting HR, HRV, sleep recorded by the watch/Oura) | §7 Performance tracking |
| Simple goal plans (e.g. 3 workouts a week for 6 weeks) | §7 AI coach |
| UI overhaul: Liquid Glass (iOS 26+, frosted panels before), animations, the icon's navy/cyan/lime palette, progress ring, rolling numbers | §8 Design; `DesignSystem.swift` |
| Delete workout history (swipe one entry, or Delete all with confirmation) | History tab |

**On hold:** saving workouts to Apple Health (milestone 4) and everything heart-rate (milestone 3, waits for the sensor).

## Fixes build (0.7.1): fixes from the field tests
All collected from the user's real runs (2026-11). **Built 2026-11-11 as 0.7.1** (rows 1–9), testing; rows 10–15 built 2026-11-17 as 0.7.2. The proposals below the table were not included. Details are in the sections named in each row.

| # | Fix | Why it's needed | Details |
|---|---|---|---|
| 1 | **Workout length guarantee:** ask for 60 min, get exactly 60:00 | A 60-min request ended at 33:30; no check on AI edits | §7 "Workout length guarantee" |
| 2 | Length typed in the text ("1 hr", "an hour") sets the length and the picker; button and preview show the exact total | The app only read the picker | same |
| 3 | **Live edits are checked:** Easier/Harder/typed requests keep the remaining time; Shorter/Longer are exactly ±5 min; Longer near the end adds a block before the cool-down | AI "Easier" could cut time unchecked; three Longer taps added nothing while the AI claimed it did | same |
| 4 | New total shown after every live edit ("55:00, was 60:00") with Undo for 10 s | Nothing told the user the workout had shrunk | same |
| 5 | **End workout sequence:** Stop the belt, wait 2 s, send incline 0% (tested on the treadmill; the deck lowers) | The old order (incline 0% then Stop) left the deck up | §3 "End workout" |
| 6 | **STOP shows only while the belt runs** | A STOP button on a stopped treadmill | §3 |
| 7 | **History:** original planned length plus the final one; top speed and incline actually reached; length changes logged with before/after totals; rapid taps on one tile merged into one entry | Four incline taps were logged as four changes; History showed the plan's values | §7 |
| 9 | **No-scroll Treadmill and Workout screens** (one set of controls, one bottom bar, coach in a sheet, overlays for check-ins) | The screens were cluttered and needed scrolling mid-session | §8b |
| 10 | **[built 0.7.2]** **Command cooldown:** speed and incline commands go out at most once a second each (the first at once, then the latest value after the cooldown); queued commands of the same kind are merged; a status poll goes out between commands; a delayed command is dropped on STOP or disconnect | 25 quick taps (5.0 → 2.5 mph) queued 25 commands that ran back to back for about 14 s with no polling, so the 10-second watchdog reset the connection | §1 |
| 11 | **[built 0.7.2]** **Plan setup, goal picker:** the setup sheet and the End plan dialog move off the list Section onto the screen itself (the Readiness load too), and the four goals become selectable rows with a one-line description each | The Goal picker on "Start a plan" doesn't work (the user confirmed: the menu opens and then vanishes, or the sheet closes). The sheet was attached to a list Section, and SwiftUI applies a Section's modifiers to every row in it, so the sheet is presented once per row | §7 |
| 12 | **[built 0.7.2]** **Workout summary** at the end of every workout and treadmill session: distance, time, average speed and pace, elevation gain, calories (estimate), incline, a speed and incline chart, comparison with last time | The finished screen only showed time and miles (requested 2026-11-17) | §8c |
| 13 | **[built 0.7.2]** **Interactive Live Activity buttons:** speed −/+, Pause/Resume and STOP on the Lock Screen and expanded Dynamic Island | Requested 2026-11-17: control the treadmill without opening the app; speed buttons depend on fix 10 | §8 |
| 14 | **[built 0.7.2]** **Dynamic Live Activity figure:** the icon changes with speed and incline (standing, walking, running, hiking). The moving in-app runner is deferred | Requested 2026-11-17: make the Live Activity feel alive, without motion for now | §8d |
| 15 | **[built 0.7.2]** **Resume reliability:** after Resume the incline sometimes doesn't take. Resume no longer sends the extra "speed 1.0"; commands wait for the belt to report moving plus a short settle, go out one per poll message, are checked against the treadmill's next readings and resent (up to 3 times, also on a "refused" reply); a failure shows on the workout screen | Reported 2026-11-17: the app sent Start, a redundant "speed 1.0", the incline and the speed back to back with no polls between them, and never checked or retried | §1 |
| 16 | **[built 0.7.3]** **Calories switch:** a "Show calories" switch in Setup (on by default). Off hides the calorie tile and the "kcal" figure on the finished screen, the treadmill session sheet and History; the body-weight field hides too; nothing about calories is shown anywhere. The numbers are still saved with each session, so turning it back on shows them for old sessions | Requested 2026-11-17: the user wears an Apple Watch and uses Apple Fitness for calories, so the app's estimate would only conflict with it | §8c |
| 17 | **[built 0.7.3]** **Keyboard can be dismissed:** a Done button above the keyboard (the main fix: confirmed 2026-11-17 that scrolling alone does not hide it), tapping outside the box, and a Done return key; dragging down is added too but not relied on, on the Coach tab note box, the workout editor, and the live Coach sheet | Reported 2026-11-17: once typing starts in the Coach notes there is no way to hide the keyboard (the box is multi-line, so Return only adds a new line) | §8 |
| 18 | **[built 0.7.3]** **Proportionate workouts:** warm-up and cool-down ramp over two steps (e.g. 2.0, 2.5, then 3.0 mph); the main part is split into blocks of 5-10 minutes that vary speed (±0.2-0.3 mph) and incline (0-2%, none on a "sore legs" or Easy request) instead of one flat step; step lengths are whole minutes (the total stays exact); an AI workout that is flat (every step within 0.2 mph and the same incline, or fewer steps than its length calls for) is replaced by the rules version; the AI prompt asks for this structure and is told the person's speed range | Reported 2026-11-17: a 60-min "endurance" workout came out as 3.0 mph at 0% for every step (warm-up 2:35, main 52:10, cool-down 5:15 at 2.5). The walk rule itself is one flat step, and nothing rejects a flat AI answer | §7 |
| 19 | **[built 0.7.3]** **One session, one Live Activity:** (a) a treadmill-mode session and its Live Activity can't start while a workout runs, for 15 s after one ends, or while a Stop is on its way; (b) starting either kind of Live Activity ends the other, and the app ends leftover Live Activities from an earlier run when it launches; (c) **workout recovery:** the running workout is saved every 10 s (step, time, edits, notes); if iOS relaunches the app and the belt is still running, the app picks the workout up again ("Welcome back, continuing Steady, 24:10 left") and reconnects to its Live Activity instead of dropping into treadmill mode | Reported 2026-11-17 (test run): two Live Activities at once, one treadmill and one workout; back in the app it had lost the workout and switched to treadmill mode | §8 |
| 20 | **[built 0.7.3]** **Check-in on the Live Activity:** when "How's it feeling?" is due, the Lock Screen and expanded Dynamic Island show Easy / Good / Hard buttons that work like the in-app card (Hard eases off at once; Easy leaves the "make it harder?" offer in the app); they disappear when answered or dismissed in the app | Requested 2026-11-17 | §8 |
| 21 | **[built 0.7.3]** **Workout editor layout:** the Edit (reorder) button moves from the bottom bar, where it floats over the "Add step" row, to the top bar beside Save; the three step controls (time, speed, incline) get real spacing so their − / + pills no longer overlap; the time stepper snaps an odd length (like 5:25) to the next 30 s mark on the first tap so steps can be made whole | Seen 2026-11-17 on the Edit workout screenshot: the Edit pill covers the last row and the − / + pills of each step touch each other; a 5:25 step can only go to 5:55 | §8 |
| 22 | **[built 0.7.3]** **Diagnostics log (build first):** a rolling event log saved in the data folder (`diagnostics.log`, last ~2,000 lines, one line per event with a time stamp): app launches and why (normal, Bluetooth relaunch, restore); Bluetooth connect, disconnect, reconnect and watchdog resets; every command sent (label, value, how long since the last one) and every refusal, resend and give-up; belt state changes; workout start, pause, resume, step changes, edits and finish; Live Activity start, update failures and end; iOS's own reports of why the app was closed (MetricKit termination and memory diagnostics, received on the next launch). Setup shows the last events and a **Share log** button (and a Clear). Nothing leaves the phone unless the user shares it | Requested 2026-11-17: the relaunch and the dropped incline had to be guessed from the code; a log answers "what happened" from the phone itself | §1 |
| 23 | **[on hold: user chose not to do it for now, 2026-11-17]** **Plan reminders:** when starting a plan the user picks the days (as many as workouts a week) and a time (default 6 PM); a local notification on those days says "Today: 30 min steady walk. Tap to create it"; finishing a workout (or a treadmill session) that day cancels that day's reminder; ending the plan cancels all; one switch in Setup turns reminders off. Local notifications only (no server); asks for notification permission the first time | Found in the review 2026-11-17: a training plan has nothing that nudges the user on their workout days | §7 |
| 24 | **[built 0.7.3]** **Tests for the treadmill command logic:** the cooldown, one-command-per-poll order, resend-after-dropped-incline and give-up rules move out of the Bluetooth class into a plain `CommandPacer` file with no Bluetooth in it, and `Tests/LengthTests` replays scripted situations against it on every build (e.g. 25 quick taps, an incline that falls back after Start, a refusal, a Stop during pending commands, a console change that must not be fought) | Found in the review 2026-11-17: the pacing and resend rules (fixes 10 and 15) have no automated test, only a hand test on the treadmill | §1 |
| 25 | **[built 0.7.3]** **Coach shape tests:** the build also checks every rules-made workout (every length 10-90, every type and intensity): the main part has several blocks that differ in speed or incline, the warm-up and cool-down ramp, step lengths are whole minutes, and no step jumps more than 1.5 mph; and that a flat AI answer is rejected | Found in the review 2026-11-17 (the 3.0-mph-everything workout): length is tested on every build, shape isn't (goes with fix 18) | §7 |
| 26 | **[built 0.7.4]** **Keep warm-up and cool-down short and distinct:** an AI workout's warm-up is capped at 5 min in total and its cool-down at 4 min, the extra time moves into the main part; the first warm-up step is at least 0.5 mph below the second; repeated names get told apart ("Warm-up" / "Ease in", "Ease out" / "Cool-down") | Seen 2026-11-17 on a 0.7.3 workout ("Easy Recovery Walk", 60 min): warm-up 4:30 at 3.0 then 3:30 at 3.2 (8 min, ramp of only 0.2), cool-down 6 min then 3 min (9 min), both pairs named the same; that is 17 of 60 minutes spent warming up and cooling down | §7 |
| 27 | **[built 0.7.5]** **Keep warm-up and cool-down at the ends, and slower than the main part:** (a) a step labelled cool-down (or warm-up) that isn't in the end group is renamed "Recover" (or "Build") so only the real ends count as warm-up and cool-down, which also keeps live edits (Longer, Shorter) from treating it as the cool-down; (b) the last warm-up step is capped at the speed of the first main step, and the first cool-down step at the speed of the last main step, so you never warm up faster than you then walk; (c) a single warm-up or cool-down step longer than 2 min is split into two so it ramps; (d) tests: a workout like the 0.7.4 one (warm-up 3.0 then 3.5, a "Cool-down" as step 3, main steps at 3.0-3.7) comes out with the cool-down only at the end and no warm-up step above the first main speed | Seen 2026-11-17 on a 0.7.4 workout ("Easy Walk Build", 60 min): after the warm-up (3.0, then 3.5 mph) came a "Cool-down" (4:30 at 2.8) as step 3 and only then the hills and steady walks at 3.0-3.7, with a second cool-down at the end; the warm-up's 3.5 mph is faster than the steady walk | §7 |
| 28 | **[built 0.7.5]** **The chosen type is binding:** (a) the AI prompt defines each type (Intervals: at least 5 pairs of a fast step of 1-3 min, 0.8-1.5 mph above the comfortable speed, and a recovery of 1.5-3 min at the comfortable speed; Hills: incline 2-8% in blocks; Jog: 4-6 mph; Walk: 2.5-3.8 mph) and says the type and intensity beat anything in the note; (b) the result is checked against the type (Intervals needs 4+ fast/recover swings of 0.5 mph or more in a 20+ min workout; Hills needs an incline range of 2% or more; Jog needs a main speed of 4 mph or more) and a miss is replaced by the rules version, with a message saying so; (c) the "Anything else?" note is cleared once the workout is created, so an old note ("legs are sore, build endurance") doesn't steer the next one; (d) tests: the rules version of every type passes its own check, and a walking workout fails the Intervals check | Reported 2026-11-17: chose Intervals and got walks ("Easy Walk Build"). Likely causes: the type is only one word in the AI prompt with no definition, nothing checks the result against it, and the note box keeps its earlier text (an earlier note said "legs are a bit sore ... endurance building") | §7 |
| 29 | **The log shows what was asked and what the AI was told:** for every workout request the Diagnostics log records the request as chosen (minutes, type, intensity), the note exactly as typed (separately from the readiness text the app adds), the readiness text, the full prompt sent to Apple Intelligence (and the fixed instructions once per launch), the AI's raw answer (name, summary, every step), the raw total against the requested total, and the final steps after repair; live-coach requests (typed or spoken) and the answers are logged the same way. Long entries are split over several lines; the Share log button already covers it | Requested 2026-11-17: the log only said \"note 93 characters\" (that count included the readiness text the app adds), so it can't show what the user asked or what the model was told | §1 |
| 30 | **Interval quality and length check:** an Intervals workout is rejected (rules version used) when a fast step is longer than 3.5 min, a fast step is more than 1.5 mph above the comfortable speed (0.8 mph on Easy), there is no recovery after a fast step, or the AI's own steps add up to more than 15% off the requested length (stretching or squashing the steps changes the intervals); Easy never goes above the comfortable speed + 0.8 mph for any type | Seen in the 2026-11-17 log: a 60-min Easy Intervals answer had fast steps growing from 1:30 to 9:00 at up to 5.2 mph, steps adding up to 67.5 min, and a \"Cool-down\" as step 3; a 30-min answer added up to 21.5 min (4.2 to 5.5 mph with no incline); both were accepted | §7 |
| 8 | **Length test on every build:** creates workouts for every length 10–90 min (rules and simulated AI output) and fails the build if any total is off | So it can't regress | §7 |

**Proposed, not yet agreed by the user** (decide before building):
- **Autosave and recovery:** the workout or session in progress is saved every 30 s and at each pause; after an app restart, offer Resume / Save as ended / Discard. During a connection drop, distance is estimated from the last speed (capped at a few minutes, marked estimated in History). Today a workout in progress is lost if the app is closed.
- **Speed safety guards:** a maximum speed the app never commands above, an automatic STOP if the treadmill reports a speed over that limit, a limit on speed jumps per command, and a treadmill event log. Background: in 2026-11 the treadmill's speed crept up by itself because of a broken keypad membrane (hardware, not the app); the guards would have stopped it automatically.
- **Check-in "Hard" stacks** (−0.3 mph and −1% each time): show the total eased amount, e.g. "eased off 0.6 mph so far".

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

### Built in 0.7.3 (2026-11-17), differences from the plan
- Step lengths: the rules make whole minutes (intervals keep their 60 s and 90 s steps); Apple Intelligence's steps are rounded to the nearest 30 s with the total kept exact (not whole minutes).
- Keyboard: Done button, scroll-to-dismiss, tap-outside in the live Coach sheet; dragging didn't work in 0.7.2, so the button is the main fix.
- Recovery: the saved workout is `activeWorkout.json` in the app's Documents folder (not the data folder), saved every 10 s and at each step, pause, resume and edit; kept up to 4 hours.
- Diagnostics: `diagnostics.log` is in Documents too (visible in Files > SportTread). iOS's termination reports come once a day.
- Calories switch: off shows top speed in the sixth tile.
- Not built: fix 23 (plan reminders, on hold).

### Built in 0.7.5 (2026-11-17)
- The AI-workout checks: a rejected workout is replaced by the rules version, and the Diagnostics log records what the AI proposed and why it was accepted or rejected, so the real pass rate can be read from the log.
- Heart rate later (user, 2026-11-17: "we will get better results"): real heart rate gives the coach actual effort to work with instead of a 1-10 rating and guesses, and makes the heart-rate hold, zones and recovery-rate coaching possible. It does not replace the checks above: the structure of a workout still comes from the rules and the checks.
