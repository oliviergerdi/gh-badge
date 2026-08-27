#!/usr/bin/env bash
#
# Builds gh-badge.app. Requires only the Xcode Command Line Tools — no Xcode,
# no App Store, no signing certificate.
#
#   ./build.sh              # release build into ./build/gh-badge.app
#   CONFIG=debug ./build.sh # debug build
#   ./build.sh --install    # also copy into /Applications (replaces existing)
#   ./build.sh --run        # also launch it
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="gh-badge"
BUNDLE_ID="com.gerdi.gh-badge"
APP="build/${APP_NAME}.app"

DO_INSTALL=0
DO_RUN=0
for arg in "$@"; do
	case "$arg" in
		--install) DO_INSTALL=1 ;;
		--run) DO_RUN=1 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

# --- preflight ---------------------------------------------------------------

if ! command -v swift >/dev/null 2>&1; then
	echo "error: 'swift' not found. Install the Command Line Tools:" >&2
	echo "         xcode-select --install" >&2
	exit 1
fi

# --- compile ----------------------------------------------------------------

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}" --product "${APP_NAME}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN="${BIN_DIR}/${APP_NAME}"

if [[ ! -x "${BIN}" ]]; then
	echo "error: expected binary at ${BIN} but it is missing" >&2
	exit 1
fi

# --- assemble the bundle ----------------------------------------------------

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Support/Info.plist "${APP}/Contents/Info.plist"

# Optional: a real app icon, if one has been generated. See docs in Support/.
if [[ -f Support/AppIcon.icns ]]; then
	cp Support/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
fi

# Optional: a custom menu bar glyph (e.g. the Octicons invertocat) as loose
# PNGs. Picked up automatically by MenuBarIcon; SF Symbol fallback otherwise.
if compgen -G "Support/Glyph/MenuBarGlyph*.png" >/dev/null; then
	cp Support/Glyph/MenuBarGlyph*.png "${APP}/Contents/Resources/"
fi

printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Validate the plist rather than discovering it is malformed at launch, where
# macOS fails silently and the app simply never appears in the menu bar.
plutil -lint "${APP}/Contents/Info.plist" >/dev/null

# --- sign -------------------------------------------------------------------

# Ad-hoc signature ('-'). Enough to run locally. If a real Apple Development
# identity is available it is preferred, because SMAppService (launch-at-login)
# is less temperamental with a stable signing identity.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
	IDENTITY="$(security find-identity -v -p codesigning \
		| grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')"
	echo "==> signing with: ${IDENTITY}"
else
	echo "==> signing ad-hoc (no Apple Development identity found)"
fi

codesign --force --sign "${IDENTITY}" --identifier "${BUNDLE_ID}" \
	--options runtime --timestamp=none "${APP}" >/dev/null 2>&1 \
	|| codesign --force --sign "${IDENTITY}" --identifier "${BUNDLE_ID}" "${APP}"

codesign --verify --deep --strict "${APP}"

echo "==> built ${APP}"

# --- optional install / run -------------------------------------------------

if [[ "${DO_INSTALL}" == "1" ]]; then
	echo "==> installing to /Applications/${APP_NAME}.app"
	rm -rf "/Applications/${APP_NAME}.app"
	cp -R "${APP}" "/Applications/${APP_NAME}.app"
	APP="/Applications/${APP_NAME}.app"
fi

if [[ "${DO_RUN}" == "1" ]]; then
	# Kill any previous instance so the new binary is what ends up in the menu bar.
	pkill -x "${APP_NAME}" 2>/dev/null || true
	sleep 0.3
	echo "==> launching"
	open "${APP}"
fi
