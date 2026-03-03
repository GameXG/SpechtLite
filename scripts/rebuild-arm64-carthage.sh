#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

log() {
  printf '[arm64-car] %s\n' "$*"
}

require_path() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    printf 'Missing required path: %s\n' "$path" >&2
    exit 1
  fi
}

require_path "Carthage/Checkouts/NEKit/NEKit.xcodeproj"
require_path "Carthage/Checkouts/Resolver/Resolver.xcodeproj"
require_path "Carthage/Checkouts/tun2socks/tun2socks.xcodeproj"

log "Patching tun2socks lwip header include"
sed -i '' 's/#include "lwip\/opt.h"/#include "opt.h"/' \
  "Carthage/Checkouts/tun2socks/lwip/lwip/netdb.h"

log "Patching NEKit sodium compatibility stubs"
cat > "Carthage/Checkouts/NEKit/src/Crypto/Libsodium.swift" <<'EOF'
import Foundation

open class Libsodium {
    /// This must be accessed at least once before Libsodium is used.
    ///
    /// NOTE: The bundled Sodium binary in this toolchain does not expose arm64 macOS
    /// symbols. Keep this as a no-op flag so non-Sodium algorithms remain usable.
    public static let initialized: Bool = true
}
EOF

cat > "Carthage/Checkouts/NEKit/src/Crypto/SodiumStreamCrypto.swift" <<'EOF'
import Foundation

open class SodiumStreamCrypto: StreamCryptoProtocol {
    public enum Alogrithm {
        case chacha20, salsa20
    }

    public let key: Data
    public let iv: Data
    public let algorithm: Alogrithm

    var counter = 0

    let blockSize = 64

    public init(key: Data, iv: Data, algorithm: Alogrithm) {
        _ = Libsodium.initialized
        self.key = key
        self.iv = iv
        self.algorithm = algorithm
    }

    open func update(_ data: inout Data) {
        preconditionFailure("CHACHA20/SALSA20 requires libsodium symbols that are unavailable in this macOS arm64 build.")
    }
}
EOF

log "Building Resolver.framework (arm64 macOS)"
xcodebuild \
  -project "Carthage/Checkouts/Resolver/Resolver.xcodeproj" \
  -scheme "Resolver-macOS" \
  -configuration Release \
  -derivedDataPath /tmp/ResolverDD \
  build \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  >/tmp/resolver-build.log 2>&1
rsync -a --delete \
  /tmp/ResolverDD/Build/Products/Release/Resolver.framework/ \
  Carthage/Build/Mac/Resolver.framework/

log "Building tun2socks.framework + lwip.framework (arm64 macOS)"
xcodebuild \
  -project "Carthage/Checkouts/tun2socks/tun2socks.xcodeproj" \
  -scheme "tun2socks-macOS" \
  -configuration Release \
  -derivedDataPath /tmp/tun2socksDD \
  build \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  HEADER_SEARCH_PATHS='$(SRCROOT)/lwip $(SRCROOT)/lwip/lwip $(SRCROOT)/lwip/arch $(inherited)' \
  >/tmp/tun2socks-build.log 2>&1
rsync -a --delete \
  /tmp/tun2socksDD/Build/Products/Release/tun2socks.framework/ \
  Carthage/Build/Mac/tun2socks.framework/
rsync -a --delete \
  /tmp/tun2socksDD/Build/Products/Release/lwip.framework/ \
  Carthage/Build/Mac/lwip.framework/

log "Building NEKit.framework (arm64 macOS)"
xcodebuild \
  -project "Carthage/Checkouts/NEKit/NEKit.xcodeproj" \
  -scheme "NEKit-macOS" \
  -configuration Release \
  -derivedDataPath /tmp/NEKitDD \
  build \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  MACOSX_DEPLOYMENT_TARGET=10.13 \
  >/tmp/nekit-build.log 2>&1
rsync -a --delete \
  /tmp/NEKitDD/Build/Products/Release/NEKit.framework/ \
  Carthage/Build/Mac/NEKit.framework/

log "Completed. Patched + rebuilt frameworks are in Carthage/Build/Mac."
