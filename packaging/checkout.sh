#!/bin/sh
# Clone the repositories in packaging/repos.txt beside parley-build (shallow, one branch each),
# or print what would be built.
#
# Usage: packaging/checkout.sh [--heads] [FOLDER=BRANCH ...]
#   FOLDER=BRANCH  build that branch of that folder's repository instead of the one in repos.txt
#   --heads        clone nothing: print each repository's commit (FOLDER BRANCH SHA), which the
#                  nightly run compares with the last one it built
#
# Folders that are already there are left as they are (a developer's checkout).

set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
heads=""
if [ "$1" = --heads ]; then
	heads=yes
	shift
fi
overrides=" $* "
github=${PARLEY_GITHUB:-https://github.com/parley-project}

grep -v '^#' "$here/repos.txt" | while read -r folder repo branch; do
	[ -n "$folder" ] || continue
	# (FOLDER=BRANCH on the command line wins)
	for o in $overrides; do
		case $o in
		"$folder="*) branch=${o#*=} ;;
		esac
	done
	if [ -n "$heads" ]; then
		sha=$(git ls-remote "$github/$repo.git" "refs/heads/$branch" | cut -f1)
		if [ -z "$sha" ]; then
			echo "checkout.sh: $repo has no branch $branch" >&2
			exit 1
		fi
		echo "$folder $branch $sha"
	elif [ -d "$root/$folder" ]; then
		echo "$folder: already there, left as it is"
	else
		echo "$folder: $repo $branch"
		git clone -q --depth 1 --branch "$branch" "$github/$repo.git" "$root/$folder"
	fi
done
