# Ember

A private signal between two Macs, built for a long-distance couple. Click
the flame in the menu bar (or press ⌃⌥E anywhere) and their Mac lights up
with your ping. They answer from the notification itself.

No accounts, no App Store, no server of your own. Messages are end-to-end
encrypted and relayed through [ntfy.sh](https://ntfy.sh), which only ever
sees ciphertext.

## What it does

| | |
|---|---|
| **Four pings** | 💛 Miss you · 🌶️ Thinking about you · 🌶️🌶️ In the mood · 🔥 Call me. Now. Each has its own sound, so you know which one it is without looking. |
| **Your own words** | Settings → *What your pings say*. Your wording travels with the ping, so they read exactly what you wrote. (Yes, 🌶️🌶️ can say "Boner alert 🍆".) |
| **Reply from the notification** | 📞 FaceTime now (starts the call) · ⏳ Give me 20 (both Macs nudge you in 20 min) · 😏 Same · 🌧️ Rain check (lands silently) |
| **It's a match** | If you both ping within 15 minutes of each other, you both get "It's a match 🔥" with a FaceTime button. Two 💛 make a softer match. |
| **✓ / ✓✓** | One tick when your ping is sent, two once it reaches their Mac. |
| **Presence** | "At their Mac" / "Away · 2 hours ago", following the screen lock, so you know whether a ping will be seen now. |
| **Busy** | 🌙 for 1h, 3h, or until 9 am. Their pings wait silently and show up as one summary when it ends. They see "Busy until 6:00 pm" before they send. |
| **Quiet hours** | 01:00 to 08:00 by default: pings still arrive, just without sound. The other side sees "😴 Quiet hours". |
| **Discreet mode** | Notifications show only the emoji, for screen shares and friends looking over your shoulder. |

### Visits

Set the dates once (either of you) and both Macs count down: **12d** sits
next to the flame.

- **The day before:** "✈️ Tomorrow."
- **Together mode** (the visit days): pings turn into a quiet signal. There's
  no sound, the flame glows orange for ten minutes, and the replies change to
  👀 On my way · ⏳ After this · 🌧️ Not now. 🔥 reads "Come find me."
- **The comedown** (the day after): "💛 Back to long distance". Ember goes
  back to normal and asks for the next date.

## Install (both Macs)

You need macOS 14 or later. The app is universal (Apple Silicon and Intel).

1. Download the latest **Ember** artifact from the
   [Ember workflow runs](https://github.com/lsuryatej/jot/actions/workflows/ember.yml)
   (open the newest green run, scroll to *Artifacts*). Unzip it.
2. In Terminal: `bash ~/Downloads/Ember/install.sh` (adjust the path to wherever it unzipped).

That's the whole install. The script puts Ember in Applications and clears
the quarantine flag. Ember is ad-hoc signed, not notarized, so without that
step macOS refuses to open it. For the other Mac, AirDrop or message the
same unzipped folder and run the same command there.

Building from source instead: `./ember/build.sh && ./ember/install.sh`
(needs Xcode).

### First launch

- **Allow notifications** when macOS asks. (Clicked Don't Allow? The menu
  shows a *Turn them on* button.)
- Set the style to **Alerts**: the menu shows a tip with a shortcut to the right
  System Settings page until you do. Banners vanish after a few seconds and
  hide the reply buttons behind a hover. Alerts stay until you answer.
- Optional: Settings (gear icon) → *Open Ember at login*.

## Pair (once)

1. **One of you:** type your name → **Create a pair** → **Copy link**, and
   send it over iMessage/WhatsApp.
2. **The other:** click the link on the Mac (Ember opens and asks to pair),
   or paste it into *Got a code from them?* → **Join**.

That's it: each of you sees the other's name and "At their Mac". Add their
FaceTime email or number in Settings so 📞 calls the right person.

The link *is* the key. Anyone holding it can read and send your pings, so
send it in a private chat and don't post it anywhere. Unpairing (Settings)
and creating a new pair retires the old one.

## Privacy

- Every message is sealed with ChaChaPoly (256-bit key, bound to your
  topic) before it leaves the Mac. ntfy.sh relays opaque base64. It can see
  *that* your topic got a message and when, but not what it says, who sent it,
  or which level it was.
- The topic name is random and unguessable. Messages that don't decrypt
  under your key are dropped, so nobody else can post into your pair.
- Your state (pair key, history, settings) lives in
  `~/Library/Application Support/Ember/state.json`, readable only by your
  user account.
- Don't install it on a work laptop. Corporate device management can see
  installed apps, and the network logs show requests to ntfy.sh.

## Limits worth knowing

- **Both Macs need to be awake to get a ping live.** A Mac that's asleep or
  off catches up on wake: anything older than 10 minutes shows quietly as
  "earlier" instead of buzzing, and can't make a match. ntfy.sh keeps
  messages for 12 hours. A Mac off for longer than that misses the pings (but
  the visit dates and status still sync when it comes back).
- **ntfy.sh's free tier** allows 250 messages a day per network. Ember sends a
  handful (pings, acks, lock/unlock), so you won't get near it.
- **Time zones:** quiet hours compare against your own clock, which is right
  while you're both on IST.
- **Mac only for now.** An iPhone version needs the $99/yr Apple Developer
  account for push notifications.

## Try it on one Mac

Run a second copy against a separate state file and pair the two:

```bash
EMBER_STATE=/tmp/ember-b.json /Applications/Ember.app/Contents/MacOS/Ember
```

Two flames appear in the menu bar. Create a pair in one and join it from the
other. (Only the first copy gets the hotkey.)

## Development

```bash
./ember/test.sh          # 137 offline checks: engine, crypto, wire format, parser, storage
./ember/test.sh --live   # real round trips through ntfy.sh, including catch-up after going offline
./ember/build.sh         # Ember.app, universal, ad-hoc signed
./ember/smoke.sh         # launches the built app and plays "the other Mac" against it
```

Every push to the `ember` branch runs all four on a GitHub macOS runner
(`.github/workflows/ember.yml`) and uploads the zipped app.

| File | |
|---|---|
| `src/Engine.swift` | All behaviour, as a pure state machine: events in, effects out. Every rule above lives here and is tested. |
| `src/Wire.swift` | The message format. Add cases, never rename them. |
| `src/PairSecret.swift` | Pair codes and encryption. |
| `src/NtfyTransport.swift` | The ntfy stream and publishing, with reconnects and catch-up. |
| `src/AppModel.swift` | Glue: carries out effects, saves state, tracks presence. |
| `src/MenuView.swift` | The menu bar popover. |
| `src/AppDelegate.swift` | Status item, glow, pair links. |

### Moving it to its own repo

Ember lives in `ember/` on Jot's `ember` branch because a new repo couldn't
be created from the session that built it. To split it out with history:

```bash
git subtree split --prefix=ember -b ember-only
# create an empty private repo (e.g. lsuryatej/ember), then:
git push git@github.com:lsuryatej/ember.git ember-only:main
```

Then copy `.github/workflows/ember.yml` across and drop the `ember/` prefixes from it.
