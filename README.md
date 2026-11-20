# Menta Sources

Software Sources for Debian and Menta. It configures where APT downloads
software from: the Debian mirror, archive components, update suites, third
party repositories and their keys. It also fixes common APT problems.

Written in Vala with GTK 3 for the MATE desktop, on X11 and Wayland.
Forked and diverged from Linux Mint's [mintsources](https://github.com/linuxmint/mintsources).

## Build

Build dependencies:

```
sudo apt install meson valac libgtk-3-dev libgee-0.8-dev libjson-glib-dev libsoup-3.0-dev gettext
```

Package:

```
dpkg-buildpackage --no-sign
cd ..
sudo apt install ./menta-sources_*.deb
```

Or directly:

```
meson setup build --prefix=/usr
ninja -C build
sudo ninja -C build install
```

## License

- Code: GPLv3
