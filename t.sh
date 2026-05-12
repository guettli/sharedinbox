#!/bin/bash
# Helper script to generate a production Android Keystore.
# Run this from the project root.

# Define the path relative to the project root
KEYSTORE_PATH="android/app/upload-keystore.jks"

echo "Generating keystore at: $KEYSTORE_PATH"

keytool -genkey -v \
  -keystore "$KEYSTORE_PATH" \
  -alias upload \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000

echo ""
echo "Done."
echo "1. Remember your password!"
echo "2. Back up $KEYSTORE_PATH safely."
echo "3. Do NOT commit the .jks file or passwords to git."
