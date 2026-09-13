import Foundation
import AppKit

/// 程序化生成 MacZip App 图标 (1024×1024 PNG)。
/// 视觉:macOS 风格圆角方块 + 蓝色渐变 + 中央拉链纹理 + 拉头,呼应"压缩"主题。
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocusFlipped(false)

guard let context = NSGraphicsContext.current?.cgContext else {
    FileHandle.standardError.write(Data("无法创建图形上下文\n".utf8))
    exit(1)
}

let inset: CGFloat = 100
let tileSize = size - inset * 2
let tileRect = CGRect(x: inset, y: inset, width: tileSize, height: tileSize)
let cornerRadius: CGFloat = 180

// 1. 圆角方块底板 + 蓝色渐变。
let path = CGPath(roundedRect: tileRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
context.addPath(path)
context.clip()

let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.22, green: 0.52, blue: 0.98, alpha: 1.0),
        CGColor(red: 0.10, green: 0.32, blue: 0.86, alpha: 1.0)
    ] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
    end: CGPoint(x: tileRect.midX, y: tileRect.minY),
    options: []
)

// 2. 顶部高光 (渐变淡出,无硬接缝)。
let highlightGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(
    highlightGradient,
    start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
    end: CGPoint(x: tileRect.midX, y: tileRect.minY),
    options: []
)

// 3. 中央拉链齿 (交错的白色圆角矩形)。
let teethCount = 10
let teethWidth: CGFloat = 150
let teethHeight: CGFloat = 34
let teethGap: CGFloat = 8
let centerX = tileRect.midX
var toothY = tileRect.maxY - 210
for index in 0..<teethCount {
    let offset: CGFloat = (index % 2 == 0) ? -teethWidth / 2 : 0
    let toothRect = CGRect(
        x: centerX + offset,
        y: toothY - teethHeight,
        width: teethWidth,
        height: teethHeight
    )
    let toothPath = CGPath(roundedRect: toothRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: index == 0 ? 0.95 : 0.85))
    context.addPath(toothPath)
    context.fillPath()
    toothY -= (teethHeight + teethGap)
}

// 4. 拉链拉头 (半透明圆角块 + 拉环)。
let sliderRect = CGRect(x: centerX - 110, y: toothY - 20, width: 220, height: 130)
let sliderPath = CGPath(roundedRect: sliderRect, cornerWidth: 34, cornerHeight: 34, transform: nil)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
context.addPath(sliderPath)
context.fillPath()
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
context.setLineWidth(16)
context.addPath(sliderPath)
context.strokePath()

// 拉环:圆角矩形环。
let ringRect = CGRect(x: centerX - 46, y: sliderRect.minY - 110, width: 92, height: 100)
let ringPath = CGPath(
    roundedRect: ringRect,
    cornerWidth: 40, cornerHeight: 40,
    transform: nil
)
context.setLineWidth(20)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
context.addPath(ringPath)
context.strokePath()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.png")
try! png.write(to: output)
print("图标已生成: \(output.path)")
