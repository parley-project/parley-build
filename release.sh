#!/usr/bin/env bash
#
# release.sh - release the version currently in pom.xml to Maven Central (and optionally
#              GitHub Packages), then record the release in git.
#
# Works on the project you run it from, so one copy serves every Parley project:
#   cd parley-core && ../parley-build/release.sh
#
# Usage:  release.sh [-y] [-n] [-g | -G] [-A] [project-dir]
#         release.sh              release to Maven Central (asks first)
#         release.sh -n           dry run: run the checks and show what would be done
#         release.sh -y           no confirmation prompt
#         release.sh -g           Maven Central AND GitHub Packages
#         release.sh -G           GitHub Packages only (the old behaviour; allows SNAPSHOTs)
#         release.sh -A           accept the findings (below) without being asked, e.g. with -y
#         release.sh ../parley-io release the project in that directory
#
# Steps:
#   1. Read the version from pom.xml
#   2. Check: git repo, no unfinished merge, tag not already used, git can push,
#      and for Central: not a SNAPSHOT, no SNAPSHOT parent/dependencies in pom.xml,
#      a <server> with <id>central</id> in ~/.m2/settings.xml, a GPG signing key
#   3. mvn -Prelease clean deploy    (Central: sources, javadoc, GPG signatures, upload)
#      mvn clean deploy              (GitHub Packages, with -g or -G)
#   4. git commit (only if there are uncommitted changes), git tag v<version>,
#      git push the current branch and the tag
#   5. YOU press Publish on https://central.sonatype.com/publishing/deployments
#      (the parent POM sets autoPublish=false, so nothing is public until you do)
#
# Findings: reported, and the release only goes ahead if you accept them (the default answer is no;
# with -y, -A is needed too). There can be good reasons to release anyway.
#   - Deprecated code in a major version (1.0.0, 2.0.0, ...): that is where deprecated code is
#     removed; anything @Deprecated in it stays in the public API until the next major version.
#     For other versions deprecations are normal and only listed.
#   - The private script: pom.xml, README.md and CHANGELOG.md are public (the pom is published to
#     Central), so they shouldn't mention release.sh, and the project shouldn't track a copy of it.
#
# Checkpoint (listed, no answer needed):
#   - Test paths: tests that write scratch files under target/, or read files by a path
#     relative to the working directory (resources/..., src/..., TestFiles/...), or use user.dir.
#     Move them to JUnit's @TempDir and the test class path, as parley-core and parley-dns did
#     (parley-core's src/test/resources/junit-platform.properties keeps the temp folders of failed
#     tests; parley-dns's Fixtures class finds fixtures on the class path).
#
# Set the new version in pom.xml BEFORE running this script, e.g.
#   mvn versions:set -DnewVersion=1.0.0 -DgenerateBackupPoms=false
#   mvn versions:update-parent -DparentVersion=1.0.0
#
# GPG passphrase: export MAVEN_GPG_PASSPHRASE, or let gpg-agent / pinentry-mac ask for it.
# GitHub Packages (-g/-G) needs the GitHub CLI: brew install gh; gh auth login -s write:packages
#
set -euo pipefail

REMOTE="origin"
DRY_RUN=false
ASSUME_YES=false
ACCEPT_FINDINGS=false
TO_CENTRAL=true
TO_GITHUB=false
DEPLOYMENTS_URL="https://central.sonatype.com/publishing/deployments"

usage() { sed -n '3,46p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts "yngGAh" opt; do
	case "$opt" in
		A) ACCEPT_FINDINGS=true ;;
		y) ASSUME_YES=true ;;
		n) DRY_RUN=true ;;
		g) TO_GITHUB=true ;;
		G) TO_GITHUB=true; TO_CENTRAL=false ;;
		h) usage 0 ;;
		*) usage 1 ;;
	esac
done
shift $((OPTIND - 1))
PROJECT_DIR="${1:-.}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
run()  {
	if $DRY_RUN; then
		echo "    [dry run] $*"
	else
		"$@"
	fi
}

command -v mvn >/dev/null 2>&1 || die "mvn is not on the PATH."
command -v git >/dev/null 2>&1 || die "git is not on the PATH."
if $TO_GITHUB; then
	command -v gh >/dev/null 2>&1 || die "The GitHub CLI (gh) is not on the PATH. Install it: brew install gh"
	gh auth status --hostname github.com >/dev/null 2>&1 \
		|| die "The GitHub CLI is not logged in. Run: gh auth login -s write:packages"
fi

# git push through gh's credentials for HTTPS remotes when gh is available,
# otherwise through git's own credential helper.
git_push() {
	if command -v gh >/dev/null 2>&1 \
	   && [[ "$(git remote get-url "$REMOTE" 2>/dev/null)" == https://github.com/* ]]; then
		git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push "$@"
	else
		git push "$@"
	fi
}

[[ -d "$PROJECT_DIR" ]] || die "$PROJECT_DIR is not a directory."
cd "$PROJECT_DIR"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
	|| die "$(pwd) is not in a git repository. Run release.sh from inside a project."
cd "$ROOT"
[[ -f pom.xml ]] || die "pom.xml not found in $ROOT"

# ---------------------------------------------------------------------------
# 1. Coordinates from pom.xml (Maven itself is the most reliable parser)
# ---------------------------------------------------------------------------
mvn_eval() {
	local v
	v="$(mvn -q -DforceStdout help:evaluate -Dexpression="$1" 2>/dev/null || true)"
	[[ -z "$v" || "$v" == *ERROR* || "$v" == *" "* || "$v" == "null object"* ]] && v=""
	echo "$v"
}
VERSION="$(mvn_eval project.version)"
[[ -n "$VERSION" ]] || die "Could not read the project version (does 'mvn help:evaluate' work here?)"
ARTIFACT="$(mvn_eval project.artifactId)"
GROUP="$(mvn_eval project.groupId)"
PARENT_VERSION="$(mvn_eval project.parent.version)"
TAG="v${VERSION}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

SNAPSHOT=false
[[ "$VERSION" == *-SNAPSHOT ]] && SNAPSHOT=true

# ---------------------------------------------------------------------------
# 2. Checks - all of them run before anything is built or uploaded
# ---------------------------------------------------------------------------
[[ "$BRANCH" != "HEAD" ]] || die "Not on a branch (detached HEAD)."
[[ ! -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]] || die "A merge is in progress. Finish it first."

SETTINGS="${HOME}/.m2/settings.xml"
has_server() { [[ -f "$SETTINGS" ]] && grep -q "<id>[[:space:]]*$1[[:space:]]*</id>" "$SETTINGS"; }

if $TO_CENTRAL; then
	$SNAPSHOT && die "$VERSION is a SNAPSHOT; Maven Central only takes releases. Set the version first (or use -G for GitHub Packages)."
	[[ "$PARENT_VERSION" != *-SNAPSHOT ]] \
		|| die "The parent is $PARENT_VERSION. Release the parent first, then: mvn versions:update-parent -DparentVersion=<released version>"
	# Any other SNAPSHOT left in pom.xml (dependencies, version properties) would be published as-is.
	LEFTOVER="$(grep -n -- '-SNAPSHOT' pom.xml || true)"
	[[ -z "$LEFTOVER" ]] || die "pom.xml still mentions SNAPSHOT versions; Central releases can't depend on them:
$LEFTOVER"
	has_server central \
		|| die "No <server> with <id>central</id> in $SETTINGS (your Central Portal user token goes there)."
	command -v gpg >/dev/null 2>&1 || die "gpg is not on the PATH. Install it: brew install gnupg pinentry-mac"
	[[ -n "$(gpg --list-secret-keys 2>/dev/null)" ]] \
		|| die "No GPG secret key found. Create one: gpg --full-generate-key (and send it to a keyserver)."
fi

if $TO_GITHUB; then
	has_server github \
		|| die "No <server> with <id>github</id> in $SETTINGS (Maven needs it to deploy to GitHub Packages)."
	if grep -q '\${env\.GITHUB_TOKEN}' "$SETTINGS" && [[ -z "${GITHUB_TOKEN:-}" ]]; then
		GITHUB_TOKEN="$(gh auth token --hostname github.com 2>/dev/null)" \
			|| die "Could not get a token from the GitHub CLI. Run: gh auth login -s write:packages"
		export GITHUB_TOKEN
		SCOPES="$(gh api -i user 2>/dev/null | tr -d '\r' | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p')"
		if [[ -n "$SCOPES" && "$SCOPES" != *write:packages* ]]; then
			die "The GitHub CLI token can't publish packages (scopes: $SCOPES). Run: gh auth refresh -s write:packages"
		fi
	fi
fi

if ! $SNAPSHOT; then
	git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
		&& die "Tag $TAG already exists. Change the version in pom.xml first (a released version can't be re-published)."
	git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1 \
		&& die "Tag $TAG already exists on $REMOTE. Change the version in pom.xml first."
fi

# Checkpoint: no references to this private script in the public files, and no tracked copy of it
PRIVATE_REFS="$(grep -nH 'release\.sh' pom.xml README.md CHANGELOG.md 2>/dev/null || true)"
git ls-files --error-unmatch release.sh >/dev/null 2>&1 \
	&& PRIVATE_REFS="${PRIVATE_REFS:+$PRIVATE_REFS
}release.sh is tracked in git (git rm it)"
FINDINGS=""
if [[ -n "$PRIVATE_REFS" ]]; then
	FINDINGS+="  - Public files mention the private release script (pom.xml is published to Central):
$(echo "$PRIVATE_REFS" | sed 's/^/      /')
"
fi

# Checkpoint: deprecated code. A major version is where it gets removed.
DEPRECATED=""
if [[ -d src/main/java ]]; then
	DEPRECATED="$(grep -rn '@Deprecated' src/main/java 2>/dev/null | sed 's|^src/main/java/||' || true)"
fi
MAJOR=false
[[ "$VERSION" =~ ^[0-9]+\.0\.0$ ]] && MAJOR=true
if [[ -n "$DEPRECATED" ]] && $MAJOR; then
	FINDINGS+="  - $VERSION is a major version, but $(echo "$DEPRECATED" | wc -l | tr -d ' ') @Deprecated declaration(s) would ship with it and stay in
    the public API until the next major version:
$(echo "$DEPRECATED" | head -20 | sed 's/^/      /' | cut -c1-150)
$([[ $(echo "$DEPRECATED" | wc -l) -gt 20 ]] && echo '      ...' || true)
"
fi

info "Checking that git can push to $REMOTE"
git_push --dry-run --quiet "$REMOTE" "$BRANCH" \
	|| die "git can't push $BRANCH to $REMOTE (see above). Nothing was deployed."

# Checkpoint: tests that depend on the build's output folder or on the working directory
TEST_PATHS=""
if [[ -d src/test/java ]]; then
	#  A path string starting with one of these folders. Not flagged: comments, paths resolved against
	#  another folder (new File(dir, "src/..."), write(root, "src/..."), dir.resolve("...")) and class
	#  path lookups (getResource("..."), Fixtures.file("..."))
	TEST_PATHS="$(grep -rnE '"(\./)?((target|resources|TestFiles)(/|")|src/)|user\.dir' src/test/java 2>/dev/null \
		| grep -vE '^[^:]+:[0-9]+:[[:space:]]*(\*|//)' \
		| grep -vE '(new File|write|Path\.of|Paths\.get)\([^"]+,[[:space:]]*"|\.resolve\("' \
		| grep -vE 'getResource(AsStream)?\(|Fixtures\.file\(' || true)"
fi

CHANGES="$(git status --porcelain --untracked-files=no)"
TARGETS=()
$TO_CENTRAL && TARGETS+=("Maven Central")
$TO_GITHUB  && TARGETS+=("GitHub Packages")

echo
echo "  Project  : $ROOT"
echo "  Artifact : ${GROUP:-?}:${ARTIFACT:-?}:${VERSION}"
echo "  Parent   : ${PARENT_VERSION:-(none)}"
echo "  Publish  : $(IFS=,; echo "${TARGETS[*]}" | sed 's/,/ and /')"
echo "  Branch   : $BRANCH  ->  $REMOTE"
if $SNAPSHOT; then
	echo "  Tag      : (none - SNAPSHOT versions are not tagged)"
else
	echo "  Tag      : $TAG"
fi
if [[ -n "$CHANGES" ]]; then
	echo "  Commit   : these uncommitted changes will be committed as \"Release $VERSION\":"
	echo "$CHANGES" | sed 's/^/             /'
else
	echo "  Commit   : nothing to commit (working tree clean)"
fi
if [[ -n "$TEST_PATHS" ]]; then
	echo "  Checkpoint: these tests use target/, resources/, src/, TestFiles/ or user.dir by path; consider moving them"
	echo "             to @TempDir and the test class path (see parley-core) - $(echo "$TEST_PATHS" | cut -d: -f1 | sort -u | wc -l | tr -d ' ') file(s):"
	echo "$TEST_PATHS" | head -10 | sed -e 's/^src\/test\/java\///' -e 's/^/             /' | cut -c1-140
	[[ $(echo "$TEST_PATHS" | wc -l) -gt 10 ]] && echo "             ..."
	[[ -f src/test/resources/junit-platform.properties ]] \
		|| echo "             (and add src/test/resources/junit-platform.properties, as in parley-core)"
fi
if [[ -n "$DEPRECATED" ]]; then
	if $MAJOR; then
		echo "  Deprecated: $(echo "$DEPRECATED" | wc -l | tr -d ' ') @Deprecated declaration(s) in a major version (see FINDINGS)"
	else
		echo "  Deprecated: $(echo "$DEPRECATED" | wc -l | tr -d ' ') @Deprecated declaration(s); remove them in the next major version"
	fi
fi
UNTRACKED="$(git ls-files --others --exclude-standard)"
if [[ -n "$UNTRACKED" ]]; then
	echo "  Note     : untracked files are NOT included:"
	echo "$UNTRACKED" | head -10 | sed 's/^/             /'
fi
echo

if [[ -n "$FINDINGS" ]]; then
	echo "FINDINGS - the release only goes ahead if you accept them:"
	printf '%s' "$FINDINGS"
	echo
	if $DRY_RUN; then
		echo "  (dry run: a real run asks you to accept these)"
		echo
	elif $ACCEPT_FINDINGS; then
		echo "  Accepted with -A."
		echo
	elif $ASSUME_YES; then
		die "The findings above need to be accepted: rerun without -y, or add -A to accept them."
	else
		read -r -p "Accept these findings and release anyway? [y/N] " answer
		[[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled. Nothing was deployed."; exit 1; }
		echo
	fi
fi

if ! $ASSUME_YES && ! $DRY_RUN; then
	read -r -p "Release $VERSION? [y/N] " answer
	[[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 1; }
fi

# ---------------------------------------------------------------------------
# 3. Build, test and deploy (stops here if anything fails).
#    Central goes first: its upload waits for your review and can still be dropped,
#    while a GitHub Packages version can't be re-published once it's there.
# ---------------------------------------------------------------------------
if $TO_CENTRAL; then
	info "mvn -Prelease clean deploy   (Maven Central)"
	run mvn -Prelease clean deploy
fi
if $TO_GITHUB; then
	info "mvn clean deploy   (GitHub Packages)"
	run mvn clean deploy
fi

# ---------------------------------------------------------------------------
# 4. Git: commit, tag, push
# ---------------------------------------------------------------------------
if [[ -n "$CHANGES" ]]; then
	info "git commit"
	run git commit -a -m "Release $VERSION"
fi
if ! $SNAPSHOT; then
	info "git tag $TAG"
	run git tag -a "$TAG" -m "Release $VERSION"
fi
info "git push $REMOTE $BRANCH"
run git_push "$REMOTE" "$BRANCH"
if ! $SNAPSHOT; then
	info "git push $REMOTE $TAG"
	run git_push "$REMOTE" "$TAG"
fi

echo
if $DRY_RUN; then
	info "Dry run complete. Nothing was deployed or pushed."
else
	info "Released ${ARTIFACT:-project} $VERSION"
	if $TO_CENTRAL; then
		cat <<MSG

    One step left: open $DEPLOYMENTS_URL,
    wait for "${ARTIFACT} ${VERSION}" to show VALIDATED, then press Publish.
    (If you Drop it instead, also remove the tag: git push $REMOTE :refs/tags/$TAG && git tag -d $TAG)
MSG
	fi
fi
