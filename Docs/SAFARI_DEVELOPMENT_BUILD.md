# Safari Development Build

Safari local WebExtension testing needs a development signature that is separate from SmartShot's persistent self-signed Release installation. The repository script builds a fresh, universal Release-configuration artifact with Xcode's **Sign to Run Locally** identity, then adds `com.apple.security.get-task-allow` only to that temporary containing app and Safari extension.

```sh
Scripts/build_safari_development.sh
```

The script prints the exact `SmartShot.app` path when it succeeds. It uses a new directory under `TMPDIR` by default, does not change `project.yml` or the generated Xcode project, and does not touch `/Applications/SmartShot.app`. Xcode 26 can transiently register a macOS app even when the command-line build disables registration, so the script unregisters its exact temporary app and appex paths on success, failure, or interruption. It also verifies the universal binaries, nested strict signatures, matching app/appex/WebExtension versions, app audio entitlement, extension sandbox entitlement, and `get-task-allow` on both relevant executables.

To retain a predictable path, provide an empty directory outside the repository and `/Applications`:

```sh
Scripts/build_safari_development.sh \
  --derived-data /private/tmp/SmartShotSafariDev8DerivedData
```

An existing artifact can be checked without rebuilding:

```sh
Scripts/build_safari_development.sh \
  --verify-only /private/tmp/SmartShotSafariDev8DerivedData/Build/Products/Release/SmartShot.app
```

After building, launch the printed app path once so macOS registers that exact containing app and extension. For a Sign to Run Locally build, enable **Safari > Settings > Developer > Allow unsigned extensions**, enable **SmartShot Web Selector**, and grant Website Access. Safari resets the unsigned-extension override when it quits.

This artifact is intentionally development-only. Do not copy it to `/Applications`, use it for normal native testing, or distribute it: `get-task-allow` weakens the hardened-runtime boundary for debugging, and ad-hoc signing does not pass Gatekeeper. Continue using the persistent self-signed Release build for native testing and a proper Apple distribution signature for any supported release.
