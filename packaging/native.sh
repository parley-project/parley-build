#!/usr/bin/env bash
# The native (GraalVM) binaries, for this platform, from the build of all of Parley (mvn install
# in parley-build first, with GraalVM as JAVA_HOME):
#
#   fsh                   FSH-VERSION-PLATFORM-ARCH.tar.gz (.zip on Windows): fsh's build-native
#                         --builtin, with the terminal file browser (parley-files-viewer-tui) built
#                         in, packaged by fsh's tools/package-native
#   fsh-ide               NAME-VERSION-PLATFORM-ARCH-native.tar.gz (.zip on Windows): the module's -Pnative
#   parley-files-viewer   build, with the JDK libraries it loads and lib/fontconfig.bfc
#
# with a .sha256 beside each. Usage: packaging/native.sh [--version V] [--label L] [--out DIR] APP...
# (the options as packaging/package.sh's). Windows: run in a shell with the MSVC build tools set up
# (an "x64 Native Tools" prompt, or the msvc-dev-cmd action).

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
build=$(cd "$here/.." && pwd)
root=$(cd "$build/.." && pwd)

version=""
label=""
out="$build/dist"
apps=()
while [ $# -gt 0 ]; do
	case $1 in
	--version) version=${2#v}; shift ;;
	--label) label=$2; shift ;;
	--out) out=$2; shift ;;
	-*) echo "native.sh: unknown option $1" >&2; exit 2 ;;
	*) apps+=("$1") ;;
	esac
	shift
done
[ ${#apps[@]} -gt 0 ] || { echo "usage: packaging/native.sh [--version V] [--label L] [--out DIR] APP..." >&2; exit 2; }

case $(uname -s) in
Linux) platform=linux ;;
Darwin) platform=macos ;;
MINGW*|MSYS*|CYGWIN*) platform=windows ;;
*) echo "native.sh: unknown platform $(uname -s)" >&2; exit 1 ;;
esac
case $(uname -m) in
x86_64|amd64) arch=x86_64 ;;
arm64|aarch64) arch=aarch64 ;;
*) arch=$(uname -m) ;;
esac
if [ -z "$version" ]; then
	version=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$root/parley-parent/pom.xml" | head -1)
fi
version=${version%-SNAPSHOT}
full=$version${label:+-$label}
mkdir -p "$out"
out=$(cd "$out" && pwd)
mvn_cmd=mvn
[ $platform = windows ] && command -v mvn.cmd > /dev/null 2>&1 && mvn_cmd=mvn.cmd
echo "native.sh: $platform $arch, version $full: ${apps[*]}"

sum() { # FILE in $out
	(cd "$out" && if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi > "$1.sha256")
	echo "  $out/$1"
}

native_fsh() {
	local fsh=$root/fsh plugin
	# shellcheck disable=SC2010
	plugin=$(ls "$root"/parley-files-viewer-tui/parley-files-viewer-tui/target/parley-files-viewer-tui-*.jar \
		| grep -v -e '-all\.jar' -e '-sources\.jar' | head -1)
	[ -n "$plugin" ] || { echo "native.sh: no parley-files-viewer-tui jar: build all of Parley first" >&2; exit 1; }
	rm -rf "$fsh/dist"
	if [ $platform = windows ]; then
		(cd "$fsh" && cmd //c 'windows\compile.cmd' && FSH_PLUGINS=$(cygpath -w "$plugin") cmd //c 'windows\build-native.cmd --builtin')
		(cd "$fsh" && pwsh -NoProfile -ExecutionPolicy Bypass -File tools/package-native.ps1 -Arch "$arch" -Version "$full")
	else
		(cd "$fsh" && sh "$platform/compile.sh" && FSH_PLUGINS=$plugin sh "$platform/build-native.sh" --builtin)
		(cd "$fsh" && sh tools/package-native.sh "$platform" "$arch" "$full")
	fi
	local f
	for f in "$fsh"/dist/fsh-*; do
		case $f in *.sha256) continue ;; esac
		mv "$f" "$out/"
		sum "$(basename "$f")"
	done
}

# fsh-ide and the viewer: the module's native profile (target/NAME), the JDK libraries it loads and
# lib/fontconfig.bfc, kept together
native_module() { # NAME MODULE
	local name=$1 mod=$root/$2 stage dist
	(cd "$mod" && "$mvn_cmd" -B -q -Pnative -DskipTests package < /dev/null)
	# (-native: not the plain archive's name, which is made for the same platform)
	dist=$name-$full-$platform-$arch-native
	stage=$build/target/native/$dist
	rm -rf "$stage"
	mkdir -p "$stage/lib"
	if [ $platform = windows ]; then
		cp "$mod/target/$name.exe" "$mod"/target/*.dll "$stage/"
	else
		cp "$mod/target/$name" "$stage/"
		cp "$mod"/target/*.so "$mod"/target/*.dylib "$stage/" 2>/dev/null || true
	fi
	[ -f "$mod/target/lib/fontconfig.bfc" ] && cp "$mod/target/lib/fontconfig.bfc" "$stage/lib/"
	[ -f "$mod/LICENSE" ] && cp "$mod/LICENSE" "$stage/"
	printf 'Run %s. Keep the files in this folder together (the libraries and lib/fontconfig.bfc are loaded by it).\n' \
		"$name$([ $platform = windows ] && echo .exe)" > "$stage/README.txt"
	if [ $platform = macos ]; then
		printf '\nmacOS marks a download as quarantined, and these files are not notarized. Once, after\nunpacking:\n\n    xattr -dr com.apple.quarantine .\n' >> "$stage/README.txt"
	fi
	if [ $platform = windows ]; then
		# (Windows' own tar makes zips with / in the paths, which every unzip reads)
		(cd "$(dirname "$stage")" && /c/Windows/System32/tar.exe -a -cf "$(cygpath -w "$out/$dist.zip")" "$dist")
		sum "$dist.zip"
	else
		(cd "$(dirname "$stage")" && tar -czf "$out/$dist.tar.gz" "$dist")
		sum "$dist.tar.gz"
	fi
}

for app in "${apps[@]}"; do
	echo "== $app"
	case $app in
	fsh) native_fsh ;;
	fsh-ide) native_module fsh-ide fsh-ide ;;
	parley-files-viewer) native_module parley-files-viewer parley-files-viewer ;;
	*) echo "native.sh: no native build of $app" >&2; exit 2 ;;
	esac
done
