#!/usr/bin/env bash
# Package the Parley applications for this platform, from the build of all of Parley (the
# aggregator in this folder's parent, built first with "mvn install"). For each application:
#
#   plain       the jars and a launcher for Java on PATH (or JAVA_HOME): NAME-VERSION.zip and
#               .tar.gz, or NAME-VERSION-PLATFORM-ARCH.zip and .tar.gz for an application whose
#               jars are for one platform (JavaFX's)
#   installer   with a Java runtime of its own (jlink), so nothing else needs to be installed:
#                 Linux    NAME_VERSION_ARCH.deb and NAME-VERSION-RELEASE.ARCH.rpm (/opt/parley/NAME,
#                          commands in /usr/bin, menu entries for the window applications)
#                 macOS    NAME-VERSION-macos-ARCH.dmg (an application to drag to Applications), or
#                          for a terminal program NAME-VERSION-macos-ARCH.pkg (/usr/local/lib/parley/NAME,
#                          commands in /usr/local/bin)
#                 Windows  NAME-VERSION-windows-ARCH.msi
#
# with a .sha256 beside each file. The applications are described in packaging/apps/*.conf; fsh
# is packaged by its own scripts (tools/ in fsh). The servers (parley-servers) are one Linux
# package, parley-servers (.deb, .rpm: /opt/parley/servers, a systemd service for each, not
# enabled, settings in /etc/parley, run as the account parley), and one plain archive.
#
# Usage: packaging/package.sh [options] APP...       (APP: a name in packaging/apps, or all)
#   --version V    the version (default: parley-parent's, without -SNAPSHOT)
#   --label L      a pre-release label: files are named V-L (2.0.0-preview.20261024), and the
#                  Linux packages' versions sort before V's (2.0.0~preview.20261024, release 0.L)
#   --types T      plain, installer or "plain installer" (the default)
#   --out DIR      where the files go (default: dist in parley-build)
#
# Needs a JDK 17 or later with jlink and jpackage in JAVA_HOME (or on PATH), and for the
# installers: dpkg-deb and rpmbuild (Linux), the WiX Toolset (Windows, for jpackage). Nothing is
# signed or notarized.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
build=$(cd "$here/.." && pwd)
root=$(cd "$build/.." && pwd)

version=""
label=""
types="plain installer"
out="$build/dist"
apps=()
while [ $# -gt 0 ]; do
	case $1 in
	--version) version=${2#v}; shift ;;
	--label) label=$2; shift ;;
	--types) types=$2; shift ;;
	--out) out=$2; shift ;;
	-h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) echo "package.sh: unknown option $1" >&2; exit 2 ;;
	*) apps+=("$1") ;;
	esac
	shift
done
if [ ${#apps[@]} -eq 0 ]; then
	echo "usage: packaging/package.sh [--version V] [--label L] [--types T] [--out DIR] APP... (or all)" >&2
	exit 2
fi
if [ "${apps[0]}" = all ]; then
	apps=()
	for f in "$here"/apps/*.conf; do
		apps+=("$(basename "$f" .conf)")
	done
fi

# ---------------------------------------------------------------- the platform and the JDK

case $(uname -s) in
Linux) platform=linux ;;
Darwin) platform=macos ;;
MINGW*|MSYS*|CYGWIN*) platform=windows ;;
*) echo "package.sh: unknown platform $(uname -s)" >&2; exit 1 ;;
esac
case $(uname -m) in
x86_64|amd64) arch=x86_64; deb_arch=amd64 ;;
arm64|aarch64) arch=aarch64; deb_arch=arm64 ;;
*) arch=$(uname -m); deb_arch=$arch ;;
esac
exe=""
[ $platform = windows ] && exe=.exe

[ $platform = windows ] && [ -n "${JAVA_HOME:-}" ] && JAVA_HOME=$(cygpath -u "$JAVA_HOME")
if [ -z "${JAVA_HOME:-}" ]; then
	if [ $platform = macos ] && [ -x /usr/libexec/java_home ]; then
		JAVA_HOME=$(/usr/libexec/java_home)
	else
		JAVA_HOME=$(cd "$(dirname "$(readlink -f "$(command -v javac)")")/.." && pwd)
	fi
fi
for tool in java jlink jpackage; do
	if [ ! -x "$JAVA_HOME/bin/$tool$exe" ]; then
		echo "package.sh: no $tool in JAVA_HOME ($JAVA_HOME): set JAVA_HOME to a JDK 17 or later" >&2
		exit 1
	fi
done
export JAVA_HOME
major=$(sed -n 's/^JAVA_VERSION="\([0-9]*\).*/\1/p' "$JAVA_HOME/release")

if [ -z "$version" ]; then
	version=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$root/parley-parent/pom.xml" | head -1)
fi
version=${version%-SNAPSHOT}
full=$version${label:+-$label}
deb_version=$version${label:+~$label}
rpm_release=${label:+0.$label}
rpm_release=${rpm_release:-1}
echo "package.sh: $platform $arch, JDK $major, version $full: ${apps[*]} ($types)"

mkdir -p "$out"
out=$(cd "$out" && pwd)
work="$build/target/packaging"
rm -rf "$work"
mkdir -p "$work"

sum() { # FILE in $out: write FILE.sha256 (sha256sum's format)
	(cd "$out" && if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi > "$1.sha256")
	echo "  $out/$1"
}

mvn_cmd=mvn
[ $platform = windows ] && command -v mvn.cmd > /dev/null 2>&1 && mvn_cmd=mvn.cmd

# ---------------------------------------------------------------- staging

# The application's jars in $1/lib: the module's own jar and what it needs at run time
stage_jars() { # DIR
	local dir=$1 mod=$root/$MODULE jar
	mkdir -p "$dir/lib"
	# shellcheck disable=SC2010
	jar=$(ls "$mod"/target/"$(basename "$MODULE")"-*.jar 2>/dev/null \
		| grep -v -e '-sources\.jar' -e '-javadoc\.jar' -e '-tests\.jar' -e '-all\.jar' -e '-plugin\.jar' | head -1 || true)
	if [ -z "$jar" ]; then
		echo "package.sh: no jar in $mod/target: build all of Parley first (mvn install in parley-build)" >&2
		exit 1
	fi
	cp "$jar" "$dir/lib/"
	local lib=$dir/lib
	[ $platform = windows ] && lib=$(cygpath -w "$lib")
	(cd "$mod" && "$mvn_cmd" -B -q dependency:copy-dependencies -DincludeScope=runtime \
		-DoutputDirectory="$lib" -Dmdep.useBaseVersion=true < /dev/null)
	MAIN_JAR=$(basename "$jar")
}

# The class path launchers use: every jar in lib (a wildcard, so lib can change)
# Launchers for Java on PATH (or JAVA_HOME), or, with a runtime folder beside lib, for that Java.
write_launchers() { # DIR
	local dir=$1 l cmd main
	mkdir -p "$dir/bin"
	for l in $LAUNCHERS; do
		cmd=${l%%=*}
		main=${l#*=}
		cat > "$dir/bin/$cmd" <<SH
#!/bin/sh
# $cmd ($TITLE $full). Keep this folder together; link this file from a directory on PATH.
# Java: the runtime beside lib when there is one, else JAVA_HOME's, else the java on PATH (17 or
# later). JAVA_OPTS adds options for Java.
self=\$0
while [ -L "\$self" ]; do
	link=\$(readlink "\$self")
	case \$link in
	/*) self=\$link ;;
	*) self=\$(dirname "\$self")/\$link ;;
	esac
done
home=\$(cd "\$(dirname "\$self")/.." && pwd)
if [ -x "\$home/runtime/bin/java" ]; then
	java=\$home/runtime/bin/java
elif [ -n "\$JAVA_HOME" ]; then
	java=\$JAVA_HOME/bin/java
else
	java=java
fi
exec "\$java" $JAVA_OPTIONS \$JAVA_OPTS -cp "\$home/lib/*" $main "\$@"
SH
		chmod 755 "$dir/bin/$cmd"
		# (Windows: the same, for cmd.exe; javaw for a window application, so no console stays open)
		local javaexe=java.exe
		[ "$KIND" = gui ] && javaexe=javaw.exe
		printf '%s\r\n' "@echo off" \
			"rem $cmd ($TITLE $full). Keep this folder together." \
			"rem Java: the runtime beside lib when there is one, else JAVA_HOME's, else the java on PATH (17 or later)." \
			"setlocal" \
			"set HOME_DIR=%~dp0.." \
			"set JAVA=$javaexe" \
			"if defined JAVA_HOME set JAVA=%JAVA_HOME%\\bin\\$javaexe" \
			"if exist \"%HOME_DIR%\\runtime\\bin\\$javaexe\" set JAVA=%HOME_DIR%\\runtime\\bin\\$javaexe" \
			"$([ "$KIND" = gui ] && echo 'start "" ')\"%JAVA%\" $JAVA_OPTIONS %JAVA_OPTS% -cp \"%HOME_DIR%\\lib\\*\" $main %*" \
			> "$dir/bin/$cmd.cmd"
	done
}

write_readme() { # DIR how
	local dir=$1 how=$2 l
	{
		echo "$TITLE $full"
		echo
		echo "$DESCRIPTION."
		echo
		echo "$how"
		echo
		echo "Commands:"
		for l in $LAUNCHERS; do
			echo "  ${l%%=*}"
		done
		if [ "${FSH_PLUGIN:-}" = yes ]; then
			echo
			echo "It is also fsh's file browser: put lib/$MAIN_JAR in one of fsh's plugin folders"
			echo "(~/.parley/fsh/plugins, or /usr/local/lib/parley/fsh/plugins for everyone) and fsh has"
			echo "browse, view, edit and search."
		fi
		echo
		echo "Source and documentation: https://github.com/parley-project"
	} > "$dir/README.txt"
	[ -f "$root/$MODULE/LICENSE" ] && cp "$root/$MODULE/LICENSE" "$dir/" || cp "$build/LICENSE" "$dir/"
}

# A Java runtime with the modules Parley's applications use: all of Java SE, plus what is found
# only at run time (elliptic curves for SSH, more encodings, every locale, zip file systems, DNS
# through JNDI, sun.misc for JNA and the terminal libraries)
make_runtime() { # DIR
	local available modules=java.se m
	available=$("$JAVA_HOME/bin/java$exe" --list-modules | sed 's/@.*//')
	for m in jdk.crypto.ec jdk.charsets jdk.localedata jdk.zipfs jdk.naming.dns jdk.unsupported jdk.management jdk.crypto.cryptoki; do
		if echo "$available" | grep -qx "$m"; then
			modules="$modules,$m"
		fi
	done
	local compress=zip-6
	[ "$major" -lt 21 ] && compress=2
	"$JAVA_HOME/bin/jlink$exe" --add-modules "$modules" --output "$1" \
		--strip-debug --no-header-files --no-man-pages --compress=$compress --generate-cds-archive
}

archive() { # STAGE-PARENT NAME: NAME.tar.gz and NAME.zip from the folder NAME
	local parent=$1 name=$2
	(cd "$parent" && tar -czf "$out/$name.tar.gz" "$name")
	sum "$name.tar.gz"
	if command -v zip > /dev/null 2>&1; then
		(cd "$parent" && zip -qr "$out/$name.zip" "$name")
	else
		# (Windows: its own tar makes zips with / in the paths, which every unzip reads)
		(cd "$parent" && /c/Windows/System32/tar.exe -a -cf "$(cygpath -w "$out/$name.zip")" "$name")
	fi
	sum "$name.zip"
}

# ---------------------------------------------------------------- plain

package_plain() {
	local name=$NAME-$full
	if [ "$PLATFORM_JARS" = yes ]; then
		name=$name-$platform-$arch
	elif [ "$platform" != linux ] || [ "$arch" != x86_64 ]; then
		echo "  (plain: the same on every platform, made on Linux x86-64)"
		return
	fi
	local dir=$work/plain/$name
	stage_jars "$dir"
	write_launchers "$dir"
	write_readme "$dir" "Needs Java 17 or later (java on PATH, or JAVA_HOME). Run bin/COMMAND (bin\\COMMAND.cmd on Windows)."
	archive "$work/plain" "$name"
}

# ---------------------------------------------------------------- installers

# The folder an installer puts on the disk: bin (the launchers), lib, runtime
image_dir() { # DIR
	local dir=$1
	stage_jars "$dir"
	write_launchers "$dir"
	write_readme "$dir" "It carries its own Java runtime (runtime): nothing else needs to be installed."
	rm -f "$dir"/bin/*.cmd
	make_runtime "$dir/runtime"
}

icon_png() { # SIZE: the brand's icon at that size, or empty
	local f="$root/parley-brand/src/main/resources/us/bringardner/parley/brand/$ICON-$1.png"
	[ -f "$f" ] && echo "$f" || true
}

linux_packages() {
	local base=$work/linux root_dir l cmd
	root_dir=$base/root
	local opt=/opt/parley/$NAME
	image_dir "$root_dir$opt"
	mkdir -p "$root_dir/usr/bin"
	for l in $LAUNCHERS; do
		cmd=${l%%=*}
		ln -s "$opt/bin/$cmd" "$root_dir/usr/bin/$cmd"
	done
	if [ "$KIND" = gui ]; then
		local png
		png=$(icon_png 128)
		mkdir -p "$root_dir/usr/share/applications"
		[ -n "$png" ] && mkdir -p "$root_dir/usr/share/icons/hicolor/128x128/apps" \
			&& cp "$png" "$root_dir/usr/share/icons/hicolor/128x128/apps/$NAME.png"
		for l in $LAUNCHERS; do
			cmd=${l%%=*}
			local title=$TITLE
			case $cmd in *-fx) title="$TITLE (JavaFX)" ;; esac
			cat > "$root_dir/usr/share/applications/$cmd.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$title
Comment=$DESCRIPTION
Exec=$opt/bin/$cmd %F
Icon=$NAME
Terminal=false
Categories=Utility;Development;
DESKTOP
		done
	fi
	if [ "${FSH_PLUGIN:-}" = yes ]; then
		# fsh's system plugin folder (see fsh's README): browse, view, edit and search
		mkdir -p "$root_dir/usr/local/lib/parley/fsh/plugins"
		ln -s "$opt/lib/$MAIN_JAR" "$root_dir/usr/local/lib/parley/fsh/plugins/$NAME.jar"
	fi
	chmod -R u=rwX,go=rX "$root_dir$opt"

	if command -v dpkg-deb > /dev/null 2>&1; then
		local deb=$base/deb
		cp -a "$root_dir" "$deb"
		mkdir -p "$deb/DEBIAN"
		cat > "$deb/DEBIAN/control" <<CTL
Package: $NAME
Version: $deb_version
Architecture: $deb_arch
Maintainer: Tony Bringardner <tony.bringardner@gmail.com>
Section: utils
Priority: optional
Installed-Size: $(du -sk "$root_dir" | cut -f1)
Homepage: https://github.com/parley-project
Description: $TITLE
 $DESCRIPTION. It carries its own Java runtime.
CTL
		# (the file named with the version, without the ~ only the package's version needs)
		local name=${NAME}_${full}_$deb_arch.deb
		dpkg-deb --root-owner-group --build "$deb" "$out/$name" > /dev/null
		sum "$name"
	else
		echo "  (no dpkg-deb: no .deb)"
	fi

	if command -v rpmbuild > /dev/null 2>&1; then
		local rpm=$base/rpm files
		mkdir -p "$rpm/SPECS" "$rpm/RPMS"
		files=$(cd "$root_dir" && find . -mindepth 1 \( -type f -o -type l \) | sed 's:^\.::' | grep -v "^$opt/" || true)
		cat > "$rpm/SPECS/$NAME.spec" <<SPEC
Name: $NAME
Version: $version
Release: $rpm_release
Summary: $TITLE
License: Apache-2.0
URL: https://github.com/parley-project
Packager: Tony Bringardner <tony.bringardner@gmail.com>
AutoReqProv: no

%description
$DESCRIPTION. It carries its own Java runtime.

%install
mkdir -p %{buildroot}
cp -a $root_dir/. %{buildroot}/

%files
%defattr(-,root,root,-)
$opt
$files
SPEC
		rpmbuild --quiet -bb --target "$(uname -m)" \
			--define "_topdir $rpm" --define "_build_id_links none" \
			--define "debug_package %{nil}" --define "__os_install_post %{nil}" \
			"$rpm/SPECS/$NAME.spec"
		local built
		built=$(ls "$rpm"/RPMS/*/*.rpm)
		local name
		name=$(basename "$built")
		mv "$built" "$out/$name"
		sum "$name"
	else
		echo "  (no rpmbuild: no .rpm)"
	fi
}

# jpackage's options shared by macOS and Windows: the app's jars, its runtime and its launchers
jpackage_common() { # INPUT RUNTIME: prints nothing, sets JP
	local input=$1 runtime=$2 first=yes l cmd main o
	JP=(--dest "$work/jpackage-out" --temp "$work/jpackage-temp" --name "$NAME" --app-version "$version"
		--vendor "Tony Bringardner" --copyright "Copyright $(date +%Y) Tony Bringardner"
		--description "$DESCRIPTION" --input "$input" --main-jar "$MAIN_JAR" --runtime-image "$runtime")
	for o in $JAVA_OPTIONS; do
		JP+=(--java-options "$o")
	done
	for l in $LAUNCHERS; do
		cmd=${l%%=*}
		main=${l#*=}
		if [ $first = yes ]; then
			JP+=(--main-class "$main")
			first=no
		else
			# (another launcher in the same application: its own main class)
			printf 'main-class=%s\n' "$main" > "$work/$cmd.properties"
			[ "$KIND" = cli ] && printf 'win-console=true\n' >> "$work/$cmd.properties"
			JP+=(--add-launcher "$cmd=$work/$cmd.properties")
		fi
	done
}

macos_installer() {
	local app=$work/mac
	image_dir "$app"
	if [ "$KIND" = gui ]; then
		local png icns=""
		png=$(icon_png 512)
		if [ -n "$png" ]; then
			# (an .icns from the brand's PNG)
			mkdir -p "$work/icon.iconset"
			for s in 16 32 128 256 512; do
				sips -z $s $s "$png" --out "$work/icon.iconset/icon_${s}x${s}.png" > /dev/null
			done
			iconutil -c icns "$work/icon.iconset" -o "$work/$NAME.icns" && icns="$work/$NAME.icns"
		fi
		jpackage_common "$app/lib" "$app/runtime"
		JP+=(--type dmg --mac-package-identifier "us.bringardner.parley.$NAME" --mac-package-name "${MAC_NAME:-$TITLE}")
		[ -n "$icns" ] && JP+=(--icon "$icns")
		[ -f "$app/LICENSE" ] && JP+=(--license-file "$app/LICENSE")
		# (hdiutil on a hosted runner sometimes fails with "Resource busy": once more)
		"$JAVA_HOME/bin/jpackage" "${JP[@]}" || { sleep 10; rm -rf "$work/jpackage-out" "$work/jpackage-temp"; "$JAVA_HOME/bin/jpackage" "${JP[@]}"; }
		local name=$NAME-$full-macos-$arch.dmg
		mv "$work"/jpackage-out/*.dmg "$out/$name"
		sum "$name"
	else
		# A terminal program: a .pkg that installs /usr/local/lib/parley/NAME, with its commands
		# linked from /usr/local/bin
		local pkgroot=$work/pkgroot scripts=$work/pkg-scripts l cmd
		mkdir -p "$pkgroot/$NAME" "$scripts"
		cp -a "$app"/. "$pkgroot/$NAME/"
		{
			echo '#!/bin/sh'
			echo 'mkdir -p /usr/local/bin'
			for l in $LAUNCHERS; do
				cmd=${l%%=*}
				echo "ln -sf /usr/local/lib/parley/$NAME/bin/$cmd /usr/local/bin/$cmd"
			done
			if [ "${FSH_PLUGIN:-}" = yes ]; then
				echo 'mkdir -p /usr/local/lib/parley/fsh/plugins'
				echo "ln -sf /usr/local/lib/parley/$NAME/lib/$MAIN_JAR /usr/local/lib/parley/fsh/plugins/$NAME.jar"
			fi
			echo 'exit 0'
		} > "$scripts/postinstall"
		chmod 755 "$scripts/postinstall"
		local name=$NAME-$full-macos-$arch.pkg
		pkgbuild --root "$pkgroot" --install-location /usr/local/lib/parley --scripts "$scripts" \
			--identifier "us.bringardner.parley.$NAME" --version "$version" "$out/$name" > /dev/null
		sum "$name"
	fi
}

windows_installer() {
	local app=$work/win
	image_dir "$app"
	jpackage_common "$app/lib" "$app/runtime"
	JP+=(--type msi --win-dir-chooser --win-menu --win-menu-group Parley --win-upgrade-uuid "$UPGRADE_UUID")
	if [ "$KIND" = gui ]; then
		JP+=(--win-shortcut)
	else
		JP+=(--win-console)
	fi
	[ -f "$app/LICENSE" ] && JP+=(--license-file "$app/LICENSE")
	# (jpackage takes Windows paths)
	local i
	for i in "${!JP[@]}"; do
		case ${JP[$i]} in
		/*) JP[$i]=$(cygpath -w "${JP[$i]}") ;;
		*=/*) JP[$i]="${JP[$i]%%=*}=$(cygpath -w "${JP[$i]#*=}")" ;;
		esac
	done
	"$JAVA_HOME/bin/jpackage.exe" "${JP[@]}"
	local name=$NAME-$full-windows-$arch.msi
	mv "$work"/jpackage-out/*.msi "$out/$name"
	sum "$name"
}

# fsh's own installers (its tools/), with its keyboard library and fshexec, named with the label
package_fsh_installers() {
	local fsh=$root/fsh f n
	for f in tools/build-jlink.sh tools/build-linux-packages.sh tools/build-jpackage.sh tools/build-msi.ps1; do
		if [ ! -f "$fsh/$f" ]; then
			echo "package.sh: fsh has no $f (its installers are on its branch installers until that is merged)" >&2
			exit 1
		fi
	done
	rm -rf "$fsh/dist"
	case $platform in
	linux)
		(cd "$fsh" && sh linux/compile.sh && sh tools/build-jlink.sh --package "$full" && sh tools/build-linux-packages.sh all "$deb_version") ;;
	macos)
		# (hdiutil on a hosted runner sometimes fails with "Resource busy": once more)
		(cd "$fsh" && sh macos/compile.sh && sh tools/build-jlink.sh --package "$full" \
			&& { sh tools/build-jpackage.sh dmg "$version" || { sleep 10; sh tools/build-jpackage.sh dmg "$version"; }; }) ;;
	windows)
		(cd "$fsh" && cmd //c 'windows\compile.cmd' && pwsh -NoProfile -ExecutionPolicy Bypass -File tools/build-msi.ps1 -Version "$version" -Arch "$arch") ;;
	esac
	for f in "$fsh"/dist/*; do
		case $f in *.sha256) continue ;; esac
		n=$(basename "$f")
		# (the disk image and the .msi are named with the plain version, jpackage's; the Linux
		# packages with the ~ only the packages' versions need)
		case $n in
		fsh-"$version"-macos-*|fsh-"$version"-windows-*) n=fsh-$full-${n#fsh-"$version"-} ;;
		esac
		n=${n//\~/-}
		mv "$f" "$out/$n"
		sum "$n"
	done
	rm -rf "$fsh/dist"
}

package_installer() {
	if [ "${INSTALLER:-}" = fsh-tools ]; then
		package_fsh_installers
		return
	fi
	case $platform in
	linux) linux_packages ;;
	macos) macos_installer ;;
	windows) windows_installer ;;
	esac
}

# ---------------------------------------------------------------- the servers

# The servers' jars in DIR/lib (each server module's, EXTRA_MODULES', and what they need), and
# SERVERS_FOUND: the servers whose main class has a main method (a server without one is left out)
stage_servers() { # DIR
	local dir=$1 n mod main prop m keep_module=$MODULE
	SERVERS_FOUND=""
	for m in $EXTRA_MODULES; do
		MODULE=$m
		stage_jars "$dir"
	done
	while IFS=: read -r n mod main prop; do
		[ -n "$n" ] || continue
		MODULE=$mod
		stage_jars "$dir"
		if "$JAVA_HOME/bin/javap$exe" -cp "$dir/lib/$MAIN_JAR" "$main" 2>/dev/null | grep -q 'public static void main(java.lang.String\[\])'; then
			SERVERS_FOUND="$SERVERS_FOUND $n"
		else
			echo "  (left out: $main has no main method in this build)"
		fi
	done <<< "$SERVERS"
	MODULE=$keep_module
}

# bin/parley-NAME for each server: its settings file is CONF/parley-NAME.properties, CONF being
# /etc/parley, or the folder of the file PARLEY_CONF names (as Parley's plugin folders)
write_server_launchers() { # DIR
	local dir=$1 n mod main prop
	mkdir -p "$dir/bin"
	while IFS=: read -r n mod main prop; do
		case " $SERVERS_FOUND " in *" $n "*) ;; *) continue ;; esac
		cat > "$dir/bin/parley-$n" <<SH
#!/bin/sh
# The Parley $n server ($full), run until it is stopped (systemd: parley-$n.service).
# Its settings: /etc/parley/parley-$n.properties (or beside the file PARLEY_CONF names), and
# -Dname=value arguments. Java: the runtime beside lib, else JAVA_HOME's, else the java on PATH.
self=\$0
while [ -L "\$self" ]; do
	link=\$(readlink "\$self")
	case \$link in
	/*) self=\$link ;;
	*) self=\$(dirname "\$self")/\$link ;;
	esac
done
home=\$(cd "\$(dirname "\$self")/.." && pwd)
if [ -x "\$home/runtime/bin/java" ]; then
	java=\$home/runtime/bin/java
elif [ -n "\$JAVA_HOME" ]; then
	java=\$JAVA_HOME/bin/java
else
	java=java
fi
conf=/etc/parley
[ -n "\$PARLEY_CONF" ] && conf=\$(dirname "\$PARLEY_CONF")
settings=""
[ -f "\$conf/parley-$n.properties" ] && settings="-D$prop=\$conf/parley-$n.properties"
exec "\$java" $JAVA_OPTIONS \$JAVA_OPTS \$settings -cp "\$home/lib/*" $main "\$@"
SH
		chmod 755 "$dir/bin/parley-$n"
	done <<< "$SERVERS"
}

# CONF-relative settings files and systemd units, for the servers found
write_server_files() { # ETC-PARLEY-DIR UNIT-DIR
	local etc=$1 units=$2 n mod main prop title
	mkdir -p "$etc" "$units"
	while IFS=: read -r n mod main prop; do
		case " $SERVERS_FOUND " in *" $n "*) ;; *) continue ;; esac
		cp "$here/servers/parley-$n.properties" "$etc/"
		title=$(echo "$n" | tr '[:lower:]' '[:upper:]')
		sed -e "s/@NAME@/$n/g" -e "s/@TITLE@/$title/g" -e "s/@MODULE@/$mod/g" \
			"$here/servers/parley-servers.service.in" > "$units/parley-$n.service"
	done <<< "$SERVERS"
}

servers_readme() { # DIR how
	{
		echo "$TITLE $full"
		echo
		echo "$DESCRIPTION."
		echo
		echo "$2"
		echo
		echo "Servers: bin/parley-NAME, with its settings in /etc/parley/parley-NAME.properties:"
		for n in $SERVERS_FOUND; do
			echo "  parley-$n"
		done
		echo
		echo "Every server runs as the account that starts it (the packages' services: parley)."
		echo "Source and documentation: https://github.com/parley-project"
	} > "$1/README.txt"
	cp "$build/LICENSE" "$1/"
}

package_servers_plain() {
	if [ "$platform" != linux ] || [ "$arch" != x86_64 ]; then
		echo "  (plain: the same on every platform, made on Linux x86-64)"
		return
	fi
	local name=$NAME-$full dir
	dir=$work/plain/$name
	stage_servers "$dir"
	write_server_launchers "$dir"
	write_server_files "$dir/etc/parley" "$dir/systemd"
	servers_readme "$dir" "Needs Java 17 or later (java on PATH, or JAVA_HOME). etc/parley has the settings files and systemd the service units, both for /opt/parley/servers; the Linux packages install them."
	archive "$work/plain" "$name"
}

linux_servers() {
	local base=$work/linux root_dir opt=/opt/parley/servers
	root_dir=$base/root
	stage_servers "$root_dir$opt"
	write_server_launchers "$root_dir$opt"
	servers_readme "$root_dir$opt" "It carries its own Java runtime (runtime): nothing else needs to be installed."
	make_runtime "$root_dir$opt/runtime"
	write_server_files "$root_dir/etc/parley" "$root_dir/usr/lib/systemd/system"
	chmod -R u=rwX,go=rX "$root_dir$opt"
	local n units="" confs=""
	for n in $SERVERS_FOUND; do
		units="$units parley-$n.service"
		confs="$confs /etc/parley/parley-$n.properties"
	done
	# (the account the services run as, and the folders the settings files name, owned by it)
	local setup='getent group parley > /dev/null || groupadd --system parley
getent passwd parley > /dev/null || useradd --system --gid parley --home-dir /var/lib/parley --shell /usr/sbin/nologin --comment "Parley servers" parley
for d in /var/lib/parley /var/lib/parley/mail /var/lib/parley/ftp /etc/parley/dns /etc/parley/dns/zones /etc/parley/ssh; do
	mkdir -p "$d"
	chown parley:parley "$d"
done
chmod 700 /etc/parley/ssh
if [ -d /run/systemd/system ]; then systemctl daemon-reload || true; fi'
	local reload='if [ -d /run/systemd/system ]; then systemctl daemon-reload || true; fi'

	if command -v dpkg-deb > /dev/null 2>&1; then
		local deb=$base/deb c
		cp -a "$root_dir" "$deb"
		mkdir -p "$deb/DEBIAN"
		cat > "$deb/DEBIAN/control" <<CTL
Package: $NAME
Version: $deb_version
Architecture: $deb_arch
Maintainer: Tony Bringardner <tony.bringardner@gmail.com>
Section: net
Priority: optional
Installed-Size: $(du -sk "$root_dir" | cut -f1)
Depends: passwd
Homepage: https://github.com/parley-project
Description: $TITLE
 $DESCRIPTION. It carries its own Java runtime. The services are installed but not enabled
 or started: choose them with systemctl enable --now parley-NAME.
CTL
		for c in $confs; do
			echo "$c" >> "$deb/DEBIAN/conffiles"
		done
		printf '#!/bin/sh\nset -e\nif [ "$1" = configure ]; then\n%s\nfi\n' "$setup" > "$deb/DEBIAN/postinst"
		# (stopping the services before the files go)
		printf '#!/bin/sh\nset -e\nif [ -d /run/systemd/system ] && [ "$1" = remove ]; then\n\tsystemctl stop%s || true\nfi\n' "$units" > "$deb/DEBIAN/prerm"
		printf '#!/bin/sh\nset -e\n%s\n' "$reload" > "$deb/DEBIAN/postrm"
		chmod 755 "$deb/DEBIAN/postinst" "$deb/DEBIAN/prerm" "$deb/DEBIAN/postrm"
		local name=${NAME}_${full}_$deb_arch.deb
		dpkg-deb --root-owner-group --build "$deb" "$out/$name" > /dev/null
		sum "$name"
	else
		echo "  (no dpkg-deb: no .deb)"
	fi

	if command -v rpmbuild > /dev/null 2>&1; then
		local rpm=$base/rpm u c
		mkdir -p "$rpm/SPECS" "$rpm/RPMS"
		{
			cat <<SPEC
Name: $NAME
Version: $version
Release: $rpm_release
Summary: $TITLE
License: Apache-2.0
URL: https://github.com/parley-project
Packager: Tony Bringardner <tony.bringardner@gmail.com>
AutoReqProv: no
Requires(pre): shadow-utils

%description
$DESCRIPTION. It carries its own Java runtime. The services are installed but not enabled
or started: choose them with systemctl enable --now parley-NAME.

%install
mkdir -p %{buildroot}
cp -a $root_dir/. %{buildroot}/

%post
$setup

%preun
if [ "\$1" = 0 ] && [ -d /run/systemd/system ]; then
	systemctl stop$units || true
fi

%postun
$reload

%files
%defattr(-,root,root,-)
$opt
SPEC
			for u in $units; do
				echo "/usr/lib/systemd/system/$u"
			done
			for c in $confs; do
				echo "%config(noreplace) $c"
			done
		} > "$rpm/SPECS/$NAME.spec"
		rpmbuild --quiet -bb --target "$(uname -m)" \
			--define "_topdir $rpm" --define "_build_id_links none" \
			--define "debug_package %{nil}" --define "__os_install_post %{nil}" \
			"$rpm/SPECS/$NAME.spec"
		local built name
		built=$(ls "$rpm"/RPMS/*/*.rpm)
		name=$(basename "$built")
		mv "$built" "$out/$name"
		sum "$name"
	else
		echo "  (no rpmbuild: no .rpm)"
	fi
}

# ---------------------------------------------------------------- each application

for app in "${apps[@]}"; do
	conf=$here/apps/$app.conf
	if [ ! -f "$conf" ]; then
		echo "package.sh: no application $app (packaging/apps/$app.conf)" >&2
		exit 2
	fi
	NAME="" TITLE="" DESCRIPTION="" MODULE="" KIND="" LAUNCHERS="" PLATFORM_JARS=no ICON=parley-icon
	JAVA_OPTIONS="" FSH_PLUGIN="" UPGRADE_UUID="" MAC_NAME="" SERVERS="" EXTRA_MODULES="" INSTALLER=""
	# shellcheck source=/dev/null
	. "$conf"
	echo "== $NAME"
	for t in $types; do
		rm -rf "${work:?}"/*
		case $KIND:$t in
		servers:plain) package_servers_plain ;;
		servers:installer)
			if [ $platform = linux ]; then
				linux_servers
			else
				echo "  (installer: the servers are packaged for Linux only)"
			fi ;;
		*:plain) package_plain ;;
		*:installer) package_installer ;;
		*) echo "package.sh: unknown type $t" >&2; exit 2 ;;
		esac
	done
done
rm -rf "$work"
