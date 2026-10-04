# Menta Sources

Software Sources for Debian and Debian Menta. It configures where APT downloads
software from: the Debian mirror, archive components, update suites, third
party repositories and their keys. It also fixes common APT problems.

Forked from Linux Mint's [mintsources](https://github.com/linuxmint/mintsources).

## What it manages

- **Debian Software**: the official repositories, written in deb822 format to
  `/etc/apt/sources.list.d/debian.sources` (the same file `apt modernize-sources`
  creates):
  - the mirror, chosen from python-apt's Debian mirror list with a speed test
  - components: `main`, `contrib`, `non-free`, `non-free-firmware`
  - suites: `-security`, `-updates`, `-backports`, `-proposed-updates`,
    and `experimental` on sid
  - source code (`deb-src`) and debug symbols (`debian-debug`)
- **Other Software**: every other entry, in one-line `.list` or deb822
  `.sources` files. They can be enabled, disabled, added and removed.
- **Authentication**: keys in `/etc/apt/trusted.gpg.d` and keyrings used by
  `Signed-By`. The Debian archive keys are hidden.
- **Maintenance**: fix MergeList problems, purge residual configuration,
  remove duplicate entries, download missing keys, remove or downgrade
  foreign packages.

Official entries found in `/etc/apt/sources.list` (as written by the Debian
installer) are moved to `debian.sources` on first start. A copy of the original
file is saved in `/var/backups/menta-sources/`.

PPAs are built for Ubuntu and are not supported.

## Supported releases

Each release is described in `usr/share/menta-sources/<codename>/menta-sources.conf`:

| Codename   | Suite              | Optional suites                                |
|------------|--------------------|------------------------------------------------|
| `bookworm` | Debian 12          | security, updates, backports, proposed-updates |
| `trixie`   | Debian 13          | security, updates, backports, proposed-updates |
| `forky`    | Debian 14, testing | security, updates, proposed-updates            |
| `sid`      | unstable           | experimental                                   |

The codename comes from `VERSION_CODENAME` in `/etc/os-release`. Testing and
unstable report the same codename, so unstable is recognized by its `sid` or
`unstable` repositories.

To support a new release, copy a directory and adjust the codename, description
and suites.

## Build

```
dpkg-buildpackage --no-sign
```

Install

```
cd ..
sudo apt install ./menta-sources_*.deb
```

## Test

Run the tests from the root of the project

```
python3 -m unittest
```

## Translations

Generate the template with `./makepot`, translations go in `po/`.

## License

- Code: GPLv3
