#!/bin/bash
set -e

# Usage: ./scripts/resign_ipa.sh <path_to_ipa>

IPA_PATH="$1"

if [ -z "$IPA_PATH" ]; then
    echo "Usage: $0 <path_to_ipa>"
    exit 1
fi

if [ ! -f "$IPA_PATH" ]; then
    echo "Error: File not found: $IPA_PATH"
    exit 1
fi

PROJECT_ROOT=$(pwd)
CERT_DIR="$PROJECT_ROOT/cert"
PROFILE_PATH="$CERT_DIR/adhoc.mobileprovision"
# The identity name we found earlier
IDENTITY="Apple Distribution: Duka De Jong (5WTF4R56K3)"
OUTPUT_IPA="${IPA_PATH%.*}_resigned.ipa"

# Check dependencies
if [ ! -f "$PROFILE_PATH" ]; then
    echo "Error: Provisioning profile not found at $PROFILE_PATH"
    exit 1
fi

# Function to extract values from plist using PlistBuddy
get_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || echo ""
}

echo "----------------------------------------"
echo "Resigning IPA"
echo "Input: $IPA_PATH"
echo "Identity: $IDENTITY"
echo "Profile: $PROFILE_PATH"
echo "----------------------------------------"

# Create temporary working directory
TEMP_DIR=$(mktemp -d)
echo "Working in $TEMP_DIR"

cp "$IPA_PATH" "$TEMP_DIR/original.ipa"
cd "$TEMP_DIR"

echo "Unzipping..."
unzip -q original.ipa

# Find the App bundle
APP_DIR=$(ls -d Payload/*.app)
APP_NAME=$(basename "$APP_DIR")
echo "Found App: $APP_NAME"

# 1. Parse the NEW Provisioning Profile to get the correct Entitlements and Bundle ID
echo "Parsing Provisioning Profile..."
security cms -D -i "$PROFILE_PATH" > profile.plist

# Extract Entitlements
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' profile.plist > entitlements.plist

# Extract Team ID and Bundle ID from the profile's entitlements to verify/update Info.plist
# Note: application-identifier usually is "TeamID.BundleID"
FULL_APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' profile.plist)
TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' profile.plist)

# Strip Team ID from the beginning of application-identifier to get Bundle ID
# Assuming format TeamID.BundleID
NEW_BUNDLE_ID=${FULL_APP_ID#$TEAM_ID.}

echo "Profile App ID: $FULL_APP_ID"
echo "Target Bundle ID: $NEW_BUNDLE_ID"

# 2. Update Info.plist Bundle ID to match the Profile
CURRENT_BUNDLE_ID=$(get_plist_value "CFBundleIdentifier" "$APP_DIR/Info.plist")
echo "Current Bundle ID: $CURRENT_BUNDLE_ID"

if [ "$CURRENT_BUNDLE_ID" != "$NEW_BUNDLE_ID" ]; then
    echo "Updating Bundle Identifier to $NEW_BUNDLE_ID..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_BUNDLE_ID" "$APP_DIR/Info.plist"
fi

# 3. Clean up old signature
echo "Removing old signature..."
rm -rf "$APP_DIR/_CodeSignature"

# 4. Copy new embedded.mobileprovision
echo "Copying new provisioning profile..."
cp "$PROFILE_PATH" "$APP_DIR/embedded.mobileprovision"

# 5. Sign Frameworks and Dylibs (Recursive deep signing is generally preferred, 
# but a flat loop over Frameworks is often enough for simple apps. 
# For robustness, we find all signable mach-o binaries/bundles inside).

# Simple approach: Sign contents of Frameworks dir first
if [ -d "$APP_DIR/Frameworks" ]; then
    echo "Signing Frameworks..."
    find "$APP_DIR/Frameworks" -depth -name "*.framework" -o -name "*.dylib" | while read -r FRAMEWORK; do
        echo "  Signing $(basename "$FRAMEWORK")"
        /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$FRAMEWORK"
    done
fi

# 6. Sign the Main App
echo "Signing App Binary..."
/usr/bin/codesign --force --sign "$IDENTITY" --entitlements entitlements.plist --timestamp=none "$APP_DIR"

# 7. Zip it back
echo "Packaging resigned IPA..."
zip -qr "resigned.ipa" Payload

# Move to output
mv "resigned.ipa" "$OUTPUT_IPA"

# Cleanup
cd "$PROJECT_ROOT"
rm -rf "$TEMP_DIR"

echo "----------------------------------------"
echo "Success! Resigned IPA saved to:"
echo "$OUTPUT_IPA"
echo "----------------------------------------"
