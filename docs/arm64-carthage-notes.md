# ARM64 Carthage Notes

This repo currently needs patch-and-rebuild steps for a few Carthage frameworks on Apple Silicon (`arm64`), mainly because some upstream binaries are iOS-only or x86_64-only.

## One-command rebuild

From repository root:

```bash
bash scripts/rebuild-arm64-carthage.sh
```

The script:

1. Patches `tun2socks` lwIP include path.
2. Applies `NEKit` sodium compatibility stubs for `arm64` macOS.
3. Rebuilds and copies:
   - `Resolver.framework`
   - `tun2socks.framework`
   - `lwip.framework`
   - `NEKit.framework`

All rebuilt artifacts are copied into `Carthage/Build/Mac`.

## Verify app build

```bash
xcodebuild -project SpechtLite.xcodeproj \
  -scheme SpechtLite \
  -configuration Debug \
  -derivedDataPath /tmp/SpechtLiteDD \
  build CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
```
