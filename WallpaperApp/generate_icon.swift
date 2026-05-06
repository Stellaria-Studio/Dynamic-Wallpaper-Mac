import Cocoa
import CoreImage

// Generate a 1024x1024 app icon
func makeIcon() -> NSImage {
    let size = CGSize(width: 1024, height: 1024)
    let image = NSImage(size: size)
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(origin: .zero, size: size)
    let inset = rect.insetBy(dx: 40, dy: 40)
    let radius: CGFloat = 180

    // Shadow
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 20, color: CGColor(gray: 0, alpha: 0.3))

    // Background: rounded rect with gradient
    let path = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        CGColor(red: 0.25, green: 0.42, blue: 0.88, alpha: 1),
        CGColor(red: 0.55, green: 0.25, blue: 0.80, alpha: 1),
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: inset.midX, y: inset.minY), end: CGPoint(x: inset.midX, y: inset.maxY), options: [])

    // Inner glow overlay
    ctx.resetClip()
    let innerGlow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.15),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(innerGlow, start: CGPoint(x: inset.midX, y: inset.minY), end: CGPoint(x: inset.midX, y: inset.midY), options: [])

    // Monitor shape
    ctx.resetClip()
    ctx.setShadow(offset: .zero, blur: 0)
    let monitorW: CGFloat = 460
    let monitorH: CGFloat = 340
    let monitorX = rect.midX - monitorW / 2
    let monitorY = rect.midY - monitorH / 2 + 20
    let monitorRadius: CGFloat = 28
    let monitorRect = CGRect(x: monitorX, y: monitorY, width: monitorW, height: monitorH)

    // Monitor bezel
    let monitorPath = CGPath(roundedRect: monitorRect, cornerWidth: monitorRadius, cornerHeight: monitorRadius, transform: nil)
    ctx.addPath(monitorPath)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1))
    ctx.fillPath()

    // Monitor screen (slightly inset)
    let screenInset: CGFloat = 16
    let screenRect = monitorRect.insetBy(dx: screenInset, dy: screenInset)
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.addPath(screenPath)
    ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
    ctx.fillPath()

    // Screen gradient (subtle blue sheen)
    ctx.addPath(screenPath)
    ctx.clip()
    let screenGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.1, green: 0.15, blue: 0.3, alpha: 1),
        CGColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(screenGradient, start: CGPoint(x: screenRect.midX, y: screenRect.minY), end: CGPoint(x: screenRect.midX, y: screenRect.maxY), options: [])

    // Play triangle on screen
    ctx.resetClip()
    ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: CGColor(gray: 0, alpha: 0.4))
    let playSize: CGFloat = 140
    let playCenterX = rect.midX
    let playCenterY = monitorRect.midY + 20
    let playPath = CGMutablePath()
    playPath.move(to: CGPoint(x: playCenterX - playSize * 0.4, y: playCenterY - playSize * 0.5))
    playPath.addLine(to: CGPoint(x: playCenterX - playSize * 0.4, y: playCenterY + playSize * 0.5))
    playPath.addLine(to: CGPoint(x: playCenterX + playSize * 0.45, y: playCenterY))
    playPath.closeSubpath()
    ctx.addPath(playPath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.fillPath()

    // Stand
    ctx.setShadow(offset: .zero, blur: 0)
    let standW: CGFloat = 40
    let standH: CGFloat = 80
    let standX = rect.midX - standW / 2
    let standY = monitorRect.minY - standH
    ctx.fill(CGRect(x: standX, y: standY, width: standW, height: standH))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1))
    ctx.fill(CGRect(x: standX + 10, y: standY, width: standW - 20, height: standH))

    // Base
    let baseW: CGFloat = 100
    let baseH: CGFloat = 16
    let baseX = rect.midX - baseW / 2
    let baseY = standY - baseH
    let basePath = CGPath(roundedRect: CGRect(x: baseX, y: baseY, width: baseW, height: baseH), cornerWidth: 8, cornerHeight: 8, transform: nil)
    ctx.addPath(basePath)
    ctx.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.3, alpha: 1))
    ctx.fillPath()

    image.unlockFocus()
    return image
}

// Save as PNG
let icon = makeIcon()
let outputPath = CommandLine.arguments[1]
let rep = NSBitmapImageRep(data: icon.tiffRepresentation!)!
let pngData = rep.representation(using: .png, properties: [:])!
try! pngData.write(to: URL(fileURLWithPath: outputPath))
print("Icon generated: \(outputPath)")
