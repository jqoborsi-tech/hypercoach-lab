# Getting ArchScan onto your Mac and your phone

## What you need

- A Mac running macOS Sequoia (15) or newer.
- **Xcode 16 or newer**, from the Mac App Store. It is a large download — start it first.
- Your iPhone and a cable. Face tracking does not work in the Simulator, so the app
  has to run on the device.
- An Apple ID. A free one is enough for running on your own phone; a paid Developer
  Program membership is only needed to send builds to other people.

## 1. Get the code

Open **Terminal** on the Mac and paste this:

```bash
cd ~/Developer 2>/dev/null || mkdir -p ~/Developer && cd ~/Developer
git clone https://github.com/jqoborsi-tech/hypercoach-lab.git
cd hypercoach-lab
git checkout claude/facial-scanner-arch-surgery-tepwpf
open face-scanner/ArchScan.xcodeproj
```

The first `git clone` will ask you to sign in to GitHub. If it asks for a password,
give it a **personal access token** rather than your account password (GitHub →
Settings → Developer settings → Personal access tokens), or install GitHub Desktop and
clone the repository from there instead — either is fine.

Everything is on the branch `claude/facial-scanner-arch-surgery-tepwpf`. If you forget
the name: `git branch -a` lists them.

## 2. Set the signing team

Xcode will not build anything until it knows who you are.

1. In the left sidebar click the blue **ArchScan** project icon at the top.
2. Select the **ArchScan** target, then the **Signing & Capabilities** tab.
3. Tick **Automatically manage signing**.
4. Pick your name in **Team**. If the list is empty: Xcode → Settings → Accounts → **+**
   → Apple ID, sign in, then come back.
5. Change **Bundle Identifier** to something nobody else has used, e.g.
   `com.yourname.archscan`. This is the one step people skip, and it fails with a
   confusing error about provisioning profiles.

## 3. Run it on the phone

1. Plug the iPhone in. Unlock it and tap **Trust** if it asks.
2. In the toolbar, set the run destination (next to the ArchScan name at the top) to
   your iPhone rather than a simulator.
3. Press **⌘R**.
4. The first run stops on the phone with "Untrusted Developer". On the iPhone go to
   **Settings → General → VPN & Device Management**, tap your Apple ID, and **Trust**.
   Press ⌘R again.

With a free Apple ID the app expires after 7 days and needs a re-run from Xcode. With a
paid membership it lasts a year.

## 4. When the first build fails

**Expect this.** This code was written without a Mac to compile on, so the first build
will almost certainly surface some compile errors — wrong argument label, a type that
needs an annotation, that kind of thing. It is normal and it is quick to clear.

To get the whole list at once instead of clicking through Xcode one error at a time,
run this in Terminal from the repository folder:

```bash
xcodebuild -project face-scanner/ArchScan.xcodeproj \
           -scheme ArchScan \
           -destination 'generic/platform=iOS' \
           -configuration Debug \
           build 2>&1 | grep -E "error:|warning: unused" | sort -u
```

Copy that output and send it back — it is exactly what is needed to fix them in one
pass. Errors are reported as `file:line:column: error: message`, which pins each one
precisely.

## 5. If you change things on the Mac

```bash
git add -A
git commit -m "what you changed"
git push
```

That pushes back to the same branch, so the next session here picks up your changes.

## Where things are

```
face-scanner/
  ArchScan.xcodeproj      ← open this
  ArchScan/
    App/                  app entry point
    Model/                cases, landmarks, clinical analysis
    Capture/              TrueDepth fusion and reconstruction
    Import/               DICOM, CBCT, intraoral mesh import, ICP registration
    Records/              the records checklist
    SmileDesign/          parametric smile design and renderer
    Export/               OBJ / PLY / STL writers, lab handoff
    UI/                   every screen
  validation/             Python checks for the geometry (run with python3)
face-scan/index.html      browser viewer for the exports
```
