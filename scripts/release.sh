#!/usr/bin/env bash
# Cut an allman-mac release: tests → download the matching allman-cli binary →
# build dist/Allman.app (Release, arm64, ad-hoc signed) → zip → checksum → tag →
# push → `gh release create` with assets.
#
# Usage:
#   scripts/release.sh                          # tag = v$MARKETING_VERSION (project.yml)
#   scripts/release.sh --cli-version v0.4.0     # pin the embedded CLI (default: latest stable)
#   scripts/release.sh --suffix alpha.1         # tag v0.2.0-alpha.1, published as a prerelease
#   scripts/release.sh --skip-tests             # not recommended
#   scripts/release.sh --dry-run                # build + zip, stop before tag/publish
#
# The version comes from MARKETING_VERSION in project.yml — bump it in a normal
# commit first. Tags are v<major>.<minor>.<patch>; a -alpha.N/-beta.N suffix
# publishes a GitHub prerelease, otherwise the release is stable ("Latest").
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="tarkaai/allman-mac"
CLI_REPO="tarkaai/allman-cli"
CLI_ASSET="allman-darwin-arm64"

cli_version=""; suffix=""; skip_tests=0; dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli-version) cli_version="${2:?--cli-version needs a value}"; shift 2 ;;
    --suffix) suffix="${2:?--suffix needs a value}"; shift 2 ;;
    --skip-tests) skip_tests=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "release: unknown argument $1" >&2; exit 1 ;;
  esac
done

die() { echo "release: $*" >&2; exit 1; }
log() { echo "release: $*"; }

version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' project.yml | head -1)"
[[ -n "$version" ]] || die "could not read MARKETING_VERSION from project.yml"
tag="v${version}"
prerelease=0
if [[ -n "$suffix" ]]; then
  [[ "$suffix" =~ ^(alpha|beta)\.[0-9]+$ ]] || die "--suffix must look like alpha.1 or beta.2"
  tag="${tag}-${suffix}"
  prerelease=1
fi
log "cutting ${tag} ($([[ $prerelease = 1 ]] && echo prerelease || echo stable))"

# --- preflight ---------------------------------------------------------------
for tool in gh xcodegen xcodebuild ditto shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done
[[ -z "$(git status --porcelain -uno)" ]] || die "tracked files have uncommitted changes"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "not on main"
git fetch origin main --quiet
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "local main is not in sync with origin/main"
[[ -z "$(git tag -l "$tag")" ]] || die "tag $tag already exists locally"
[[ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ]] || die "tag $tag already exists on origin"

# --- tests -------------------------------------------------------------------
log "ui rules"
scripts/check-rules.sh
xcodegen generate --quiet
if [[ $skip_tests = 0 ]]; then
  log "test"
  test_log="$(mktemp)"
  if ! xcodebuild -project Allman.xcodeproj -scheme Allman -configuration Debug \
      -derivedDataPath build -destination 'platform=macOS' test \
      CODE_SIGN_IDENTITY="-" >"$test_log" 2>&1; then
    grep -E "error:|failed|TEST FAILED" "$test_log" | head -40 >&2
    die "tests failed (full log: $test_log)"
  fi
  grep -E "Executed [0-9]+ tests" "$test_log" | tail -1
  rm -f "$test_log"
else
  log "skipping tests (--skip-tests)"
fi

# --- embedded CLI --------------------------------------------------------------
if [[ -z "$cli_version" ]]; then
  # /releases/latest is the newest non-prerelease, non-draft release.
  cli_version="$(gh api "repos/$CLI_REPO/releases/latest" --jq .tag_name 2>/dev/null || true)"
  [[ -n "$cli_version" && "$cli_version" != "null" ]] \
    || die "no stable release found on $CLI_REPO — release the CLI first, or pass --cli-version"
fi
log "embedding allman-cli $cli_version"
cli_dir="$(mktemp -d)"
trap 'rm -rf "$cli_dir"' EXIT
gh release download "$cli_version" --repo "$CLI_REPO" --dir "$cli_dir" --clobber \
  --pattern "$CLI_ASSET" --pattern "$CLI_ASSET.sha256"
expected="$(awk '{print $1}' "$cli_dir/$CLI_ASSET.sha256")"
actual="$(shasum -a 256 "$cli_dir/$CLI_ASSET" | awk '{print $1}')"
[[ "$expected" == "$actual" ]] || die "checksum mismatch for $CLI_ASSET"
chmod +x "$cli_dir/$CLI_ASSET"

# --- build -------------------------------------------------------------------
log "building Allman.app (Release, arm64)"
build_log="$(mktemp)"
if ! ALLMAN_BIN="$cli_dir/$CLI_ASSET" xcodebuild \
    -project Allman.xcodeproj -scheme Allman -configuration Release \
    -derivedDataPath build -destination 'platform=macOS' build \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" >"$build_log" 2>&1; then
  grep -E "error:|BUILD FAILED" "$build_log" | head -40 >&2
  die "build failed (full log: $build_log)"
fi
grep -E "embedded allman|warning: no allman" "$build_log" || true
rm -f "$build_log"

app="build/Build/Products/Release/Allman.app"
[[ -d "$app" ]] || die "build produced no app at $app"
rm -rf dist/Allman.app && mkdir -p dist && cp -R "$app" dist/Allman.app

# Smoke-test the bundle: the embedded CLI must run and report the version we pinned.
embedded="dist/Allman.app/Contents/Resources/allman"
[[ -x "$embedded" ]] || die "no allman binary embedded at $embedded"
embedded_version="$("$embedded" --version | tr -d '[:space:]')"
[[ "v$embedded_version" == "$cli_version" || "$embedded_version" == "$cli_version" ]] \
  || die "embedded allman reports $embedded_version, expected $cli_version"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/Allman.app/Contents/Info.plist)"
[[ "$bundle_version" == "$version" ]] || die "bundle version $bundle_version != $version"

# --- package -----------------------------------------------------------------
zip="dist/Allman-${version}-arm64.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --keepParent dist/Allman.app "$zip"
(cd dist && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
log "sha256: $(awk '{print $1}' "$zip.sha256")"

if [[ $dry_run = 1 ]]; then
  log "dry-run: built $zip, stopping before tag/publish"
  exit 0
fi

# --- tag + publish -----------------------------------------------------------
log "tagging $tag"
git tag "$tag"
git push origin "$tag"

notes="Allman for Mac ${version}. Embeds allman-cli ${cli_version}.

- Requires macOS 26 (Tahoe) on Apple Silicon.
- Ad-hoc signed, not notarized: on first launch, right-click **Allman.app → Open**.
- Unzip, move \`Allman.app\` to /Applications, launch; it lives in the menu bar."
log "publishing release on $REPO"
flags=()
[[ $prerelease = 1 ]] && flags+=(--prerelease)
gh release create "$tag" --repo "$REPO" --title "$tag" --notes "$notes" "${flags[@]+"${flags[@]}"}" "$zip" "$zip.sha256"
log "done: $(gh release view "$tag" --repo "$REPO" --json url --jq .url)"
