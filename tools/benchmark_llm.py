"""Benchmark free cloud AI services on the app's own workout requests.

Sends the same prompt the app sends (rules, JSON format, one worked example, the request) to each service you
have a key for, checks every answer with the app's checks (ported from SportTread/Coach/TemplateCoach.swift),
and, like the app, sends a rejected answer back with the reason, up to 2 times. Prints the pass rates and the
time per call, so the order of the services in Setup can come from numbers.

Keys come from environment variables and are never printed or saved:
    GROQ_API_KEY, GEMINI_API_KEY, COHERE_API_KEY          (free keys)
    CUSTOM_URL, CUSTOM_MODEL, CUSTOM_KEY (optional)       (for example http://192.168.1.50:11434/v1 and qwen3:8b)
OVHcloud needs no key and is always included (slow: 2 requests a minute).
Models can be changed with GROQ_MODEL, GEMINI_MODEL, COHERE_MODEL, OVH_MODEL.

    python tools/benchmark_llm.py              all 15 scenarios, every service with a key
    python tools/benchmark_llm.py --quick      6 scenarios
    python tools/benchmark_llm.py --only groq  one service

The rules text below is a copy of WorkoutPrompt.rules: keep the two in step.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")

RULES = """You are a friendly treadmill coach. You design one treadmill workout as a list of timed steps.
Rules:
- The steps' seconds must add up to the requested total time.
- Start with a warm-up of 3 to 5 minutes in total (never more than 5), in two steps that ramp up
  by at least 0.5 mph (for example 2.0 then 2.5 mph), and end with a cool-down of about 3 minutes
  in total (never more than 4) in two steps that ramp down. Most of the time is the main part.
- The main part is never one flat step: use at least 3 blocks of 5 to 10 minutes that differ in
  speed (by 0.2 to 0.5 mph) or in incline (0 to 3 percent). Never give every step the same speed and incline.
- If the person is sore, tired or asks for easy, keep the incline at 0 and vary only the speed a little.
- Make step lengths whole minutes (multiples of 60 seconds), except interval steps.
- The chosen workout type and intensity are required. If the person's note seems to ask for something
  else, still make that type and intensity and use the note only to adjust how hard it is.
- Speeds are in miles per hour. Walking is about 2.5 to 3.8 mph, jogging about 4 to 6 mph.
  Stay close to the person's comfortable speed and never go above 10 mph.
- Incline is 0 to 10 percent.
- Never raise the speed by more than 1.5 mph from one step to the next.
- Easy means relaxed, moderate means somewhat hard, hard means challenging but safe.
- Each step lasts between 30 seconds and 15 minutes."""

JSON_RULE = ('Reply with one JSON object only, with no other text, in exactly this shape:\n'
             '{"name": "at most 4 words", "summary": "one encouraging sentence", '
             '"steps": [{"label": "Warm-up", "seconds": 120, "mph": 2.0, "incline": 0}]}')

FAST = {"easy": (0.5, 1.0), "moderate": (0.8, 1.5), "hard": (1.2, 2.0)}
BASE = 3.0  # the comfortable speed used in every scenario


def example(kind):
    def s(label, seconds, mph, incline=0):
        return {"label": label, "seconds": seconds, "mph": mph, "incline": incline}
    steps = [s("Warm-up", 120, 2.0), s("Ease in", 180, 2.8)]
    if kind == "intervals":
        for r in range(1, 7):
            steps += [s(f"Fast {r}/6", 120, 4.2), s(f"Recover {r}/6", 240 if r == 6 else 180, 3.0)]
    elif kind == "hills":
        steps = [s("Warm-up", 120, 2.0), s("Ease in", 180, 2.5)]
        for i, inc in enumerate([2, 4, 6, 4, 2, 4, 6, 8, 4, 2]):
            steps.append(s(f"Hill {i + 1}/10", 240 if i == 9 else 180, 3.0, inc))
    elif kind == "jog":
        steps = [s("Warm-up", 120, 2.5), s("Ease in", 180, 3.3)]
        for i, (sp, mn) in enumerate(zip([4.2, 4.5, 4.3, 4.6], [8, 8, 8, 7])):
            steps.append(s(f"Jog {i + 1}/4", mn * 60, sp, 2 if i == 2 else 1))
    else:
        steps = [s("Warm-up", 120, 2.0), s("Ease in", 180, 2.5)]
        for i, (sp, inc, mn) in enumerate(zip([3.0, 3.3, 3.1, 3.4], [0, 1, 2, 1], [7, 8, 8, 8])):
            steps.append(s(f"Steady {i + 1}/4", mn * 60, sp, inc))
    steps += [s("Ease out", 120, 2.5), s("Cool-down", 120, 2.0)]
    return json.dumps({"name": "Example", "summary": "An example workout.", "steps": steps})


def type_guide(kind, intensity):
    lo, hi = FAST[intensity]
    return {
        "intervals": f"Type rules for intervals: the main part repeats at least 5 pairs of a fast step (1 to 3 minutes at {BASE + lo:.1f} to {BASE + hi:.1f} mph) and a recovery step (1.5 to 3 minutes at {BASE:.1f} mph). It is not a steady walk.",
        "hills": f"Type rules for hills: the main part is blocks of 2 to 4 minutes whose incline changes between 2 and 8 percent, with the speed staying near {BASE:.1f} mph.",
        "jog": "Type rules for jog: the main part is jogging at 4 to 6 mph in blocks of 5 to 10 minutes.",
        "walk": "Type rules for walk: the main part is walking at 2.5 to 3.8 mph in blocks that vary a little.",
    }[kind]


def build_messages(minutes, kind, intensity, note):
    system = (RULES + "\n\n" + JSON_RULE + "\n\nHere is an example of a good " + kind + " workout for 40 minutes, moderate effort and a "
              "comfortable speed of 3.0 mph. Do not copy it: make your own for the requested time, speed and effort.\n" + example(kind))
    user = (f"Create a {minutes}-minute {intensity} {kind} treadmill workout.\nTotal time: exactly {minutes * 60} seconds.\n"
            f"The person's comfortable walking speed is about {BASE:.1f} mph.\n{type_guide(kind, intensity)}\n"
            "No previous workouts yet, so keep it approachable.")
    if note:
        user += f"\nThe person adds: {note}"
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


# ---- the app's checks (ported from TemplateCoach.swift)
def is_warm(s): l = s["label"].lower(); return "warm" in l or "ease in" in l
def is_cool(s): l = s["label"].lower(); return "cool" in l or "ease out" in l


def main_steps(steps):
    a = 0
    while a < len(steps) and is_warm(steps[a]): a += 1
    b = len(steps)
    while b > a and is_cool(steps[b - 1]): b -= 1
    return steps[a:b]


def judge(steps, minutes, kind, intensity):
    """The reason the app would reject this answer, or None. Warm-up and cool-down sizes are reported but the app
    repairs them, so they only count against the strict score."""
    total = sum(s["seconds"] for s in steps)
    want = minutes * 60
    main = main_steps(steps)
    if not main: return "there is no main part"
    sp = [s["mph"] for s in main]; inc = [s["incline"] for s in main]
    if minutes >= 20 and max(sp) - min(sp) <= 0.25 and max(inc) - min(inc) <= 0.5:
        return "it was one flat pace"
    if minutes >= 20:
        if kind == "intervals" and sum(1 for x, y in zip(main, main[1:]) if abs(x["mph"] - y["mph"]) >= 0.49) < 4:
            return "it didn't look like intervals"
        if kind == "hills" and max(inc) - min(inc) < 1.99: return "it didn't look like hills"
        if kind == "jog" and max(sp) < 3.8: return "it didn't look like a jog"
    if kind == "intervals" and minutes >= 20:
        if abs(total - want) / want > 0.15:
            return f"its own steps added up to {total // 60}:{total % 60:02d} instead of {minutes}:00"
        allowed = BASE + FAST[intensity][1] + 0.05
        for i, s in enumerate(main):
            if s["mph"] >= BASE + 0.5:
                if s["seconds"] > 210: return f"a fast step lasts {s['seconds'] // 60}:{s['seconds'] % 60:02d}"
                if s["mph"] > allowed: return f"a fast step is {s['mph']:.1f} mph, too fast for {intensity}"
                if i + 1 < len(main) and main[i + 1]["mph"] >= s["mph"] - 0.4: return "a fast step has no recovery after it"
    if intensity == "easy" and kind != "jog" and max(sp) > BASE + FAST["easy"][1] + 0.05:
        return f"it went up to {max(sp):.1f} mph, faster than an easy pace"
    return None


def strict_notes(steps, minutes):
    notes = []
    total = sum(s["seconds"] for s in steps)
    if abs(total - minutes * 60) / (minutes * 60) > 0.15: notes.append("length off by more than 15%")
    a = 0
    while a < len(steps) and is_warm(steps[a]): a += 1
    b = len(steps)
    while b > a and is_cool(steps[b - 1]): b -= 1
    if sum(s["seconds"] for s in steps[:a]) > 300: notes.append("warm-up over 5 min")
    if sum(s["seconds"] for s in steps[b:]) > 240: notes.append("cool-down over 4 min")
    if any(y["mph"] - x["mph"] > 1.5 for x, y in zip(steps, steps[1:])): notes.append("speed jump over 1.5 mph")
    return notes


def read(text):
    a, b = text.find("{"), text.rfind("}")
    if a < 0 or b <= a: return None
    try:
        o = json.loads(text[a:b + 1])
        steps = [{"label": str(s.get("label", "Step")), "seconds": int(round(float(s["seconds"]))),
                  "mph": float(s["mph"]), "incline": float(s.get("incline", 0) or 0)} for s in o["steps"]]
        return steps or None
    except Exception:
        return None


def retry(reason, seconds):
    return (f"The app's checks rejected your workout because: {reason}.\nFix exactly that and keep everything that was fine. "
            f"The steps must still add up to exactly {seconds} seconds. Reply with the complete corrected JSON object only.")


# ---- services
def providers():
    found = []
    if os.environ.get("GROQ_API_KEY"):
        found.append(("Groq", "https://api.groq.com/openai/v1", os.environ.get("GROQ_MODEL", "openai/gpt-oss-120b"), os.environ["GROQ_API_KEY"], 25))
    if os.environ.get("GEMINI_API_KEY"):
        found.append(("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", os.environ.get("GEMINI_MODEL", "gemini-2.5-flash"), os.environ["GEMINI_API_KEY"], 8))
    if os.environ.get("COHERE_API_KEY"):
        found.append(("Cohere", "https://api.cohere.ai/compatibility/v1", os.environ.get("COHERE_MODEL", "command-a-03-2025"), os.environ["COHERE_API_KEY"], 5))
    found.append(("OVHcloud", "https://oai.endpoints.kepler.ai.cloud.ovh.net/v1", os.environ.get("OVH_MODEL", "gpt-oss-120b"), None, 35))
    if os.environ.get("CUSTOM_URL"):
        found.append(("Custom", os.environ["CUSTOM_URL"], os.environ.get("CUSTOM_MODEL", "qwen3:8b"), os.environ.get("CUSTOM_KEY"), 0))
    return found


def chat(base, model, key, messages):
    body = json.dumps({"model": model, "messages": messages, "temperature": 0.4, "max_tokens": 5000}).encode()
    headers = {"Content-Type": "application/json"}
    if key: headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(base.rstrip("/") + "/chat/completions", data=body, headers=headers)
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=180) as r:
        data = json.load(r)
    return data["choices"][0]["message"]["content"], time.time() - t0, data.get("usage", {}).get("total_tokens", 0)


SCENARIOS = [
    (30, "intervals", "moderate", ""), (60, "intervals", "easy", ""), (45, "intervals", "hard", ""),
    (60, "walk", "easy", "my legs are a bit sore"), (30, "walk", "moderate", ""), (90, "walk", "moderate", ""),
    (45, "hills", "moderate", ""), (30, "hills", "easy", ""), (60, "hills", "hard", ""),
    (30, "jog", "moderate", ""), (45, "jog", "hard", ""), (20, "jog", "easy", ""),
    (60, "intervals", "moderate", "I want to burn calories and build endurance"),
    (40, "walk", "hard", "push me today"), (25, "intervals", "easy", "legs are tired"),
]
QUICK = [SCENARIOS[i] for i in (0, 1, 3, 6, 9, 12)]


def run(name, base, model, key, gap, scenarios):
    stats = {"runs": 0, "first": 0, "fixed": 0, "calls": 0, "seconds": 0.0, "tokens": 0, "errors": 0, "strict": 0}
    last_call = 0.0
    failures = []
    for minutes, kind, intensity, note in scenarios:
        stats["runs"] += 1
        messages = build_messages(minutes, kind, intensity, note)
        label = f"{minutes} min {kind} {intensity}" + (f" ({note})" if note else "")
        accepted = None
        last = "no answer"
        for attempt in range(3):
            wait = gap - (time.time() - last_call)
            if wait > 0: time.sleep(wait)
            last_call = time.time()
            try:
                text, took, tokens = chat(base, model, key, messages)
            except urllib.error.HTTPError as e:
                stats["errors"] += 1
                print(f"  {name}: {label}: HTTP {e.code}", flush=True)
                break
            except Exception as e:
                stats["errors"] += 1
                print(f"  {name}: {label}: {e}", flush=True)
                break
            stats["calls"] += 1; stats["seconds"] += took; stats["tokens"] += tokens
            steps = read(text)
            reason = "the reply wasn't one JSON object with a steps list" if steps is None else judge(steps, minutes, kind, intensity)
            if reason is None:
                accepted = attempt
                if attempt == 0:
                    stats["first"] += 1
                    if not strict_notes(steps, minutes): stats["strict"] += 1
                else:
                    stats["fixed"] += 1
                break
            messages = messages + [{"role": "assistant", "content": text}, {"role": "user", "content": retry(reason, minutes * 60)}]
            last = reason
        if accepted is None:
            failures.append(label + ": " + last)
        print(f"  {name}: {label}: " + ("accepted first try" if accepted == 0 else f"accepted after {accepted} fix(es)" if accepted else "REJECTED"), flush=True)
    return stats, failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--only")
    args = parser.parse_args()
    scenarios = QUICK if args.quick else SCENARIOS
    rows = []
    for name, base, model, key, gap in providers():
        if args.only and args.only.lower() != name.lower(): continue
        print(f"{name} ({model}): {len(scenarios)} scenarios", flush=True)
        stats, failures = run(name, base, model, key, gap, scenarios)
        rows.append((name, model, stats, failures))
    print("\n=== Results (the app accepts a workout when its checks pass; a rejected one is sent back up to 2 times) ===")
    print(f"{'service':<10} {'model':<22} {'first try':>10} {'after fixes':>12} {'never':>6} {'sec/call':>9} {'tokens/run':>11} {'strict':>7}")
    for name, model, st, failures in rows:
        runs = max(1, st["runs"]); calls = max(1, st["calls"])
        never = st["runs"] - st["first"] - st["fixed"]
        print(f"{name:<10} {model[:22]:<22} {st['first']:>6}/{st['runs']:<3} {st['fixed']:>8}/{st['runs']:<3} {never:>6} {st['seconds'] / calls:>9.1f} {st['tokens'] // runs:>11} {st['strict']:>4}/{st['runs']:<2}")
        for f in failures: print("    rejected:", f)
    print("strict = accepted first try AND warm-up/cool-down sizes, length and jumps all right without the app's repair")
    with open("benchmark_results.json", "w", encoding="utf-8") as out:
        json.dump([{"service": n, "model": m, **s, "failures": f} for n, m, s, f in rows], out, indent=2)
    print("saved benchmark_results.json")


if __name__ == "__main__":
    main()
