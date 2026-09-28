---
title: "Builds"
description: "Android APK and Linux download links, one per day."
---

Daily Android APK and Linux builds are published here automatically on every push to main.

Each entry links to the build and the commit that produced it.

## Linux: install with mise

The daily builds above are git-hash snapshots. For a versioned install that upgrades itself, use
[mise](https://mise.jdx.dev/) — it installs from the project's GitHub Releases:

```bash
mise use -g github:guettli/sharedinbox@latest
sharedinbox
```

Upgrade later with `mise up sharedinbox`.

Runtime prerequisites on Debian 13+ / Ubuntu 24.04+ (the bundle needs glibc 2.39 or newer):

```bash
sudo apt install libgtk-3-0t64 libsecret-1-0 libgcrypt20 libjsoncpp25 zenity xdg-utils
```

(On Debian 13 the jsoncpp package is `libjsoncpp26`.)

A running keyring (gnome-keyring, KWallet, …) is required for account passwords. See the
[README](https://github.com/guettli/sharedinbox#install-on-linux-with-mise) for the explicit mise
options and for adding an application-menu entry.
