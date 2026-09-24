// make-icon —— 把一张方形设计稿裁成符合 macOS 规范的应用图标。
//
// 用法：swift Tools/make-icon.swift
//   Resources/AppIcon-source.png  →  build/AppIcon.iconset/  →  Resources/AppIcon.icns
//
// 为什么要这一步，而不是直接把原图丢给 iconutil：
// macOS Big Sur 起的图标有自己的网格——内容占画布的 824/1024（约 80.5%），四周各留
// 约 9.8% 的空白，圆角画在内容里。设计稿通常内容占得更大（这张是 85%），直接打包出来
// 会比 Dock 里其它图标大一圈，一眼就能看出不齐。所以这里量出内容边界，按统一比例
// 缩到规范尺寸再居中。
//
// 顺带处理蒙版：设计稿已经是透明背景的圆角方块，不需要抠图，只要按内容边界裁掉多余空白。

import AppKit
import CoreGraphics
import Foundation

// MARK: - 参数

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Resources/AppIcon-source.png")
let iconsetURL = root.appendingPathComponent("build/AppIcon.iconset")
let outputURL = root.appendingPathComponent("Resources/AppIcon.icns")

/// macOS 图标内容应占画布的比例：824 / 1024 ≈ 0.8047
let contentRatio: CGFloat = 824.0 / 1024.0

/// 小于等于这个像素尺寸就用**简化版**。
///
/// 完整设计稿里「金色圆角方块 + 奶油便签卡 + 褐色 # + 方糖」四层在小尺寸下会糊成一团：
/// 16px 时 # 只剩一个褐色模糊团。所以最小的那几个尺寸只保留主干——金色方块 + 放大的 #，
/// 保证轮廓和识别度。配色从原图采样，保证和完整版是同一套色。
let simplifiedUpToPixelSize = 32

/// 简化版配色，取自原图采样：外圈金色自上而下（#F5EFDE → #F8DEA5 → #F4C164），
/// 以及 # 的褐色（#613514 / #693E1F / #673A1B 取样后取中）。
let goldTop = CGColor(red: 0xF5 / 255, green: 0xEF / 255, blue: 0xDE / 255, alpha: 1)
let goldMiddle = CGColor(red: 0xF8 / 255, green: 0xDE / 255, blue: 0xA5 / 255, alpha: 1)
let goldBottom = CGColor(red: 0xE8 / 255, green: 0xBC / 255, blue: 0x6B / 255, alpha: 1)
let markBrown = CGColor(red: 0x66 / 255, green: 0x39 / 255, blue: 0x1A / 255, alpha: 1)

/// .iconset 需要的全部尺寸。名字是 iconutil 认的死格式，不能改。
let variants: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// MARK: - 读源图

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    FileHandle.standardError.write("读不到 \(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let sourceWidth = source.width
let sourceHeight = source.height
print("源图 \(sourceWidth)x\(sourceHeight)")

/// 把 CGImage 画进 RGBA 缓冲，方便逐像素读。
func pixels(of image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &buffer, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return buffer
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

/// 不透明内容的边界。设计稿四周可能有透明留白，要按实际内容对齐规范网格。
func contentBounds(of image: CGImage) -> CGRect {
    let width = image.width
    let height = image.height
    let data = pixels(of: image)
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where data[(y * width + x) * 4 + 3] > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return CGRect(x: 0, y: 0, width: width, height: height) }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let bounds = contentBounds(of: source)
print("内容边界 \(Int(bounds.width))x\(Int(bounds.height)) "
      + "（占画布 \(String(format: "%.1f%%", Double(bounds.width) / Double(sourceWidth) * 100))，"
      + "规范要求 \(String(format: "%.1f%%", contentRatio * 100))）")

guard let croppedSource = source.cropping(to: bounds) else {
    FileHandle.standardError.write("裁剪失败\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - 生成各尺寸

try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

/// 把一个尺寸画出来：内容按 contentRatio 缩放居中，画布其余部分保持透明。
func render(side: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    context.interpolationQuality = .high

    // 内容的边长按长边算，保持设计稿的宽高比
    let contentSide = CGFloat(side) * contentRatio
    let scale = contentSide / max(bounds.width, bounds.height)
    let drawWidth = bounds.width * scale
    let drawHeight = bounds.height * scale
    let rect = CGRect(x: (CGFloat(side) - drawWidth) / 2,
                      y: (CGFloat(side) - drawHeight) / 2,
                      width: drawWidth, height: drawHeight)
    context.draw(croppedSource, in: rect)
    return context.makeImage()
}

/// 简化版：金色圆角方块 + 放大的褐色 #。
func renderSimplified(side: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    let canvas = CGFloat(side)
    let tile = canvas * contentRatio
    let origin = (canvas - tile) / 2
    let cornerRadius = tile * 0.2237   // Apple 图标圆角比例（连续圆角近似）

    let squircle = CGPath(roundedRect: CGRect(x: origin, y: origin, width: tile, height: tile),
                          cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [goldTop, goldMiddle, goldBottom] as CFArray,
                                 locations: [0, 0.55, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: canvas),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
    }
    context.restoreGState()

    // # 的大小按方块边长取。0.68 是试出来的：再大就在 16px 下贴边、笔画糊在一起，
    // 再小则在 16px 下认不出是 #。
    let fontSize = tile * 0.68
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: markBrown) ?? .brown,
    ]
    let text = NSAttributedString(string: "#", attributes: attributes)
    let textSize = text.size()
    let textOrigin = CGPoint(x: (canvas - textSize.width) / 2,
                             y: (canvas - textSize.height) / 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    text.draw(at: textOrigin)
    NSGraphicsContext.restoreGraphicsState()

    return context.makeImage()
}

for variant in variants {
    guard let image = (variant.size <= simplifiedUpToPixelSize
                       ? renderSimplified(side: variant.size)
                       : render(side: variant.size)),
          let destination = CGImageDestinationCreateWithURL(
            iconsetURL.appendingPathComponent(variant.name) as CFURL, "public.png" as CFString, 1, nil)
    else {
        FileHandle.standardError.write("生成 \(variant.name) 失败\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write("写入 \(variant.name) 失败\n".data(using: .utf8)!)
        exit(1)
    }
}
let simplified = variants.filter { $0.size <= simplifiedUpToPixelSize }.map(\.name)
print("已生成 \(variants.count) 个尺寸到 \(iconsetURL.path)")
print("  其中 \(simplified.count) 个用简化版（≤\(simplifiedUpToPixelSize)px）：\(simplified.joined(separator: ", "))")

// MARK: - 打包成 .icns

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}

let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
let byteSize = (attributes?[.size] as? Int) ?? 0
print("已写入 \(outputURL.path)（\(byteSize / 1024) KB）")
