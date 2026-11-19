# PockAI and Windows (Boot Camp on a Touch Bar Mac)

**There is no PockAI for Windows, and no `.exe` to download.** Windows can't do what PockAI
needs:

- **No Windows API for custom Touch Bar content.** Under Boot Camp, Apple's driver runs the
  Touch Bar as a fixed row of keys. Windows apps can't add buttons, text, lyrics or widgets.
- **The only way around that is a kernel driver.** The community project
  [DFRDisplayKm](https://github.com/imbushuo/DFRDisplayKm) turns the Touch Bar into a tiny
  second display. It has no signed release, so you have to build it with the Windows Driver
  Kit and turn off Secure Boot. It is confirmed only on T2 Macs, is unmaintained, and an
  unsigned driver that fails can stop Windows from booting. We don't ship or recommend it.

## What you get in Windows (Boot Camp drivers)

After installing the **Boot Camp drivers** (Boot Camp Assistant installs them during Windows
setup; Apple's Windows Support Software otherwise), the Touch Bar shows:

- Esc, brightness, keyboard light, media keys and volume
- **F1–F12 while you hold Fn**

That's built into Apple's driver. Nothing extra is needed or possible.

## Windows 11

Apple's Boot Camp officially supports **Windows 10**. Intel Touch Bar Macs don't meet Windows
11's TPM 2.0 requirement, so Windows 11 on Boot Camp is unofficial. If you install it anyway,
the Boot Camp drivers give you the same Touch Bar keys as above.

## Want the full PockAI experience?

Restart into **macOS**: hold ⌥ Option at startup, or use the Boot Camp tray icon → "Restart in
macOS". PockAI works on macOS 12 Monterey and newer. **Linux** on a Touch Bar Mac gets
media, clock and battery layouts; see [`../Linux/README.md`](../Linux/README.md).
