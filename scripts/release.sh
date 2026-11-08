#!/usr/bin/env bash
# Works out the next version from the Conventional Commits since the last release tag, and tags it.
#
#   ./scripts/release.sh                 # show the next version and its release notes; changes nothing
#   ./scripts/release.sh --tag           # create the annotated tag vX.Y.Z on HEAD, the notes as its message
#   ./scripts/release.sh --tag --push    # ... and push it, which starts .github/workflows/release.yml
#   ./scripts/release.sh --as=1.0.0      # a version of your own instead (e.g. going to 1.0.0, or a 1.2.0-beta.1)
#   ./scripts/release.sh --since=v0.19.0 # count from another vX.Y.Z tag than the last one before HEAD
#
# The bump is the strongest commit's since the last vX.Y.Z tag:
#   before 1.0   a breaking change (`type!:` or a `BREAKING CHANGE:` paragraph) → 0.MINOR; anything else → 0.x.PATCH.
#                The minor is 0.x's major: a host pinned with `.upToNextMinor(from:)` gets every fix and feature and
#                no break.
#   from 1.0     breaking → MAJOR, feat → MINOR, anything else → PATCH.
# A prerelease (vX.Y.Z-beta.1, made with --as) is not a base: the release after it is at least its X.Y.Z, with the
# notes of everything since the last release.
# The release notes (the tag's message, which release.yml publishes) list breaking changes (the BREAKING CHANGE
# paragraph, else the subject: what a host has to change), features and fixes; a breaking feature or fix is in both.
# refactor, build and revert go under "Other"; test, docs, ci, style and chore are left out, and alone make no release.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

tag=false
push=false
override=""
since=""
for arg in "$@"; do
    case "$arg" in
        --tag) tag=true ;;
        --push) push=true ;;
        --as=*) override="${arg#--as=}" ;;
        --since=*) since="${arg#--since=}" ;;
        -h | --help)
            sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg (see --help)" >&2
            exit 2
            ;;
    esac
done
if $push && ! $tag; then
    echo "--push needs --tag" >&2
    exit 2
fi

release_tags() {
    git tag --merged HEAD --list 'v*' --sort=-v:refname | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$1\$" || true
}

# Whether version $1 is above $2, both X.Y.Z.
version_above() {
    local a b i
    IFS=. read -r -a a <<<"$1"
    IFS=. read -r -a b <<<"$2"
    for i in 0 1 2; do
        ((a[i] > b[i])) && return 0
        ((a[i] < b[i])) && return 1
    done
    return 1
}

if [[ -z "$since" ]]; then
    since="$(release_tags "" | head -n 1)"
elif ! [[ "$since" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "--since takes a release tag, vX.Y.Z: $since" >&2
    exit 2
elif ! git rev-parse -q --verify "refs/tags/$since" >/dev/null; then
    echo "No such tag: $since" >&2
    exit 2
fi
last_tag="$since"
if [[ -z "$last_tag" ]]; then
    echo "No vX.Y.Z tag before HEAD; give the version with --as=X.Y.Z." >&2
    [[ -n "$override" ]] || exit 1
    range="HEAD"
    last_version="0.0.0"
else
    range="$last_tag..HEAD"
    last_version="${last_tag#v}"
fi

# The BREAKING CHANGE paragraph of a commit body, its lines joined; it ends at a blank line or at a trailer
# (`Co-Authored-By: …`, `Refs #…`) that follows it in the same footer.
breaking_note() {
    local line note="" inside=false
    while IFS= read -r line; do
        if ! $inside; then
            if [[ "$line" =~ ^BREAKING[\ -]CHANGE:\ *(.*)$ ]]; then
                inside=true
                note="${BASH_REMATCH[1]}"
            fi
        elif [[ -z "$line" || "$line" =~ ^[A-Za-z][A-Za-z0-9-]*(:\ |\ #) ]]; then
            break
        else
            note+=" $line"
        fi
    done <<<"$1"
    printf '%s' "$note"
}

breaking=()
features=()
fixes=()
other=()
level=0 # 0 nothing, 1 patch, 2 feature, 3 breaking
commits=0

# One record per commit: hash, subject, body, separated by US; records by RS.
while IFS=$'\x1f' read -r -d $'\x1e' hash subject body; do
    hash="${hash#$'\n'}"
    [[ -n "$hash" ]] || continue
    commits=$((commits + 1))
    short="${hash:0:7}"

    type=""
    scope=""
    bang=""
    description="$subject"
    if [[ "$subject" =~ ^([a-z]+)(\(([^\)]+)\))?(!)?:\ (.+)$ ]]; then
        type="${BASH_REMATCH[1]}"
        scope="${BASH_REMATCH[3]}"
        bang="${BASH_REMATCH[4]}"
        description="${BASH_REMATCH[5]}"
    fi
    line="${scope:+**$scope:** }$description ($short)"

    note="$(breaking_note "$body")"
    if [[ -n "$bang" || -n "$note" ]]; then
        breaking+=("${scope:+**$scope:** }${note:-$description} ($short)")
        level=3
    fi

    case "$type" in
        feat)
            features+=("$line")
            level=$((level < 2 ? 2 : level))
            ;;
        fix | perf)
            fixes+=("$line")
            level=$((level < 1 ? 1 : level))
            ;;
        refactor | build | revert | "")
            other+=("$line")
            level=$((level < 1 ? 1 : level))
            ;;
        *)
            # test, docs, ci, style, chore: in a release with others, not in its notes, and no release of their own.
            ;;
    esac
done < <(git log --reverse --no-merges --format='%H%x1f%s%x1f%b%x1e' "$range")

if ((level == 0)) && [[ -z "$override" ]]; then
    if ((commits == 0)); then
        echo "Nothing since $last_tag."
    else
        echo "Nothing to release since $last_tag: $commits commit(s) of test, docs, ci, style or chore only."
    fi
    exit 0
fi

IFS=. read -r major minor patch <<<"$last_version"
prerelease=""
if [[ -n "$override" ]]; then
    version="${override#v}"
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
        echo "Not a version: $override" >&2
        exit 2
    fi
else
    if ((major == 0)); then
        if ((level == 3)); then
            version="0.$((minor + 1)).0"
        else
            version="0.$minor.$((patch + 1))"
        fi
    else
        case "$level" in
            3) version="$((major + 1)).0.0" ;;
            2) version="$major.$((minor + 1)).0" ;;
            *) version="$major.$minor.$((patch + 1))" ;;
        esac
    fi
    # A prerelease since the last release names the version it leads to: the release is at least that one.
    latest_prerelease="$(release_tags '-[0-9A-Za-z.]+' | head -n 1)"
    if [[ -n "$latest_prerelease" ]]; then
        core="${latest_prerelease#v}"
        core="${core%%-*}"
        if version_above "$core" "$version"; then
            version="$core"
            prerelease="$latest_prerelease"
        fi
    fi
fi

notes_section() {
    local title="$1"
    shift
    (($# > 0)) || return 0
    printf '### %s\n\n' "$title"
    printf -- '- %s\n' "$@"
    printf '\n'
}

notes="$(
    notes_section "Breaking changes" ${breaking[@]+"${breaking[@]}"}
    notes_section "Features" ${features[@]+"${features[@]}"}
    notes_section "Fixes" ${fixes[@]+"${fixes[@]}"}
    notes_section "Other" ${other[@]+"${other[@]}"}
)"

echo "${last_tag:-(no tag)} → v$version ($commits commit$( ((commits == 1)) || echo s))${prerelease:+, after $prerelease}"
echo
if [[ -n "$notes" ]]; then
    printf '%s\n' "$notes"
else
    echo "(no changes for the notes)"
fi

$tag || exit 0

if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    echo "Tag v$version exists already." >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "The working tree has changes; the tag would not build what you see." >&2
    exit 1
fi
# Before tagging: a tag left behind by a push that can't go would be the base of the next run.
if $push; then
    branch="$(git rev-parse --abbrev-ref HEAD)"
    git fetch -q origin
    if ! git merge-base --is-ancestor HEAD "origin/$branch" 2>/dev/null; then
        echo "HEAD is not on origin/$branch yet: push the branch first." >&2
        exit 1
    fi
fi

message_file="$(mktemp)"
trap 'rm -f "$message_file"' EXIT
{
    printf 'Nits %s\n\n' "$version"
    [[ -n "$notes" ]] && printf '%s\n' "$notes"
} >"$message_file"
# Verbatim: the notes' "###" headings would be taken for comments.
git tag -a "v$version" --cleanup=verbatim -F "$message_file"
echo
echo "Tagged v$version on $(git rev-parse --short HEAD)."

if ! $push; then
    echo "Push it with: git push origin v$version"
    exit 0
fi
git push origin "v$version"
