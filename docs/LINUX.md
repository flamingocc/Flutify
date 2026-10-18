# Flutify on Linux (experimental)

Linux desktop support is **experimental**. The app builds, runs, signs in and
plays full tracks by driving a system **Google Chrome / Chromium** (with
Widevine) in the background.

## Requirements

- A desktop session (X11 or Wayland) with **glibc 2.34 or newer** — Ubuntu
  22.04+, Debian 12+, Fedora 36+, Arch Linux and their derivatives all
  qualify; Ubuntu 20.04 / Debian 11 are too old.
- Runtime libraries:
  - GTK 3
  - **libmpv** — the `media_kit` audio backend loads `libmpv.so.2` or
    `libmpv.so.1` at startup:

    | Distribution | libmpv package |
    |---|---|
    | Ubuntu 24.04+ / Debian 12+ | `libmpv2` |
    | Ubuntu 22.04 | `libmpv1` |
    | Fedora (RPM Fusion) | `mpv-libs` |
    | Arch Linux | `mpv` (provides `libmpv.so=2`) |

- **Google Chrome** (recommended) or another Chromium build that ships the
  Widevine CDM, for full-track (DRM) playback. Flutify launches it with its own
  profile; your normal browser profile is untouched.

### Widevine-capable browsers

Full-track playback shells out to a system browser; only builds shipping the
Widevine CDM work:

| Distribution | Recommended |
|---|---|
| Debian / Ubuntu | Google Chrome `.deb` from https://www.google.com/chrome/ |
| Fedora | Google Chrome `.rpm` from https://www.google.com/chrome/ |
| Arch Linux | AUR `google-chrome` or `chromium-widevine`; the official `chromium` package has no Widevine |
| Other | Any Chromium build with the Widevine CDM |

## Installing

Linux x64 release artifacts:

- **`.deb`** (Debian, Ubuntu, ...) — registers a launcher, desktop entry and
  icon:

  ```bash
  sudo apt install ./Flutify-<label>-linux-x64.deb
  ```

- **`.tar.gz`** (any distribution) — extract and run the bundled executable,
  no package manager involved:

  ```bash
  tar -xzf Flutify-<label>-linux-x64.tar.gz
  ./Flutify-<label>-linux-x64/flutify
  ```

- **Arch Linux** — AUR package template in `tool/arch/PKGBUILD`
  (`flutify-bin`). It repackages the release `.deb`, so no local Flutter
  toolchain is needed; after publication to the AUR it installs with
  `yay -S flutify-bin` (or any other AUR helper).

The `.deb` and the AUR package declare the library dependencies, but cannot
depend on the proprietary Chrome package — install Chrome separately as
described above.

## Building from source

Install the Flutter 3.44 SDK (https://docs.flutter.dev/get-started/install/linux)
plus the platform build dependencies for your distribution:

```bash
# Debian / Ubuntu
sudo apt-get install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libblkid-dev libstdc++-12-dev libmpv2

# Fedora (mpv packages come from RPM Fusion)
sudo dnf install -y clang cmake ninja-build pkgconf-pkg-config gcc-c++ \
  gtk3-devel libstdc++-devel xz-devel libblkid-devel mpv-libs-devel

# Arch Linux
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 mpv
```

Then build and package:

```bash
flutter pub get
flutter build linux --release
tool/package_linux_deb.sh --label v0.14-beta       # -> dist/Flutify-v0.14-beta-linux-x64.deb
tool/package_linux_tarball.sh --label v0.14-beta   # -> dist/Flutify-v0.14-beta-linux-x64.tar.gz
```

## Feature support on Linux

| Feature | Status |
|---|---|
| Window chrome, drag, minimize/maximize/close, F11 fullscreen | ✅ self-drawn title bar |
| Account sign-in (system browser + loopback OAuth) | ✅ |
| Full-track playback (Widevine via system Chrome/Chromium) | ✅ needs Chrome + one-time Web sign-in |
| Browsing, search, library, playlists, settings | ✅ |
| Lyrics, Spotify Connect, caching, proxies | ✅ |
| Canvas video artwork | ⚠️ falls back to the static cover |
| Share embed preview | ⚠️ unavailable (iframe code still copyable) |
| System media controls / taskbar lyrics | ⚠️ not implemented on Linux |
| In-app auto-update | ⚠️ open the Releases page |

### How full-track playback works

`flutter_inappwebview` has no Linux implementation, so there is no in-app
WebView. Instead, on Linux Flutify:

1. starts a local HTTP server that serves the same HLS.js/EME host page used on
   Windows/macOS (`lib/services/eme/`);
2. launches a system **Chrome/Chromium** (dedicated profile under the app
   support directory) pointed at that page, and drives it over the Chrome
   DevTools Protocol (`lib/services/eme/chrome/`);
3. the page requests the Widevine license through the app (so the Web player
   token is used), and Chrome decrypts and plays the audio.

By default Chrome runs **headless** (`--headless=new`, no window at all); audio
still goes to the system output. If playback is silent on your setup, set
`FLUTIFY_CHROME_WINDOW=1` to run a (mostly off-screen) real window instead. The
managed profile persists, so the one-time **Web sign-in** (which captures the
`sp_dc` cookie needed for the Widevine license) only has to be done once.

The older protocol path (Access Point audio key + AES-CTR) is region-restricted
on many networks and is no longer used.

## Troubleshooting

- **"未找到 Chrome / Chromium"** — install Google Chrome, or a Chromium build
  with the Widevine CDM.
- **"Cannot find libmpv at the usual places"** — install libmpv from the table
  above (`libmpv2` / `libmpv1` on Debian/Ubuntu, `mpv` on Arch, `mpv-libs` on
  Fedora).
- **Playback silent but position advances** — run with `FLUTIFY_CHROME_WINDOW=1`
  (a real Chrome window is more reliable for audio on some setups).
- **No audio device** — make sure PipeWire/PulseAudio is running for your
  session; `media_kit` plays through the default sink.
- **Window has no decorations** — expected; Flutify draws its own title bar.
  If the window manager ignores it, use `Alt`-drag to move the window.
- **Tray/media keys do nothing** — system media controls are not implemented on
  Linux yet.
