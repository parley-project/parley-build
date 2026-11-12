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
# is packaged by its own scripts (tools/ in fsh), with fshdb: commands only, on macOS a .pkg
# (/usr/local/lib/parley/fsh, commands in /usr/local/bin). The servers (parley-servers) are a Linux
# package (.deb, .rpm: /opt/parley/servers, a systemd service for each, not enabled, settings in
# /etc/parley, run as the account parley), a macOS package (.pkg: /usr/local/lib/parley/servers,
# a launchd daemon for each, not started) and one plain archive; the mail servers are one service,
# parley-mail. parley-mail-admin (a war) is a Linux package (.deb, .rpm) that deploys it in the
# system's Tomcat 10.1, and one plain archive with a script that deploys it in any Tomcat.
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
for tool in java jlink jpackage jdeps jar; do
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
	# MODULE@CLASSIFIER: only the module's jar with that classifier (parley-mail-admin@server: the
	# server side of a web application), whose dependencies are other modules staged beside it
	local dir=$1 module=${MODULE%@*} classifier="" mod jar
	[ "$module" != "$MODULE" ] && classifier=${MODULE#*@}
	mod=$root/$module
	mkdir -p "$dir/lib"
	if [ -n "$classifier" ]; then
		jar=$(ls "$mod"/target/"$(basename "$module")"-*"$classifier".jar 2>/dev/null | head -1 || true)
		if [ -z "$jar" ]; then
			echo "package.sh: no $classifier jar in $mod/target: build all of Parley first (mvn install in parley-build)" >&2
			exit 1
		fi
		cp "$jar" "$dir/lib/"
		return
	fi
	# shellcheck disable=SC2010
	jar=$(ls "$mod"/target/"$(basename "$module")"-*.jar 2>/dev/null \
		| grep -v -e '-sources\.jar' -e '-javadoc\.jar' -e '-tests\.jar' -e '-all\.jar' -e '-plugin\.jar' -e '-server\.jar' | head -1 || true)
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

# An application's jars: its module's (MAIN_JAR), and EXTRA_MODULES' with what they need (for an
# application whose module is a library: pssh's parley-logging, its System.Logger)
stage_app_jars() { # DIR
	local keep_module=$MODULE keep_main m
	stage_jars "$1"
	keep_main=$MAIN_JAR
	for m in $EXTRA_MODULES; do
		MODULE=$m
		stage_jars "$1"
	done
	MODULE=$keep_module
	MAIN_JAR=$keep_main
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

# A Java runtime with the modules Parley's applications use: what the jars in the lib folder beside
# DIR use (jdeps), plus what is found only at run time (elliptic curves for SSH, more encodings,
# every locale, zip file systems, DNS through JNDI, sun.misc for JNA and the terminal libraries, the
# JMX agent for the servers' remote management: com.sun.management.jmxremote). PARLEY_RUNTIME_MODULES
# replaces what jdeps finds (java.se: all of Java SE, for plugins that need more than the jars here).
# The CDS archive for heaps over 32 GB (classes_nocoops.jsa, 14 MB) is left out, as in fsh's.
make_runtime() { # DIR
	local available modules m
	modules=${PARLEY_RUNTIME_MODULES:-$(runtime_modules "$(dirname "$1")/lib")}
	echo "  runtime modules: $modules"
	available=$("$JAVA_HOME/bin/java$exe" --list-modules | sed 's/@.*//')
	for m in jdk.crypto.ec jdk.charsets jdk.localedata jdk.zipfs jdk.naming.dns jdk.unsupported jdk.management jdk.management.agent jdk.crypto.cryptoki; do
		if echo "$available" | grep -qx "$m"; then
			modules="$modules,$m"
		fi
	done
	local compress=zip-6
	[ "$major" -lt 21 ] && compress=2
	"$JAVA_HOME/bin/jlink$exe" --add-modules "$modules" --output "$1" \
		--strip-debug --no-header-files --no-man-pages --compress=$compress --generate-cds-archive
	rm -f "$1/lib/server/classes_nocoops.jsa" "$1/bin/server/classes_nocoops.jsa"
}

# The Java modules the jars in LIB use, comma-separated (java.base at least). jdeps reads them
# unpacked and without module-info: a modular jar that requires a module the JDK doesn't have
# (commons-dbcp2 requires java.transaction) would stop it
runtime_modules() { # LIB
	local classes=$work/jdeps-classes lib f d found
	lib=$(cd "$1" && pwd)
	rm -rf "$classes"
	mkdir -p "$classes"
	for f in "$lib"/*.jar; do
		[ -f "$f" ] || continue
		d=$classes/$(basename "$f" .jar)
		mkdir -p "$d"
		(cd "$d" && "$JAVA_HOME/bin/jar$exe" xf "$f")
		find "$d" -name module-info.class -exec rm -f {} +
	done
	found=$(ls "$classes")
	if [ -n "$found" ]; then
		found=$("$JAVA_HOME/bin/jdeps$exe" -q --multi-release "$major" --ignore-missing-deps \
			--print-module-deps "$classes"/*) || { echo "jdeps failed on $lib" >&2; exit 1; }
	fi
	rm -rf "$classes"
	echo "${found:-java.base}"
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
	stage_app_jars "$dir"
	write_launchers "$dir"
	write_readme "$dir" "Needs Java 17 or later (java on PATH, or JAVA_HOME). Run bin/COMMAND (bin\\COMMAND.cmd on Windows)."
	archive "$work/plain" "$name"
}

# ---------------------------------------------------------------- installers

# The folder an installer puts on the disk: bin (the launchers), lib, runtime
image_dir() { # DIR
	local dir=$1
	stage_app_jars "$dir"
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

# fsh's own installers (its tools/), with its keyboard library and fshexec, named with the label.
# They install commands, not applications: fsh, and fshdb on the same Java runtime (fshdb's
# checkout beside fsh's; it builds against fsh-ide, which the build of all of Parley installed).
package_fsh_installers() {
	local fsh=$root/fsh fshdb=$root/fshdb f n
	for f in tools/build-jlink.sh tools/build-linux-packages.sh tools/build-macos-pkg.sh tools/build-msi.ps1; do
		if [ ! -f "$fsh/$f" ]; then
			echo "package.sh: fsh has no $f (its command-only installers are on its branch command-packages until that is merged)" >&2
			exit 1
		fi
	done
	if [ ! -f "$fshdb/pom.xml" ]; then
		echo "package.sh: no fshdb checkout at $fshdb (it is installed with fsh)" >&2
		exit 1
	fi
	rm -rf "$fsh/dist"
	case $platform in
	linux)
		(cd "$fsh" && sh linux/compile.sh && sh tools/build-jlink.sh --db "$fshdb" --package "$full" && sh tools/build-linux-packages.sh all "$deb_version") ;;
	macos)
		(cd "$fsh" && sh macos/compile.sh && sh tools/build-jlink.sh --db "$fshdb" --package "$full" && sh tools/build-macos-pkg.sh "$version") ;;
	windows)
		(cd "$fsh" && cmd //c 'windows\compile.cmd' && pwsh -NoProfile -ExecutionPolicy Bypass -File tools/build-msi.ps1 -Version "$version" -Arch "$arch" -DbRepo "$(cygpath -w "$fshdb")") ;;
	esac
	for f in "$fsh"/dist/*; do
		case $f in *.sha256) continue ;; esac
		n=$(basename "$f")
		# (the macOS package and the .msi are named with the plain version, the installers' own;
		# the Linux packages with the ~ only the packages' versions need)
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
		# (MODULE may be several, for a server process that runs several servers: parley-mail)
		for m in $mod; do
			MODULE=$m
			stage_jars "$dir"
		done
		local cp="$dir/lib/*"
		[ $platform = windows ] && cp="$(cygpath -w "$dir/lib")\\*"
		if "$JAVA_HOME/bin/javap$exe" -cp "$cp" "$main" 2>/dev/null | grep -q 'public static void main(java.lang.String\[\])'; then
			SERVERS_FOUND="$SERVERS_FOUND $n"
		else
			echo "  (left out: $main has no main method in this build)"
		fi
	done <<< "$SERVERS"
	MODULE=$keep_module
	mkdir -p "$dir/bin"
	cp "$here/servers/parley-servers-setup" "$here/servers/parley-health" "$dir/bin/"
	chmod 755 "$dir/bin/parley-servers-setup" "$dir/bin/parley-health"
	# (rspamd's settings, which parley-servers-setup puts in /etc/rspamd/local.d)
	mkdir -p "$dir/rspamd"
	cp -R "$here/servers/rspamd/local.d" "$dir/rspamd/"
}

# bin/parley-NAME for each server: its settings file is CONF/parley-NAME.properties, CONF being
# /etc/parley, or the folder of the file PARLEY_CONF names (as Parley's plugin folders), and its
# Java options CONF/parley-NAME.jvm when it is there (a java @argfile: JMX for parley-mail)
write_server_launchers() { # DIR
	local dir=$1 n mod main prop
	mkdir -p "$dir/bin"
	while IFS=: read -r n mod main prop; do
		case " $SERVERS_FOUND " in *" $n "*) ;; *) continue ;; esac
		cat > "$dir/bin/parley-$n" <<SH
#!/bin/sh
# The Parley $n server ($full), run until it is stopped (systemd: parley-$n.service).
# Its settings: /etc/parley/parley-$n.properties (or beside the file PARLEY_CONF names), and
# -Dname=value arguments; its Java options: parley-$n.jvm there, one per line, when it is there.
# Java: the runtime beside lib, else JAVA_HOME's, else the java on PATH.
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
options=""
[ -f "\$conf/parley-$n.jvm" ] && options="@\$conf/parley-$n.jvm"
exec "\$java" $JAVA_OPTIONS \$options \$JAVA_OPTS \$settings -cp "\$home/lib/*" $main "\$@"
SH
		chmod 755 "$dir/bin/parley-$n"
	done <<< "$SERVERS"
}

# The settings files for the servers found, in ETC-PARLEY-DIR: servers/parley-NAME.properties
# and the files in servers/NAME.d (the mail servers' protocol files, users, aliases, Java
# options), and SERVER_FILES: their names. Their service units: systemd in UNIT-DIR, and launchd
# in LAUNCHD-DIR when it is given.
write_server_files() { # ETC-PARLEY-DIR UNIT-DIR [LAUNCHD-DIR]
	local etc=$1 units=$2 launchd=${3:-} n mod main prop title f
	mkdir -p "$etc" "$units"
	if [ -n "$launchd" ]; then mkdir -p "$launchd"; fi
	SERVER_FILES=""
	while IFS=: read -r n mod main prop; do
		case " $SERVERS_FOUND " in *" $n "*) ;; *) continue ;; esac
		for f in "$here/servers/parley-$n.properties" "$here/servers/$n.d"/*; do
			[ -f "$f" ] || continue
			cp "$f" "$etc/"
			SERVER_FILES="$SERVER_FILES $(basename "$f")"
		done
		title=$(server_title "$n")
		sed -e "s/@NAME@/$n/g" -e "s/@TITLE@/$title/g" -e "s/@MODULE@/${mod%% *}/g" \
			"$here/servers/parley-servers.service.in" > "$units/parley-$n.service"
		if [ -n "$launchd" ]; then
			sed -e "s/@NAME@/$n/g" -e "s/@TITLE@/$title/g" \
				"$here/servers/parley-servers.plist.in" > "$launchd/us.bringardner.parley.$n.plist"
		fi
	done <<< "$SERVERS"
	# (the health check: bin/parley-health, its settings, and on systemd a timer that runs it)
	cp "$here/servers/parley-health.properties" "$etc/"
	SERVER_FILES="$SERVER_FILES parley-health.properties"
	cp "$here/servers/parley-health.service" "$here/servers/parley-health.timer" "$units/"
}

server_title() { # NAME: for the units' descriptions
	case $1 in
	mail) echo "mail servers (SMTP, submission, IMAP, POP3)" ;;
	*) echo "$(echo "$1" | tr '[:lower:]' '[:upper:]') server" ;;
	esac
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
		echo "parley-mail runs the mail servers (SMTP, submission, IMAP, POP3, and with a key store"
		echo "their implicit TLS servers) and FTP for the mail users in one process: parley-mail.properties"
		echo "first, then parley-smtp.properties, parley-imap.properties, parley-pop3.properties and"
		echo "parley-mail-ftp.properties. Its JMX (for"
		echo "parley-mail-admin) is set in parley-mail.jvm: 127.0.0.1:9010, with the password in jmx/."
		echo "bin/parley-health checks the servers, the disk, the queue and the certificate, and mails an"
		echo "alert when that changes (settings: parley-health.properties; on systemd, enable"
		echo "parley-health.timer to run it every 5 minutes)."
		echo "The mail servers need a hostname and the local domains, which have no default:"
		echo "bin/parley-servers-setup --hostname mail.example.com --domains example.com sets them in"
		echo "the queue's settings (DATA/mail/.smtp-queue/queue.properties) and parley-smtp.properties."
		echo
		echo "bin/parley-servers-setup makes the folders, copies etc/parley to the settings folder,"
		echo "makes the JMX passwords and (--units systemd or launchd) the services; --help says how."
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
	write_server_files "$dir/etc/parley" "$dir/systemd" "$dir/launchd"
	servers_readme "$dir" "Needs Java 17 or later (java on PATH, or JAVA_HOME). etc/parley has the settings files, systemd and launchd the service units; bin/parley-servers-setup puts them in place for this folder (sudo bin/parley-servers-setup --create-account --units systemd, or on macOS --units launchd)."
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
	local n f units="" confs=""
	for n in $SERVERS_FOUND; do
		units="$units parley-$n.service"
	done
	units="$units parley-health.timer parley-health.service"
	for f in $SERVER_FILES; do
		confs="$confs /etc/parley/$f"
	done
	# (the account the services run as, its folders, the mail servers' JMX passwords: see the script)
	local setup="$opt/bin/parley-servers-setup --create-account
if [ -d /run/systemd/system ]; then systemctl daemon-reload || true; fi"
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
Recommends: rspamd
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
Recommends: rspamd

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

# A macOS package: /usr/local/lib/parley/servers with its own Java runtime, and a postinstall
# that runs parley-servers-setup for launchd (the account: the user logged in at the console;
# settings /etc/parley, data /usr/local/var/parley, logs /usr/local/var/log/parley). The
# daemons are made in /Library/LaunchDaemons but not started.
macos_servers() {
	local pkgroot=$work/pkgroot scripts=$work/pkg-scripts opt=/usr/local/lib/parley/servers
	local dir=$pkgroot/servers
	stage_servers "$dir"
	write_server_launchers "$dir"
	write_server_files "$dir/etc/parley" "$dir/systemd" "$dir/launchd"
	rm -rf "$dir/systemd"
	servers_readme "$dir" "It carries its own Java runtime (runtime): nothing else needs to be installed. The installer ran bin/parley-servers-setup --units launchd: the settings are in /etc/parley, the daemons in /Library/LaunchDaemons (not started)."
	make_runtime "$dir/runtime"
	chmod -R u=rwX,go=rX "$dir"
	mkdir -p "$scripts"
	cat > "$scripts/postinstall" <<SH
#!/bin/sh
# (the installer runs this as root)
$opt/bin/parley-servers-setup --units launchd
exit 0
SH
	chmod 755 "$scripts/postinstall"
	local name=$NAME-$full-macos-$arch.pkg
	pkgbuild --root "$pkgroot" --install-location /usr/local/lib/parley --scripts "$scripts" \
		--identifier "us.bringardner.parley.$NAME" --version "$version" "$out/$name" > /dev/null
	sum "$name"
}

# ---------------------------------------------------------------- a web application (war)

# The war, the Tomcat context that deploys it, and bin/NAME-setup, which puts the context in a
# Tomcat (found, or --catalina-base) and lets it at the settings folder (servers/NAME-setup)
stage_war() { # DIR README-LINE
	local dir=$1 war=$root/$MODULE/target/$MODULE.war
	if [ ! -f "$war" ]; then
		echo "package.sh: no $war: build all of Parley first (mvn install in parley-build)" >&2
		exit 1
	fi
	mkdir -p "$dir/bin" "$dir/conf"
	cp "$war" "$dir/"
	# (NAME-setup fills in the war's path and the folders)
	cp "$here/servers/$NAME.xml.in" "$dir/conf/$NAME.xml"
	cp "$here/servers/$NAME-setup" "$dir/bin/"
	chmod 755 "$dir/bin/$NAME-setup"
	{
		echo "$TITLE $full"
		echo
		echo "$DESCRIPTION."
		echo
		echo "$2"
		echo
		echo "bin/$NAME-setup finds the Tomcat (10.1 or later: Debian's and Ubuntu's tomcat10, Fedora's"
		echo "and Amazon Linux's tomcat or tomcat10, Homebrew's tomcat@10, or --catalina-base DIR), puts"
		echo "conf/$NAME.xml in its conf/Catalina/localhost (the war, and the folders: settings"
		echo "/etc/parley, home /var/lib/parley/mail-admin), and lets a systemd Tomcat write to them and"
		echo "join the group parley. --help says how. The pages are then at http://localhost:8080/$NAME/."
		echo
		echo "Install parley-servers first: the admin manages its parley-mail service over JMX (the"
		echo "settings it makes tell the admin where). Without it the admin runs the mail servers itself."
		echo
		echo "Source and documentation: https://github.com/parley-project"
	} > "$dir/README.txt"
	[ -f "$root/$MODULE/LICENSE" ] && cp "$root/$MODULE/LICENSE" "$dir/" || cp "$build/LICENSE" "$dir/"
}

package_war_plain() {
	if [ "$platform" != linux ] || [ "$arch" != x86_64 ]; then
		echo "  (plain: the same on every platform, made on Linux x86-64)"
		return
	fi
	local name=$NAME-$full dir
	dir=$work/plain/$name
	stage_war "$dir" "Needs a Tomcat 10.1 or later (Java 17 or later). Put this folder where it is to stay, run sudo bin/$NAME-setup (it finds the Tomcat, or give it --catalina-base; it restarts a systemd Tomcat, restart any other yourself)."
	archive "$work/plain" "$name"
}

# A Linux package (no Java of its own: Tomcat's): the war in /usr/share/NAME, and a postinst
# that runs NAME-setup for the system's Tomcat; removing it takes the context away again
linux_war() {
	local base=$work/linux root_dir share=/usr/share/$NAME
	root_dir=$base/root
	stage_war "$root_dir$share" "Installed by the package: bin/$NAME-setup has put it in the system's Tomcat."
	chmod -R u=rwX,go=rX "$root_dir$share"
	local setup="$share/bin/$NAME-setup || echo \"$NAME: run $share/bin/$NAME-setup when Tomcat 10.1 is installed\""
	local unsetup="$share/bin/$NAME-setup --remove || true"

	if command -v dpkg-deb > /dev/null 2>&1; then
		local deb=$base/deb
		cp -a "$root_dir" "$deb"
		mkdir -p "$deb/DEBIAN"
		cat > "$deb/DEBIAN/control" <<CTL
Package: $NAME
Version: $deb_version
Architecture: all
Maintainer: Tony Bringardner <tony.bringardner@gmail.com>
Section: mail
Priority: optional
Installed-Size: $(du -sk "$root_dir" | cut -f1)
Depends: tomcat10
Recommends: parley-servers
Homepage: https://github.com/parley-project
Description: $TITLE
 $DESCRIPTION. It is deployed in the system's Tomcat (tomcat10) at /$NAME, and manages the
 parley-servers package's parley-mail service over JMX.
CTL
		printf '#!/bin/sh\nset -e\nif [ "$1" = configure ]; then\n%s\nfi\n' "$setup" > "$deb/DEBIAN/postinst"
		printf '#!/bin/sh\nset -e\nif [ "$1" = remove ]; then\n%s\nfi\n' "$unsetup" > "$deb/DEBIAN/prerm"
		chmod 755 "$deb/DEBIAN/postinst" "$deb/DEBIAN/prerm"
		local name=${NAME}_${full}_all.deb
		dpkg-deb --root-owner-group --build "$deb" "$out/$name" > /dev/null
		sum "$name"
	else
		echo "  (no dpkg-deb: no .deb)"
	fi

	if command -v rpmbuild > /dev/null 2>&1; then
		local rpm=$base/rpm
		mkdir -p "$rpm/SPECS" "$rpm/RPMS"
		cat > "$rpm/SPECS/$NAME.spec" <<SPEC
Name: $NAME
Version: $version
Release: $rpm_release
Summary: $TITLE
License: Apache-2.0
URL: https://github.com/parley-project
Packager: Tony Bringardner <tony.bringardner@gmail.com>
BuildArch: noarch
AutoReqProv: no
Requires: (tomcat10 or tomcat)
Recommends: parley-servers

%description
$DESCRIPTION. It is deployed in the system's Tomcat (tomcat10 or tomcat) at /$NAME, and manages
the parley-servers package's parley-mail service over JMX.

%install
mkdir -p %{buildroot}
cp -a $root_dir/. %{buildroot}/

%post
$setup

%preun
if [ "\$1" = 0 ]; then
	$unsetup
fi

%files
%defattr(-,root,root,-)
$share
SPEC
		rpmbuild --quiet -bb --target noarch \
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
	if [ -n "$MODULE" ] && [ ! -d "$root/$MODULE" ]; then
		echo "  (left out: no $MODULE beside parley-build; packaging/checkout.sh clones it when it can)"
		continue
	fi
	for t in $types; do
		rm -rf "${work:?}"/*
		case $KIND:$t in
		servers:plain) package_servers_plain ;;
		servers:installer)
			case $platform in
			linux) linux_servers ;;
			macos) macos_servers ;;
			*) echo "  (installer: the servers are packaged for Linux and macOS)" ;;
			esac ;;
		war:plain) package_war_plain ;;
		war:installer)
			if [ $platform = linux ]; then
				if [ "$arch" = x86_64 ]; then linux_war; else echo "  (installer: the war's packages are made on Linux x86-64)"; fi
			else
				echo "  (installer: the war is packaged for Linux; elsewhere, the plain archive's bin/$NAME-setup)"
			fi ;;
		*:plain) package_plain ;;
		*:installer) package_installer ;;
		*) echo "package.sh: unknown type $t" >&2; exit 2 ;;
		esac
	done
done
rm -rf "$work"
