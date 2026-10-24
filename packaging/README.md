# Packaging

Pre-built Parley applications: plain archives, installers with their own Java runtime, native
binaries and the servers as Linux services, built from the whole of Parley. The workflow
`.github/workflows/preview.yml` runs these scripts on Linux (x86-64, ARM64), macOS (Apple
silicon, Intel) and Windows, and puts the files on the pre-release `v2.0.0-preview`.

| Application | Plain archive | Installers (own Java runtime) | Native (GraalVM) |
|---|---|---|---|
| fsh | `fsh-V.zip`, `.tar.gz` | fsh's own: `.deb`, `.rpm`, `.dmg`, `.msi`, and `fsh-V-PLATFORM-ARCH-jvm.tar.gz` | `fsh-V-PLATFORM-ARCH.tar.gz` (`.zip`), with the terminal browser built in |
| fsh-ide (Swing, JavaFX) | `fsh-ide-V-PLATFORM-ARCH.zip`, `.tar.gz` | `.deb`, `.rpm`, `.dmg`, `.msi` | `fsh-ide-V-PLATFORM-ARCH-native.tar.gz` (`.zip`) |
| parley-files-viewer (Swing, JavaFX) | `parley-files-viewer-V-PLATFORM-ARCH.zip`, `.tar.gz` | `.deb`, `.rpm`, `.dmg`, `.msi` | `parley-files-viewer-V-PLATFORM-ARCH-native.tar.gz` (`.zip`) |
| parley-files-viewer-tui (`pfv`, fsh's browser plugin) | `parley-files-viewer-tui-V.zip`, `.tar.gz` | `.deb`, `.rpm`, `.pkg`, `.msi` | (built into the native fsh) |
| parley-servers (DNS, FTP, SSH, POP3, IMAP, SMTP) | `parley-servers-V.zip`, `.tar.gz` | `.deb`, `.rpm` (Linux only) | |

Every file has a `.sha256` beside it. Nothing is signed or notarized. JavaFX's jars are for one
platform, so the window applications' plain archives are made on each; the others' once, on
Linux x86-64. The Linux packages' file names have `-` where their versions have `~`
(`fsh_2.0.0-preview.20261024_amd64.deb` is version `2.0.0~preview.20261024`).

## What the installers install

- **Linux** (`.deb`, `.rpm`): `/opt/parley/NAME` (`bin`, `lib`, `runtime`), the commands in
  `/usr/bin`, a menu entry for each window application. `pfv`'s package also links its jar into
  fsh's system plugin folder, `/usr/local/lib/parley/fsh/plugins`, so fsh has `browse`, `view`,
  `edit` and `search`. fsh's own packages install `/opt/fsh` and `/usr/bin/fsh` (in `/etc/shells`).
- **macOS**: the window applications as a `.dmg` (an application to drag to Applications, with
  the Swing launcher as its main one and the JavaFX one beside it); `pfv` as a `.pkg`
  (`/usr/local/lib/parley/parley-files-viewer-tui`, `/usr/local/bin/pfv`, and the plugin link).
- **Windows** (`.msi`): `C:\Program Files\NAME`, with Start menu entries (group Parley). The
  installers don't change `PATH`.

### The servers (`parley-servers`, Linux)

`/opt/parley/servers` with one launcher for each server (`bin/parley-dns`, `-ftp`, `-ssh`,
`-pop3`, `-imap`, `-smtp`), its settings in `/etc/parley/parley-NAME.properties` (kept on upgrade),
and a systemd service for each, `parley-NAME.service`, **installed but not enabled or started**:

```sh
sudo systemctl enable --now parley-pop3
```

The services run as the account `parley` (made by the package), may use ports below 1024, and
keep their data in `/var/lib/parley` (`mail`, `ftp`) and `/etc/parley` (`dns`, `ssh`). POP3, IMAP
and SMTP share the mail store (`parley.mail.sharedStore=host`). A server without a `main` method
in the build is left out (the SSH server's is on parley-ssh's branch `ssh-service`). DNS needs a
zone file in `/etc/parley/dns/zones` before it starts.

## Running the scripts

Build all of Parley first, from the repositories beside this one (`packaging/checkout.sh` clones
those that are missing):

```sh
mvn install -DskipTests                       # in parley-build
packaging/package.sh all                      # plain archives and installers for this platform
packaging/package.sh --types plain fsh-ide    # one kind, one application
packaging/native.sh fsh fsh-ide               # native binaries (GraalVM as JAVA_HOME)
```

`--version` and `--label` name the files (`--label preview.20261024` gives `2.0.0-preview.20261024`;
the Linux packages' versions sort before `2.0.0`'s). The applications are described in `apps/*.conf`,
the servers' settings files and service in `servers/`.

Needs: a JDK 17 or later with `jlink` and `jpackage` (25 for fsh's AOT cache); `dpkg-deb` and
`rpmbuild` on Linux; the WiX Toolset on Windows (for jpackage), and the MSVC build tools for fsh's
keyboard library; GraalVM 24 or later for the native binaries.

## The workflow

`preview.yml` runs by hand (Actions > preview > Run workflow), with other branches for some
repositories if you like (`fsh=installers parley-ssh=ssh-service`), and every night when one of the
`release-2.0.0` branches (or this repository) has changed since the last run that built. A
scheduled run uses the workflow on this repository's default branch.

With the secret `PARLEY_RELEASE_TOKEN` (a token that can write releases in parley-project's
repositories), each application's files also go on the pre-release `v2.0.0-preview` of its own
repository (`publish.txt`), where people without access to this one can download them.
