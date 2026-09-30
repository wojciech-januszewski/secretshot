# SecretShot

Menu bar app for macOS. Take a screenshot → it OCRs the image **entirely on-device**
(Apple Vision), auto-covers anything that looks like a secret, shows you a preview,
and only then puts the clean image on your clipboard.

Nothing is uploaded. There is no network code in this app at all.

## What it detects

| On by default | Off by default |
|---|---|
| E-mail, IP (public only), MAC address | UUID |
| JWT, Bearer token, private key header | Phone number |
| OpenAI/Anthropic `sk-`, GitHub `ghp_`, AWS `AKIA…`, Slack `xox…`, Google `AIza…` | High-entropy string |
| Stripe, Google OAuth `GOCSPX-`, npm, PyPI, SendGrid, Slack webhook | |
| **FileVault recovery key**, **BitLocker recovery key** | |
| TOTP/MFA secret (`otpauth://`), credentials embedded in a URL | |
| `password: …` / `hasło: …` field values | |
| Card number (Luhn-validated), IBAN | |
| Serial number (only next to "Serial"/"S/N"/"IMEI") | |
| Device UDID (only next to "UDID"/"Hardware UUID") | |
| Bank account (NRB, IBAN mod-97) | |
| PESEL, NIP, REGON, ID card — checksum **and** label required | |
| AWS secret key, Okta token — label required | |

### Why national ID numbers need a label

PESEL carries a check digit *and* an embedded birth date, so it is tempting to detect it
on structure alone. Measured: roughly **3% of random 11-digit numbers satisfy both** — and
admin panels are full of 11-digit order and asset IDs. `Tools/rulestest.sh` had a live
false positive on `Order number 90051512999` before the label requirement was added.
Checksums narrow a search; they don't replace context.

Toggle any of them in the menu bar → **Detect**.

Two deliberate anti-annoyance choices: private IPs (`192.168.*`, `10.*`, …) are ignored,
and serial-number matching requires a nearby label — a bare 10-char alphanumeric blob is
too common to redact blind.

## Build

Needs only Command Line Tools — no Xcode.

```bash
./build.sh                          # → build/SecretShot.app
./build.sh --install                # → ~/Applications, and launches it
./build.sh --install /Applications  # system-wide (needs write access)
```

`~/Applications` is the default on purpose: it needs no sudo, and Screen Recording
permission then sticks to a stable path instead of being re-prompted every time
`./build` is regenerated.

Preview layout can be checked without taking a real screenshot:

```bash
./build/SecretShot.app/Contents/MacOS/SecretShot --demo build/selftest-original.png
```

## Use

| Shortcut | Action |
|---|---|
| `⌘⇧8` | capture a region |
| `⌘⇧9` | capture a window |
| — | menu → *Scan Clipboard Image* for a screenshot you already took |
| — | menu → *Watch Clipboard* to auto-scan anything you `⌃⌘⇧4` into the clipboard |

In the preview window:

| Key / gesture | Action |
|---|---|
| `⏎` | copy redacted image to clipboard, close |
| `⌘S` | save as PNG |
| `⎋` | cancel, nothing is copied |
| click a box | toggle — reveal something redacted by mistake |
| drag on the image | add your own redaction box |
| `⌥`-click a box | delete the box |
| `A` | toggle all |

Boxes are drawn at 92% opacity **in the preview only** so you can still make out what's
underneath and decide whether it really needs hiding. The exported image is fully opaque.

### Verify pass

After redacting, the app re-runs OCR **on the redacted output**. If any rule still
fires, the leftovers are added to the preview and you're asked to confirm again.
It is the cheap insurance against the one screenshot that ends up in a public channel.
Toggle in the menu.

### Redaction style

`Solid black` (default), `Pixelate`, `Blur`. Solid is the only one that is provably
irreversible — pixelate/blur are lossy but not a security guarantee. Redaction is burned
into the pixels, and the output is re-encoded through a bare bitmap context so the
screenshot's EXIF/TIFF metadata is dropped along with it.

## Permissions

On the first capture macOS asks for **Screen Recording** (System Settings → Privacy &
Security). This is `screencapture` running as a child of the app — TCC attributes it to
SecretShot.

The global hotkeys use Carbon `RegisterEventHotKey`, so **no Accessibility permission is
needed**. That's on purpose: an app for security people shouldn't ask for the right to
read every keystroke.

### The Screen Recording prompt keeps coming back

TCC keys the grant to the code signature. An **ad-hoc signature gets a new cdhash on
every build**, so each rebuild looks like a brand-new app and the prompt returns.

Fix it once:

```bash
./Tools/make-signing-cert.sh   # creates a local "SecretShot Dev" identity
./build.sh --install
```

`build.sh` picks that identity up automatically and falls back to ad-hoc if it's absent.
The certificate is local-only — it stops the re-prompting but does **not** let you hand
the app to anyone else. That needs a real Developer ID.

Undo: `security delete-certificate -c "SecretShot Dev" ~/Library/Keychains/login.keychain-db`

### A granted permission that doesn't work

Changing signing identity (ad-hoc → self-signed → Developer ID) **invalidates an
existing grant**, and the failure is silent: System Settings keeps showing SecretShot
toggled ON while `CGPreflightScreenCaptureAccess()` returns false. TCC stored the grant
against the old signature and the new binary no longer matches it.

```bash
./Tools/reset-permission.sh   # tccutil reset + relaunch
```

Then approve again. Verify what the app actually sees — not what the toggle claims:

```bash
pkill -x SecretShot
open ~/Applications/SecretShot.app --args --check-permission
sleep 3 && cat /tmp/secretshot-permission.txt
```

It must be launched via `open`; started from a terminal, TCC attributes the call to the
terminal instead of the bundle and the answer is meaningless.

### Running with no permissions at all

*Watch Clipboard* mode needs **zero** TCC permissions — macOS takes the screenshot
(`⌃⌘⇧4`) and SecretShot only reads the clipboard, which is unrestricted.

Caveat worth knowing: the **unredacted** image sits in the clipboard for up to 0.6 s
before being replaced. Clipboard managers (Raycast, Alfred, Paste) will capture it
permanently. For this particular app that's a real hole — built-in capture is the safer
path despite the permission friction.

## Architecture

```
Sources/SecretShot/
  main.swift          AppDelegate, status item, menu, pipeline
  HotKey.swift        Carbon global hotkeys (no Accessibility needed)
  Capture.swift       screencapture shell-out + clipboard watcher
  Scanner.swift       Vision OCR → per-character bounding boxes → Detection
  Detectors.swift     the rules: regex + Luhn/entropy validators + context gating
  Redactor.swift      burns boxes into pixels, strips metadata, verify pass
  PreviewWindow.swift review UI
  Settings.swift      UserDefaults
```

Coordinates stay in Vision's normalized bottom-left space from OCR all the way to the
output bitmap, so there is no flip anywhere — AppKit's non-flipped views and
CoreGraphics use the same convention.

Three details that matter more than they look:

- A Retina capture's `CGImage` is in **pixels**, window geometry is in **points**.
  Sizing the preview without dividing by `backingScaleFactor` makes it 2× too big,
  which on a multi-display setup means AppKit dumps it on whichever screen it fits —
  and it looks like the window never opened.
- The preview is **aspect-fit, not stretched**: the footer's intrinsic width can make
  the window wider than the image, so normalized rects map to `imageRect`, not `bounds`.

- `usesLanguageCorrection = false` — otherwise Vision "corrects" `ghp_aB3dEf…` into
  words and the token no longer matches its own regex.
- Boxes get vertical padding (18% of glyph height) — OCR boxes hug the glyphs and
  descenders leak otherwise.

### Two things real admin panels taught us

**Context is spatial, not textual.** Jamf renders `Serial Number:` and its value as two
separate OCR observations in different columns. A rule that looks for its keyword in the
same *line* never fires. `Scanner.rowContext` gathers every observation sharing a
horizontal band, so a value in one column can see its label in another.

**OCR confuses glyphs, and the regex has to survive it.** Vision reads `B0:BE:83:17:35:BA`
as `BO:BE:…` (letter O for zero) and `8EF78972` as `BEF78972`. Hex-charset patterns miss
every one of those. MAC and UDID patterns therefore match on a *wider* alphabet and lean on
structure — six colon-separated pairs, or 8-4-4-4-12 — then `looksHexAfterOCRFixes`
undoes the substitutions to confirm. Structure is reliable where the alphabet isn't.

## Tests

```bash
./Tools/selftest.sh   # plain light-background text, 10 planted secrets
./Tools/jamftest.sh   # Jamf-style dark two-column inventory table
./Tools/rulestest.sh  # checksum unit tests + FileVault/PESEL/token rules, with decoys
```

`jamftest.sh` also dumps raw Vision output, which is the fastest way to find out why a
rule didn't fire — usually the OCR text isn't what the screen says it is.

Renders a synthetic admin-panel screenshot with 10 planted secrets and 3 innocent
lookalikes (a version string, a private IP, an all-caps word), runs the real pipeline,
and fails if anything is missed, over-matched, or still readable after redaction.
Writes `build/selftest-original.png` and `build/selftest-redacted.png` to eyeball.

Current: 10/10 caught, 0 false positives, 0 leftovers.

## Not done yet

- Developer ID signing + notarization (required before anyone else can run it)
- Configurable hotkeys
- App icon
- Face/avatar blurring, QR code detection
- Remembering per-app rules ("always redact everything in 1Password")

## Why open source

An app that reads your screenshots should be auditable. You shouldn't have to trust a closed binary with exactly the content it's meant to protect, so the whole pipeline is public, and there is no network code to audit in the first place.

The test fixtures in `Tools/` contain **fake** tokens and keys on purpose, so the detectors have something to catch. They are listed in `.gitleaksignore`.

## License

MIT
