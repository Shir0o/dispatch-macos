#!/usr/bin/env bash
#
# Regenerate Assets/AppIcon.icns from Assets/AppIcon.svg.
# Uses only macOS built-ins (AppKit's SVG support + iconutil); rerun after editing the SVG.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SVG="${REPO_ROOT}/Assets/AppIcon.svg"
ICNS="${REPO_ROOT}/Assets/AppIcon.icns"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
ICONSET="${WORK_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET}"

# Render each iconset size (points x scale) with the standard macOS icon drop shadow.
swift - "${SVG}" "${ICONSET}" <<'SWIFT'
import AppKit

let args = CommandLine.arguments
guard let svg = NSImage(contentsOfFile: args[1]) else { fatalError("cannot load \(args[1])") }
let outDir = args[2]

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let k = CGFloat(px) / 1024
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
        shadow.shadowBlurRadius = 20 * k
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.set()
        svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
SWIFT

iconutil --convert icns --output "${ICNS}" "${ICONSET}"
echo "Wrote ${ICNS}"
