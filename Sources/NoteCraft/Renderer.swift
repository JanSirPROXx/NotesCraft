import SwiftUI
import PDFKit
import NoteCraftCore
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

@MainActor enum PageRenderer {
    static func color(_ ink: InkColor, alpha: Double = 1) -> CGColor { CGColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: alpha) }
    static func render(_ page: Page, assets: [String: Data], in c: CGContext) {
        let size = page.dimensions
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: size.x, height: size.y))
        if let name = page.backgroundPDF, let data = assets[name], let pdf = CGPDFDocument(CGDataProvider(data: data as CFData)!), let p = pdf.page(at: (page.backgroundPage ?? 0) + 1) {
            c.saveGState(); c.translateBy(x: 0, y: size.y); c.scaleBy(x: 1, y: -1)
            c.concatenate(p.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: size.x, height: size.y), rotate: 0, preserveAspectRatio: true)); c.drawPDFPage(p); c.restoreGState()
        } else { paper(page.paper, in: c) }
        for image in page.images {
            guard let data = assets[image.filename], let source = CGImageSourceCreateWithData(data as CFData, nil), let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let r = image.frame
            c.saveGState(); c.translateBy(x: r.x + r.width / 2, y: r.y + r.height / 2); c.rotate(by: image.rotation); c.scaleBy(x: 1, y: -1)
            c.draw(bitmap, in: CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height)); c.restoreGState()
        }
        for s in page.strokes.filter({ $0.tool == .highlighter }) + page.strokes.filter({ $0.tool != .highlighter }) { stroke(s, in: c) }
        for text in page.texts {
            #if os(macOS)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: text.size), .foregroundColor: NSColor(cgColor: color(text.color)) ?? .black]
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
            (text.text as NSString).draw(in: CGRect(x: text.origin.x, y: text.origin.y, width: size.x - text.origin.x - 16, height: size.y - text.origin.y), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            #else
            UIGraphicsPushContext(c)
            (text.text as NSString).draw(in: CGRect(x: text.origin.x, y: text.origin.y, width: size.x - text.origin.x - 16, height: size.y - text.origin.y), withAttributes: [.font: UIFont.systemFont(ofSize: text.size), .foregroundColor: UIColor(cgColor: color(text.color))])
            UIGraphicsPopContext()
            #endif
        }
    }
    static func paper(_ paper: Paper, in c: CGContext) {
        let size = paper.dimensions
        c.setStrokeColor(CGColor(red: 0.79, green: 0.83, blue: 0.88, alpha: 0.65)); c.setLineWidth(0.5)
        switch paper.pattern {
        case .blank: break
        case .ruled, .squared:
            for y in stride(from: 52.0, to: size.y - 20, by: 24) { c.move(to: CGPoint(x: 24, y: y)); c.addLine(to: CGPoint(x: size.x - 24, y: y)) }
            if paper.pattern == .squared { for x in stride(from: 24.0, to: size.x - 20, by: 24) { c.move(to: CGPoint(x: x, y: 28)); c.addLine(to: CGPoint(x: x, y: size.y - 20)) } }
            c.strokePath()
        case .dotted:
            c.setFillColor(CGColor(gray: 0.7, alpha: 0.65))
            for y in stride(from: 28.0, to: size.y - 20, by: 20) { for x in stride(from: 24.0, to: size.x - 20, by: 20) { c.fillEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5)) } }
        case .planner:
            for i in 0..<7 { c.stroke(CGRect(x: 28, y: 60 + Double(i) * (size.y - 88) / 7, width: size.x - 56, height: (size.y - 88) / 7)) }
        }
    }
    static func stroke(_ s: Stroke, in c: CGContext) {
        guard let first = s.samples.first else { return }
        c.saveGState(); c.setLineCap(.round); c.setLineJoin(.round)
        let alpha = s.tool == .highlighter ? 0.3 : 1.0
        if s.tool == .highlighter {
            c.setAlpha(alpha); c.beginTransparencyLayer(auxiliaryInfo: nil)
            c.setStrokeColor(color(s.color)); c.setLineWidth(s.width)
            c.move(to: CGPoint(x: first.point.x, y: first.point.y))
            for sample in s.samples.dropFirst() { c.addLine(to: CGPoint(x: sample.point.x, y: sample.point.y)) }; c.strokePath()
            c.endTransparencyLayer()
        } else {
            c.setStrokeColor(color(s.color)); c.setFillColor(color(s.color))
            if s.samples.count == 1 { c.fillEllipse(in: CGRect(x: first.point.x - s.width / 2, y: first.point.y - s.width / 2, width: s.width, height: s.width)) }
            for (a, b) in zip(s.samples, s.samples.dropFirst()) {
                let pressure = s.style == .ballpoint ? 1 : max(0.2, (a.pressure + b.pressure) / 2)
                c.setLineWidth(s.width * pressure * (s.style == .brush ? 1.7 : 1))
                c.move(to: CGPoint(x: a.point.x, y: a.point.y)); c.addLine(to: CGPoint(x: b.point.x, y: b.point.y)); c.strokePath()
            }
        }
        c.restoreGState()
    }
    static func export(_ package: NotebookPackage) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let c = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw PackageError.invalidPackage }
        for page in package.notebook.pages {
            let size = page.dimensions
            c.beginPDFPage([kCGPDFContextMediaBox as String: CGRect(x: 0, y: 0, width: size.x, height: size.y)] as CFDictionary)
            c.saveGState(); c.translateBy(x: 0, y: size.y); c.scaleBy(x: 1, y: -1); render(page, assets: package.assets, in: c); c.restoreGState(); c.endPDFPage()
        }
        c.closePDF(); return data as Data
    }
    static func importPDF(_ data: Data) throws -> [Page] {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw PackageError.invalidPackage }
        return (0..<pdf.pageCount).map { index in
            var page = Page(paper: Paper(pattern: .blank)); page.backgroundPage = index
            if let bounds = pdf.page(at: index)?.bounds(for: .mediaBox) { page.backgroundSize = Point(bounds.width, bounds.height) }
            return page
        }
    }
}
