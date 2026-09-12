#!/bin/zsh
# Build, sign, notarize, and package a ScreenCap release.
#
#   scripts/release.sh <version> [--dry-run]
#
# Steps: validate semver → bump versions in project.yml → Release build signed with
# "Developer ID Application" + hardened runtime → zip → notarize (notarytool) → staple →
# dmg (app + Applications symlink) → sign/notarize/staple dmg → SHA-256 → release notes
# skeleton → commit the version bump and tag v<version> → print the `gh release create` command.
#
# --dry-run runs everything except notarization, stapling, committing and tagging, and
# restores project.yml afterwards. Reads DEVELOPMENT_TEAM and NOTARY_PROFILE from
# scripts/local.env (see scripts/local.env.example).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ScreenCap"
IDENTITY="Developer ID Application"
DIST="dist"
DERIVED="build"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"

# ---------------------------------------------------------------- helpers
bold=$'\e[1m'; dim=$'\e[2m'; red=$'\e[31m'; green=$'\e[32m'; yellow=$'\e[33m'; reset=$'\e[0m'
step() { print -- $'\n'"${bold}==> $*${reset}"; }
info() { print -- "    $*"; }
warn() { print -- "${yellow}    ! $*${reset}"; }
die()  { print -- "${red}error: $1${reset}" >&2; exit "${2:-1}"; }
would() { print -- "${dim}    [dry-run] would run: $*${reset}"; }

usage() {
  cat <<EOF
Usage: scripts/release.sh <version> [--dry-run]

  <version>   semver, e.g. 1.2.0 or 1.2.0-beta.1 (becomes tag v<version>)
  --dry-run   build, sign, zip and dmg only; skip notarization, stapling, commit and tag

Reads scripts/local.env:
  DEVELOPMENT_TEAM   Apple Developer Team ID that owns the Developer ID certificate
  NOTARY_PROFILE     keychain profile created with \`xcrun notarytool store-credentials\`
EOF
}

# ---------------------------------------------------------------- arguments
VERSION=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $arg" 2 ;;
    *) [[ -z "$VERSION" ]] || { usage >&2; die "unexpected argument: $arg" 2; }; VERSION="$arg" ;;
  esac
done
[[ -n "$VERSION" ]] || { usage >&2; exit 2; }
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
[[ "$VERSION" =~ $SEMVER ]] || die "'$VERSION' is not a semver version (expected e.g. 1.2.0 or 1.2.0-beta.1)" 2
TAG="v$VERSION"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
NOTES="$DIST/RELEASE_NOTES.md"

# ---------------------------------------------------------------- local.env
step "Checking configuration"
if [[ -f scripts/local.env ]]; then source scripts/local.env; fi
[[ -n "${DEVELOPMENT_TEAM:-}" && "${DEVELOPMENT_TEAM}" != "YOUR_TEAM_ID" ]] \
  || die "DEVELOPMENT_TEAM is not set. Copy scripts/local.env.example to scripts/local.env and fill in your Team ID." 2

if [[ -z "${NOTARY_PROFILE:-}" || "${NOTARY_PROFILE}" == "YOUR_PROFILE_NAME" ]]; then
  if (( DRY_RUN )); then
    warn "NOTARY_PROFILE is not set; fine for --dry-run, required for a real release."
  else
    cat >&2 <<EOF
error: NOTARY_PROFILE is not set in scripts/local.env.

Create a notarytool keychain profile once (needs an app-specific password from
https://account.apple.com → Sign-In and Security → App-Specific Passwords):

  xcrun notarytool store-credentials "ScreenCapNotary" \\
    --apple-id "you@example.com" \\
    --team-id "$DEVELOPMENT_TEAM" \\
    --password "xxxx-xxxx-xxxx-xxxx"

Then add the profile name to scripts/local.env:

  NOTARY_PROFILE=ScreenCapNotary
EOF
    exit 2
  fi
fi

# Developer ID certificate for this team must be in the keychain.
if ! security find-identity -v -p codesigning | grep -F "$IDENTITY" | grep -qF "($DEVELOPMENT_TEAM)"; then
  security find-identity -v -p codesigning >&2 || true
  die "no valid '$IDENTITY' certificate for team $DEVELOPMENT_TEAM in the keychain (see list above)."
fi
info "Team:            $DEVELOPMENT_TEAM"
info "Notary profile:  ${NOTARY_PROFILE:-<unset>}"
info "Version:         $VERSION  (tag $TAG)"
(( DRY_RUN )) && info "Mode:            DRY RUN (no notarization, stapling, commit or tag)"

# ---------------------------------------------------------------- git state
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  if (( DRY_RUN )); then warn "tag $TAG already exists; a real release would abort here."
  else die "tag $TAG already exists."; fi
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  if (( DRY_RUN )); then warn "working tree has uncommitted changes; a real release would abort here."
  else git status --short >&2; die "working tree has uncommitted changes; commit or discard them first."; fi
fi
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"

# ---------------------------------------------------------------- version bump
step "Bumping versions in project.yml"
PROJECT_BACKUP="$(mktemp -t screencap-project-yml)"
cp project.yml "$PROJECT_BACKUP"
STAGING=""
# On exit: drop the dmg staging folder; in dry-run mode also put project.yml back and regenerate.
cleanup() {
  [[ -n "$STAGING" ]] && rm -rf "$STAGING"
  if (( DRY_RUN )); then
    cp "$PROJECT_BACKUP" project.yml
    xcodegen generate --quiet >/dev/null 2>&1 || true
  fi
  rm -f "$PROJECT_BACKUP"
  return 0
}
trap cleanup EXIT

OLD_SHORT="$(sed -nE 's/^ *CFBundleShortVersionString: *"([^"]*)".*/\1/p' project.yml)"
OLD_BUILD="$(sed -nE 's/^ *CFBundleVersion: *"([^"]*)".*/\1/p' project.yml)"
[[ -n "$OLD_SHORT" && -n "$OLD_BUILD" ]] || die "could not find CFBundleShortVersionString / CFBundleVersion in project.yml"
[[ "$OLD_BUILD" =~ ^[0-9]+$ ]] || die "CFBundleVersion '$OLD_BUILD' is not an integer"
NEW_BUILD=$(( OLD_BUILD + 1 ))
sed -i '' -E \
  -e "s/^( *CFBundleShortVersionString: *)\"[^\"]*\"/\1\"$VERSION\"/" \
  -e "s/^( *CFBundleVersion: *)\"[^\"]*\"/\1\"$NEW_BUILD\"/" \
  project.yml
grep -qE "^ *CFBundleShortVersionString: *\"$VERSION\"" project.yml || die "version bump failed"
grep -qE "^ *CFBundleVersion: *\"$NEW_BUILD\"" project.yml || die "build number bump failed"
info "CFBundleShortVersionString: $OLD_SHORT → $VERSION"
info "CFBundleVersion:            $OLD_BUILD → $NEW_BUILD"

# ---------------------------------------------------------------- build
step "Building Release (Developer ID, hardened runtime)"
mkdir -p "$DIST"
rm -f "$ZIP" "$DMG"
xcodegen generate --quiet
BUILD_LOG="$DIST/build-$VERSION.log"
set +e
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' clean build \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e
grep -E "error:|BUILD" "$BUILD_LOG" | sort -u | sed 's/^/    /' || true
(( BUILD_STATUS == 0 )) || die "xcodebuild failed (full log: $BUILD_LOG)"
[[ -d "$APP" ]] || die "build succeeded but $APP is missing"

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
print -- "$SIGN_INFO" | grep -E '^(Authority=Developer ID Application|TeamIdentifier=|Timestamp=)' | sed 's/^/    /'
print -- "$SIGN_INFO" | grep -qE 'flags=.*\(runtime\)' || die "hardened runtime flag is missing"
print -- "$SIGN_INFO" | grep -qF "Authority=$IDENTITY" || die "app is not signed with '$IDENTITY'"
print -- "$SIGN_INFO" | grep -q '^Timestamp=' || die "signature has no secure timestamp"
# Xcode injects get-task-allow into `build` (not `archive`) products; notarization rejects it.
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -qF 'get-task-allow' \
  && die "entitlements contain com.apple.security.get-task-allow (notarization would fail)"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" ]] || die "built app reports version $BUILT_VERSION, expected $VERSION"
info "Hardened runtime: on · version $BUILT_VERSION ($NEW_BUILD)"

# ---------------------------------------------------------------- notarize helper
# notarize <file>: submit, wait, fail with the notary log if not Accepted.
notarize() {
  local file="$1" out id verdict
  out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
  print -- "$out" | sed 's/^/    /'
  id="$(print -- "$out" | sed -nE 's/^ *id: ([0-9a-f-]+).*/\1/p' | head -1)"
  verdict="$(print -- "$out" | sed -nE 's/^ *status: (.*)$/\1/p' | tail -1)"
  if [[ "$verdict" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 | sed 's/^/    /' || true
    die "notarization of $file failed (status: ${verdict:-unknown})"
  fi
}

# ---------------------------------------------------------------- zip + notarize + staple
step "Zipping app"
ditto -c -k --keepParent "$APP" "$ZIP"
info "$ZIP"

step "Notarizing app"
if (( DRY_RUN )); then
  would "xcrun notarytool submit $ZIP --keychain-profile ${NOTARY_PROFILE:-<NOTARY_PROFILE>} --wait"
  would "xcrun stapler staple $APP   (then re-zip the stapled app)"
else
  notarize "$ZIP"
  xcrun stapler staple "$APP" | sed 's/^/    /'
  # Re-zip so the distributed archive contains the stapled ticket.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type exec --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
fi

# ---------------------------------------------------------------- dmg
step "Building dmg"
STAGING="$(mktemp -d -t screencap-dmg)"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
codesign --sign "$IDENTITY" --timestamp --verbose=1 "$DMG" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=1 "$DMG" 2>&1 | sed 's/^/    /'
info "$DMG"

step "Notarizing dmg"
if (( DRY_RUN )); then
  would "xcrun notarytool submit $DMG --keychain-profile ${NOTARY_PROFILE:-<NOTARY_PROFILE>} --wait"
  would "xcrun stapler staple $DMG"
else
  notarize "$DMG"
  xcrun stapler staple "$DMG" | sed 's/^/    /'
fi

# ---------------------------------------------------------------- checksums
step "SHA-256"
SUMS="$DIST/SHA256SUMS-$VERSION.txt"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")") | tee "$SUMS" | sed 's/^/    /'

# ---------------------------------------------------------------- release notes
step "Release notes skeleton"
if [[ -n "$PREV_TAG" ]]; then RANGE="$PREV_TAG..HEAD"; RANGE_LABEL="since $PREV_TAG"
else RANGE="HEAD"; RANGE_LABEL="all commits (no previous tag)"; fi
{
  print -- "# $APP_NAME $TAG"
  print
  print -- "<!-- Edit before publishing. Generated from git log: $RANGE_LABEL. -->"
  print
  print -- "## Highlights"
  print
  print -- "- "
  print
  print -- "## Changes"
  print
  git log "$RANGE" --no-merges --pretty='- %s (%h)'
  print
  print -- "## Install"
  print
  print -- "Download \`$(basename "$DMG")\`, open it, drag ScreenCap to Applications, then grant Screen Recording"
  print -- "permission on first launch (System Settings → Privacy & Security → Screen & System Audio Recording)."
  print
  print -- "## Checksums (SHA-256)"
  print
  print -- '```'
  cat "$SUMS"
  print -- '```'
} >"$NOTES"
info "$NOTES  ($RANGE_LABEL)"

# ---------------------------------------------------------------- commit + tag
step "Tagging $TAG"
RELEASE_FILES=(project.yml "$APP_NAME/Info.plist")
if (( DRY_RUN )); then
  would "git add ${RELEASE_FILES[*]} && git commit -m \"Release $TAG\""
  would "git tag -a $TAG -m \"$APP_NAME $TAG\""
  info "(project.yml will be restored to its previous contents)"
else
  git add "${RELEASE_FILES[@]}"
  git commit -q -m "Release $TAG" -- "${RELEASE_FILES[@]}"
  git tag -a "$TAG" -m "$APP_NAME $TAG"
  info "committed version bump and created tag $TAG (not pushed)"
fi

# ---------------------------------------------------------------- summary
step "Done"
cat <<EOF
    Artifacts in $DIST/:
      $DMG
      $ZIP
      $SUMS
      $NOTES

    Next steps (not run by this script):

      git push origin "\$(git branch --show-current)" $TAG
      gh release create $TAG $DMG $ZIP --title "$APP_NAME $TAG" --notes-file $NOTES
EOF
(( DRY_RUN )) && print -- "\n${yellow}    Dry run: nothing was notarized, stapled, committed or tagged.${reset}"
exit 0
