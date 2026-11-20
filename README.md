# Andrew's SportTread

iPhone app that runs a ProForm 505 CST treadmill without iFit. See [PLAN.md](PLAN.md).

## Current stage: build 0.10.0 (your own speeds and gait, a fitness test that uses the real stage times, background Bluetooth polling; 0.9.0: about you, heart-rate zones, the fitness test; 0.8.0: heart rate, heart-rate hold, Apple Health saving, incline choices, live coach on the cloud; 0.7.7: cloud AI for workouts with a fix-up loop, Easy interval limit; 0.7.6: the log shows what was asked and what the AI was told, interval quality check; 0.7.5: the chosen type is checked, warm-up and cool-down only at the ends; 0.7.4: shorter warm-up and cool-down; 0.7.3: diagnostics log, workout recovery, better workouts)
Passed so far: milestones 0, 1, 2, 5, the Live Activity and two field tests. On hold: saving to Apple Health,
heart rate (waits for the Bluetooth sensor), plan reminders and speed guards.

### Get the IPA
1. GitHub → **Actions** → latest **Build unsigned IPA** run → download **SportTread-ipa**.
2. Unzip it to get `SportTread-unsigned.ipa`.
3. Upload it to Signulous, sign (no extra options), and install.

Every build first runs the length tests (`Tests/LengthTests`): every workout length from 10 to 90 minutes,
simulated AI workouts, live edits and reading a length from text must come out exact, or the build fails.

### Test (0.10.0 and earlier; the 0.7.2 list still applies: pacing, resume, summary, Live Activity buttons)
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
| 10 | Create a 60-min Apple Intelligence workout | Warm-up steps add up to 5 min or less and cool-down steps to 4 min or less; the first warm-up step is 0.5 mph below the next; no two steps share a name; the total is still 60:00 |
| 11 | Pick **Intervals** (60 min) and create | The workout alternates fast and recovery steps (5 or more pairs); if Apple Intelligence gave walks the card says it was rejected and the rules made it |
| 12 | Look at any new workout's steps | Warm-up and cool-down only at the start and end (no "Cool-down" in the middle); the warm-up never ends faster than the first main step |
| 13 | Create a workout, then look at the Coach tab's note box | The note box is empty again |
| 14 | Setup → Diagnostics after creating a workout | "Coach: asked for…", "AI proposed…" and "accepted" or "rejected, because…" lines |
| 15 | Create a workout, then Setup → Diagnostics → Share log | The log has "Coach request", "Coach note as typed" (your exact words), the readiness text, the full prompt, the AI's answer step by step, and the final steps, plus the fixed instructions once per launch |
| 16 | Type a request in the live Coach during a workout | The log has "Live coach request", the prompt, the AI's answer and whether it was applied or offered |
| 17 | Create Intervals, Easy, 60 min | Either real short fast steps with recoveries (nothing above about 3.8 mph for an easy pace), or a card saying the AI's workout was rejected and why |
| 18 | Setup → Cloud AI for workouts | Switch it on; add a Groq or Gemini key (paste, Save); tap **Test**: it says "Works (n s)"; the key shows "saved in the Keychain" |
| 19 | Coach tab → create a workout with cloud AI on | The button says "Asking Groq…" (or the service you enabled); the card says "Created with Groq" (or "after one fix"); the steps follow the type you chose |
| 20 | Same, with Wi-Fi off | It falls back to Apple Intelligence or the rules, with no error screen |
| 21 | Setup → Diagnostics → Share log after a cloud workout | "cloud AI is on", the prompt, which service answered and how fast, its steps, accepted or rejected and why |
| 22 | Easy Intervals, 60 min | Fast steps up to about 4.0 mph for a 3.0 mph walker are accepted |
| 23 | Setup → Heart rate sensor → Find a heart-rate sensor | Your Coospo shows up (wake it on bare skin first); tap it; Status says Connected with the bpm; Battery and Signal show; after closing the app it reconnects by itself |
| 24 | Treadmill and Workout screens with the armband on | A ♥ number updates every second; '--' when the armband is off |
| 25 | Workout → ✦ Coach → Hold my heart rate | Switch on, set a target (for example 5 above where you are now), choose Speed, Incline or Both; the status line says 'Heart rate 128, target 135: speed +0.1 mph'; changes come at most every 15 s (30 s for incline); the tiles and STOP always win; it waits during warm-up and cool-down |
| 26 | Same, then move a tile by hand | The hold pauses 45 s and then starts from your new value |
| 27 | Setup → Apple Health → Save workouts to Apple Health, then finish a workout | Health asks permission once; the Fitness app shows an indoor walk or run (source 'Spotify') with distance, active calories, heart rate and climb; the Move ring moves |
| 28 | Coach tab → Incline: Lots, Make it hard with: Incline, 45-min walk | Blocks at 4 to 8% with the speed within about 0.2 mph of your comfortable speed |
| 29 | Coach tab → Incline: None (or a note 'my legs are sore') | 0% in every step (hills excepted) |
| 30 | Intervals, 60 min | About 10 pairs of 2:00 fast and 3:00 recovery, not 21 |
| 31 | Live Coach during a workout: type 'Hello', then 'add some hills' | 'Hello' gets a reply and no change; hills are added to the whole rest of the workout, with the intervals keeping their lengths (the answer is no longer cut at 24 steps) |
| 32 | Setup → About you | Height, age and maximum heart rate steppers; 'Fill weight, height and age from Apple Health' asks permission once and fills what Health has; the maximum shows 208 − 0.7 × age |
| 33 | Setup → Fitness test (sensor on, treadmill connected, age entered) → Begin | 45 s standing still, then a 24-minute workout: warm-up, six 3-minute stages, cool-down; the stage speeds are around your comfortable speed (for 3.0: 2.2 to 4.2 mph) |
| 34 | When the test ends | A card with your zones as heart rate and as mph, how well it fitted, and any stage that was still rising; Setup → Fitness test shows the last result |
| 35 | Start the test and let your heart rate pass 92% of the maximum (or take the sensor off for 10 s) | It skips to the cool-down with a message (or pauses and asks you to check the armband) |
| 36 | Workout → ✦ Coach → Heart rate: Suggest, pick a zone | Stay under the zone for 4 minutes (or over it for 2) and a harder or easier card appears; Hold has Z1 to Z5 buttons that set the target to the zone's middle |
| 37 | Finished workout with the sensor on | A line 'Zones: Z2 12:40 · Z3 4:20' under the charts |
| 38 | Setup → About you | New rows: Resting heart rate (with where it comes from), Easy walk, Fast walk, Jogging starts at (tap + to set each; for you about 2.4, 3.0 and 3.6 mph) |\n| 39 | Setup → Fitness test → Begin | Stage speeds run from a little below your easy walk to a little below your jog speed; resting heart rate is the lowest 15 seconds of the 45, or Apple Health's if the standing one is 20 bpm higher |\n| 40 | During a workout or the test | A Walking / Jogging button next to the ♥ number: tap it when you start jogging; the test then leaves jogged stages out and, if your jog speed isn't set, saves it |\n| 41 | The result card after a test | Says where the resting rate came from; zones show walk, jog or walk to jog next to the mph; a noisy result says it was not saved; Setup → Fitness test → Forget the saved test result clears it |\n| 42 | Fitness test stage that is cut short | Not used in the fit (the log lists the real stage lengths, e.g. \"5:51s\") |\n| 43 | Start a workout, lock the phone for several minutes | The treadmill link stays up; the log shows \"Background polling: the link was kept alive n times\"; any drop is logged with seconds since the last status, the app's state, signal, memory |\n| 44 | Create a workout after a fitness test | The comfortable speed in the log's prompt is your middle walking speed, not the test's top speed; the \"Recent workouts\" list has no fitness test |\n| 45 | Make a live coach edit, then watch the next step | The log shows \"Edit applied\" with the next steps and, when the next step starts, \"Edit check: this step matches the last edit\" (or says what changed it); a tap on Undo is logged |\n| 46 | Setup with Low Power Mode on | An orange note at the top explains that Bluetooth is limited in the background |\n
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
- `tools/`: Python BLE scripts used to work out the treadmill protocol, and `benchmark_llm.py` (tries the free cloud AI services on the app's own workout requests)
