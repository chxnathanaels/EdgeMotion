# EdgeMotion

Small app for optimizing touchpad movement on Hackintosh laptop devices.

Windows-style **edge motion** for macOS trackpads: when your finger slides into the edge of the trackpad and stays there, the pointer (or the window you're dragging) keeps moving in that direction. Handy on small trackpads, where you'd otherwise run out of room mid-drag.

Built for a ThinkPad hackintosh (VoodooI2C + VoodooInput), but it works with any trackpad macOS sees as multitouch, including real Mac trackpads. Version 2 adds its own pointer engine, two-finger click-drag, tap gestures, smooth brightness and a key mapper.

<p align="center"><img src="docs/panel.png" width="300" alt="Edge Motion menu bar panel"></p>

## Features

**Pointer engine**
- Takes over trackpad pointer motion from macOS with a tunable acceleration curve (default: libinput's, the touchpad driver used on Linux): slow movements are scaled down for precision, medium speeds move 1:1, fast flicks accelerate
- Presets (Linux, macOS-like, Linear) plus sliders for speed, precision and acceleration, with a live curve graph

**Dragging**
- Click with one finger, drag with another: the pointer follows the moving finger, not the one holding the click, whichever touched first

**Edge motion**
- When your finger slides into the trackpad edge and stays there, the pointer (or dragged window) keeps moving
- Edge width and speed, ramps up smoothly, works with click-drag and three-finger drag, optional "only while dragging"
- Ignores resting thumbs, two-finger scrolls and gestures

**Gestures**
- Three- and four-finger taps: Quick Look / Look Up (like Force Click), middle click, Mission Control, App windows, Show Desktop, Spotlight, screenshot toolbar

**Smooth brightness**
- Brightness keys fade the backlight between steps instead of jumping, like a real Mac, with an on-screen indicator and optional finer steps

**Keyboard mapper**
- Remap any key (PrtSc arrives as F13 on ThinkPads): screenshots, Spotlight, Siri, lock screen, open an app, run a Shortcut, type text, or send another key combination

**App**
- Menu bar panel for quick changes, plus a System Settings-style window with illustrations for every section
- Open at login
- Runs in user space: no kext, no reboot, nothing in your EFI

## Install

**Download:** grab `EdgeMotion.zip` from [Releases](../../releases), unzip, and move **Edge Motion** to Applications.

The app isn't notarized, so the first time, right-click it > **Open** (or allow it in System Settings > Privacy & Security). You can also clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/EdgeMotion.app
```

**Or build it yourself** (needs Command Line Tools: `xcode-select --install`):

```sh
git clone https://github.com/chxnathanaels/EdgeMotion
cd EdgeMotion
./build.sh --install
```

## First run

1. Allow **Accessibility** when asked (System Settings > Privacy & Security > Accessibility > Edge Motion ON). It's needed to move the pointer.
2. Quit Edge Motion from its menu bar icon and open it again.
3. Turn on **Open at login** in the panel.

After updating or rebuilding, macOS may reset the permission: toggle Edge Motion off and on in the Accessibility list.

## How it works

EdgeMotion reads touch frames from Apple's private `MultitouchSupport` framework. A small C engine picks the finger that should drive the pointer (the moving one, not the one holding the click), applies the acceleration curve, adds edge motion, and detects multi-finger taps. A system event tap hides macOS's own trackpad pointer motion while EdgeMotion is driving, handles the brightness keys and applies key mappings.

The acceleration curve follows libinput's touchpad profile (MIT licensed): a precision zone that scales slow movement down to 30 %, a 1:1 plateau, then a curve that accelerates up to four times the threshold speed.

If the pointer ever feels wrong, turn off **EdgeMotion moves the pointer** in the menu bar panel to hand control back to macOS instantly.

## Uninstall

Quit it from the menu bar, delete `/Applications/EdgeMotion.app`, and remove it from Accessibility and Login Items.

## Notes

- Uses a private Apple framework, so a future macOS update could break it.
- macOS 13 Ventura or later.
- If you use the three-finger tap, turn off macOS's own "Look up & data detectors: Tap with three fingers" so both don't fire.

## License

[Apache 2.0](LICENSE)
