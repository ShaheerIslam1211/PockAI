# PockAI for Linux (Touch Bar MacBook Pro)

Linux can drive the MacBook Pro Touch Bar with **tiny-dfr**, a small open-source daemon. This
package installs tiny-dfr if needed, adds three PockAI layouts and a `pockai-touchbar`
command to switch between them.

> The full PockAI app (Dock, lyrics, AI, subtitles, games, settings window) uses macOS-only
> Touch Bar APIs, so it can't run on Linux. Linux gets media keys, brightness, a clock and
> battery, with F1–F12 when you hold Fn.

## Install

| Distro | Download | Command |
|---|---|---|
| **Fedora** | `pockai-touchbar-1.0.0-1.noarch.rpm` | `sudo dnf install ./pockai-touchbar-1.0.0-1.noarch.rpm` |
| **Ubuntu 25.04+ / Debian 13+** | `pockai-touchbar_1.0.0_all.deb` | `sudo apt install ./pockai-touchbar_1.0.0_all.deb tiny-dfr` |
| **Ubuntu 24.04 / Linux Mint 22 / Pop!_OS** | `pockai-touchbar_1.0.0_all.deb` | First add the [t2 Ubuntu repo](https://github.com/AdityaGarg8/t2-ubuntu-repo), then the same `apt install` command |
| **Arch / Manjaro / any other distro** | `pockai-touchbar-1.0.0-linux.tar.gz` | `tar xzf pockai-touchbar-1.0.0-linux.tar.gz && cd pockai-touchbar-1.0.0 && sudo ./install.sh` |

`install.sh` also works on Fedora, Ubuntu and Mint. It picks dnf, apt or pacman automatically.

**T2 Macs (2018–2020)** also need the T2 Linux kernel, which provides the keyboard, trackpad,
Touch Bar, audio and Wi-Fi. Follow https://wiki.t2linux.org for your distro, then reboot.
**T1 Macs (2016–2017)** are experimental.

## Use

```bash
pockai-touchbar status           # Mac, drivers, tiny-dfr, current layout
pockai-touchbar layouts          # pockai, minimal, function-keys
pockai-touchbar apply minimal    # switch layout (asks for sudo)
pockai-touchbar restore          # back to the config you had before PockAI
```

| Layout | Default row | With Fn |
|---|---|---|
| `pockai` | brightness · keyboard light · clock · battery · ⏮ ⏯ ⏭ · mute · volume | F1–F12 |
| `minimal` | brightness · date and time · ⏮ ⏯ ⏭ · volume, no outlines; double-press Fn switches rows | F1–F12 |
| `function-keys` | F1–F12 | media and brightness |

To customise further, edit `/etc/tiny-dfr/config.toml`; the options are documented in
`/usr/share/tiny-dfr/config.toml`. Then run `sudo systemctl restart tiny-dfr`.

## Uninstall

- **Fedora:** `sudo dnf remove pockai-touchbar`
- **Ubuntu / Mint / Debian:** `sudo apt remove pockai-touchbar`
- **Archive install:** `sudo ./install.sh --uninstall`

Uninstalling restores your previous tiny-dfr config.
