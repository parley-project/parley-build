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
| parley-files-viewer-tui (`pfv`; fsh has the same browser built in) | `parley-files-viewer-tui-V.zip`, `.tar.gz` | `.deb`, `.rpm`, `.pkg`, `.msi` | (part of fsh, native too) |
| parley-ssh (`pssh`, the SSH client) | `parley-ssh-V.zip`, `.tar.gz` | `.deb`, `.rpm`, `.pkg`, `.msi` | |
| parley-servers (DNS, FTP, SSH, and the mail servers: SMTP, submission, IMAP, POP3, and FTP for the mail users) | `parley-servers-V.zip`, `.tar.gz` | `.deb`, `.rpm` (Linux), `parley-servers-V-macos-ARCH.pkg` | |
| parley-mail-admin (the mail servers' web administration, a war) | `parley-mail-admin-V.zip`, `.tar.gz` | `.deb`, `.rpm` (Linux, for the system's Tomcat 10.1) | |

Every file has a `.sha256` beside it. Nothing is signed or notarized. JavaFX's jars are for one
platform, so the window applications' plain archives are made on each; the others' once, on
Linux x86-64. The Linux packages' file names have `-` where their versions have `~`
(`fsh_2.0.0-preview.20261024_amd64.deb` is version `2.0.0~preview.20261024`).

## What the installers install

- **Linux** (`.deb`, `.rpm`): `/opt/parley/NAME` (`bin`, `lib`, `runtime`), the commands in
  `/usr/bin`, a menu entry for each window application. fsh's own packages install `/opt/fsh` and `/usr/bin/fsh` (in `/etc/shells`).
- **macOS**: the window applications as a `.dmg` (an application to drag to Applications, with
  the Swing launcher as its main one and the JavaFX one beside it); the terminal programs as a
  `.pkg`: `pfv` (`/usr/local/lib/parley/parley-files-viewer-tui`, `/usr/local/bin/pfv`) and `pssh`
  (`/usr/local/lib/parley/parley-ssh`, `/usr/local/bin/pssh`).
- **Windows** (`.msi`): `C:\Program Files\NAME`, with Start menu entries (group Parley). The
  installers don't change `PATH`.

### The servers (`parley-servers`)

**Linux** (`.deb`, `.rpm`): `/opt/parley/servers` with a launcher for each server (`bin/parley-dns`,
`-ftp`, `-ssh`, and `bin/parley-mail` for the mail servers), its settings in `/etc/parley` (kept on
upgrade), and a systemd service for each, `parley-NAME.service`, **installed but not enabled or
started**:

```sh
sudo systemctl enable --now parley-mail
```

The services run as the account `parley` (made by the package), may use ports below 1024, and
keep their data in `/var/lib/parley` (`mail`, `ftp`), their logs in `/var/log/parley`, and their
settings in `/etc/parley` (`dns`, `ssh` too). A server without a `main` method in the build is
left out. DNS needs a zone file in
`/etc/parley/dns/zones` before it starts.

**macOS** (`.pkg`): `/usr/local/lib/parley/servers`, with a launchd daemon for each server in
`/Library/LaunchDaemons` (`us.bringardner.parley.NAME.plist`), **made but not started**:

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/us.bringardner.parley.mail.plist
```

They run as the user logged in at the console when it was installed (macOS lets any user use ports
below 1024), with the settings in `/etc/parley`, data in `/usr/local/var/parley` and logs in
`/usr/local/var/log/parley`.

**Plain archive**: unpack it where it is to stay, then `sudo bin/parley-servers-setup
--create-account --units systemd` (Linux) or `--units launchd` (macOS) makes the same folders,
settings and services for that folder; `--user`, `--conf`, `--data` and `--logs` choose others, and
without `--units` it only makes the folders and settings (run `bin/parley-mail` yourself). The
packages run the same script (`bin/parley-servers-setup --help`).

#### The mail servers: one service

`parley-mail` is parley-net's launcher (`ServerMain`) running the mail servers that
`parley.servers` lists in `/etc/parley/parley-mail.properties`: `smtp`, `submission`,
`submissions`, `imap`, `imaps`, `pop3`, `pop3s`, `ftp` and `ftps`, in one process, serving one mail
store. A server whose port is 0 is off; the implicit TLS ones are off until they have a port and a
key store. `ftp` and `ftps` give the mail users FTP: the users file, the local domains and the store
are the mail servers' (log in as `name@domain`; each user's files are in `.ftp/DOMAIN/NAME` in the
store; logins need TLS). They and the separate `parley-ftp` service both want port 21: run one.

| `/etc/parley/` | |
|---|---|
| `parley-mail.properties` | What the mail servers share: `parley.servers`, the mail root, the users file, the TLS key store, logging; and where parley-mail-admin finds them |
| `parley-smtp.properties`, `parley-imap.properties`, `parley-pop3.properties`, `parley-mail-ftp.properties` | Each protocol's own settings, read after the shared file |
| `users.txt`, `aliases.txt` | The users and the SMTP aliases (the queue's `aliases` names the file) |
| `parley-mail.jvm` | Java options (a `java @argfile`): JMX on `127.0.0.1:9010` with a password |
| `jmx/` | The JMX password files, made at install with a new password: `jmxremote.password` (the service's account only), `jmxremote.access`, `admin.password` (for parley-mail-admin) |
| `parley-dns.properties`, `parley-dns.jvm` | The DNS server's settings (recursion off; dynamic updates only with `dns/admin.key`) and Java options: JMX on `127.0.0.1:9011`, with the same password |
| `dns/zones/`, `dns/shared.zone`, `dns/admin.key` | The zone files (the primary domain's by hand; a listed domain's, which inherits the shared zone with `$INHERIT`, made by parley-mail-admin's DNS page when it gets records of its own), the shared zone every listed domain is served from (by hand, `parley.dns.sharedZone`), and the TSIG key the DNS page signs record changes with, made at install (the group may read it) |

The mail settings files and `/etc/parley` belong to the group `parley` and are group-writable, so
parley-mail-admin (in that group) can edit them; the mail store and logs are group-readable.

parley-mail-admin manages any Parley server it reaches over JMX (its Servers page), and the DNS
server's zones (its DNS page, where a DNS server runs): to manage the parley-dns service too, list
its JMX address beside parley-mail's in `parley.mail.admin.jmxUrl` and set
`parley.mail.admin.dnsKeyFile=/etc/parley/dns/admin.key` (commented in `parley-mail.properties`).

The store and the queue carry their own settings, in the data folder, so the servers can't disagree
about them (parley-mail's and parley-smtp's READMEs); `parley-servers-setup` makes both once:

| `/var/lib/parley/mail/` | |
|---|---|
| `.parley-store.properties` | The store's: `sharing=host`, since the service's servers are several servers on one store |
| `.smtp-queue/queue.properties` | The queue's (shared by `smtp`, `submission` and `submissions`): `hostname` and `domains` (both required), the aliases file, the smart host, DKIM keys |

Each SMTP server needs its own hostname too (`parley.mail.smtp.hostname`,
`parley.mail.submission.hostname`, `parley.mail.submissions.hostname` in `parley-smtp.properties`).
None of them has a default (it isn't taken from the machine's name), so after installing, give them
once and start the service:

```sh
sudo /opt/parley/servers/bin/parley-servers-setup --hostname mail.example.com --domains example.com
sudo systemctl enable --now parley-mail
```

##### A store that several machines share

The mail store can be on any of Parley's file systems instead of the local disk; the package has
the database one (parley-files-jdbc, and MySQL's driver), for machines that all serve the same
mail. `parley-mail.properties` names the file system and gives its connection settings, each
`parley.mail.fileSource.KEY` being the file system's setting `KEY`, a secret as a reference:

```properties
parley.mail.root=/mail
parley.mail.fileSource=Jdbc
parley.mail.fileSource.jdbcUrl=jdbc:mysql://db.example.com:3306/file_source
parley.mail.fileSource.jdbcUser=parley
parley.mail.fileSource.jdbcPassword=@file:/etc/parley/store.secret
```

(or `parley.mail.root` is one `filesource:` URL with them all). The store's and the queue's own
settings are then in that store, not in `/var/lib/parley/mail`. `parley-servers-setup` makes them
there, with `sharing=cluster` (servers on several machines; `--sharing` for another), finding the
store from `parley-mail.properties` as the servers do (through parley-mail's `StoreSetup`, so it
needs Java and the store reachable; when it isn't, the script says so and the package installs
anyway: run it again). Set the store in `parley-mail.properties` before running it with
`--hostname` and `--domains`, or it makes them on the local disk.

Until they are set, the setup script lists what is missing and the servers refuse to start, naming
the setting. Running the script again only fills settings that are empty; it never changes a value.

#### The spam scanner (rspamd)

The SMTP servers can ask a scanner about each message (parley-smtp's README, `spam.*` queue
settings). rspamd is a separate program: the `.deb` and `.rpm` list it as a recommended package
(`apt install rspamd`, `dnf install rspamd`; the plain archive needs it installed by hand). When
`/etc/rspamd` exists, or with `parley-servers-setup --rspamd`, the setup script puts the package's
`rspamd/local.d` files in `/etc/rspamd/local.d` (the scanner listens on `127.0.0.1:11333` only)
and sets `spam.provider=rspamd` in the queue's `queue.properties`, if it has no provider. Spam
filtering stays **off** until `spam.enabled=true` (parley-mail-admin: Settings > Spam; a domain can
override it on the Domains page). Restart rspamd after the first setup (`systemctl restart rspamd`).

#### The health check

`bin/parley-health` checks this machine's Parley servers and mails an alert when that changes (a
problem found, or every problem gone), not at every run: the systemd units in
`parley.health.services` are active, the ports in `parley.health.ports` answer, the file systems of
the mail root and the logs are under `parley.health.diskPercent` (80) full, no message has waited
in the SMTP queue over `parley.health.queueMinutes` (60), and the certificate on
`parley.health.certPort` expires in more than `parley.health.certDays` (30) days. Its settings are
`/etc/parley/parley-health.properties`; the alerts go to `parley.health.alertTo` from
`parley.health.alertFrom` through this machine's relay (`parley.health.smtp`, 127.0.0.1:25), so use
an address on another server. On systemd, `parley-health.timer` runs it every 5 minutes, as the
account `parley`; it isn't enabled by the package:

```sh
sudo /opt/parley/servers/bin/parley-servers-setup --alert-to you@example.org --alert-from postmaster@example.com
sudo systemctl enable --now parley-health.timer
journalctl -u parley-health        # every run's result
sudo -u parley /opt/parley/servers/bin/parley-health --test   # a test alert
```

### The administration (`parley-mail-admin`)

A war, deployed in a Tomcat 10.1 or later that is already installed. The Linux packages need the
system's Tomcat (`tomcat10` on Debian and Ubuntu; `tomcat10` or `tomcat` on Fedora, RHEL and Amazon
Linux): they put the war in `/usr/share/parley-mail-admin` and run its `bin/parley-mail-admin-setup`,
which

1. puts `conf/Catalina/localhost/parley-mail-admin.xml` in the Tomcat: the war, the settings folder
   (`/etc/parley`, the servers') and the admin's home (`/var/lib/parley/mail-admin`)
2. adds a systemd drop-in for the Tomcat service (`tomcat10.service.d/parley-mail-admin.conf`): it
   may write to those folders and to the mail store's and queue's own settings files
   (`/var/lib/parley/mail/.parley-store.properties`, `/var/lib/parley/mail/.smtp-queue`), since
   Debian's Tomcat may write only to its own, and is in the group `parley`
3. restarts a running Tomcat service, so the drop-in applies (`--no-restart`: not; then
   `sudo systemctl restart tomcat10`, or `tomcat`)

The pages are at `http://localhost:8080/parley-mail-admin/`. With parley-servers installed, the admin manages the
`parley-mail` service over JMX (the settings the servers' package made tell it where and with
which password); without it, the admin runs the mail servers in Tomcat itself.

Elsewhere (macOS with Homebrew's `tomcat@10`, a Tomcat of your own), unpack the plain archive where
it is to stay and run `sudo bin/parley-mail-admin-setup` (it finds Homebrew's Tomcat, or give it
`--catalina-base DIR`). `--remove` takes it out again; `--help` says the rest. Serve the pages over
HTTPS (a Tomcat HTTPS connector, or a reverse proxy) before they are reachable from other machines.

## Running the scripts

Build all of Parley first, from the repositories beside this one (`packaging/checkout.sh` clones
those that are missing):

```sh
mvn install -DskipTests                       # in parley-build
packaging/package.sh all                      # plain archives and installers for this platform
packaging/package.sh --types plain fsh-ide    # one kind, one application
packaging/native.sh fsh fsh-ide               # native binaries (GraalVM as JAVA_HOME)
```

parley-mail-admin is built (and packaged) when its folder is there: `checkout.sh` leaves it out
when its repository can't be cloned (it is marked `optional` in `repos.txt`), and the aggregator
builds it with the profile `parley-mail-admin` when `../parley-mail-admin` exists.

`--version` and `--label` name the files (`--label preview.20261024` gives `2.0.0-preview.20261024`;
the Linux packages' versions sort before `2.0.0`'s). The applications are described in `apps/*.conf`,
the servers' settings files and service in `servers/`.

Needs: a JDK 17 or later with `jlink` and `jpackage` (25 for fsh's AOT cache); `dpkg-deb` and
`rpmbuild` on Linux; the WiX Toolset on Windows (for jpackage), and the MSVC build tools for fsh's
keyboard library; GraalVM 24 or later for the native binaries.

## The workflow

`preview.yml` runs by hand (Actions > preview > Run workflow), with other branches for some
repositories if you like (`fsh=installers parley-ssh=my-branch`), and every night when one of the
`release-2.0.0` branches (or this repository) has changed since the last run that built. A
scheduled run uses the workflow on this repository's default branch.

With the secret `PARLEY_RELEASE_TOKEN` (a token that can write releases in parley-project's
repositories), each application's files also go on the pre-release `v2.0.0-preview` of its own
repository (`publish.txt`), where people without access to this one can download them.
