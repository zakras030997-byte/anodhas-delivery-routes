import AppKit
import Foundation
let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {for scale in [1,2] {
    let n=size*scale
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:n,pixelsHigh:n,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    rep.size=NSSize(width:n,height:n)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    let c=NSGraphicsContext.current!.cgContext;c.scaleBy(x:CGFloat(n)/512,y:CGFloat(n)/512)
    NSColor(calibratedRed:0.10,green:0.13,blue:0.18,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:20,y:20,width:472,height:472),xRadius:108,yRadius:108).fill()
    NSColor(calibratedRed:1,green:0.64,blue:0.21,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:86,y:185,width:220,height:160),xRadius:20,yRadius:20).fill()
    let cabin=NSBezierPath();cabin.move(to:NSPoint(x:318,y:185));cabin.line(to:NSPoint(x:425,y:185));cabin.line(to:NSPoint(x:425,y:270));cabin.line(to:NSPoint(x:382,y:319));cabin.line(to:NSPoint(x:318,y:319));cabin.close();cabin.fill()
    NSColor(calibratedWhite:0.15,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:336,y:260,width:46,height:36),xRadius:5,yRadius:5).fill()
    for x in [151.0,359.0] {NSColor(calibratedWhite:0.06,alpha:1).setFill();NSBezierPath(ovalIn:NSRect(x:x-29,y:155,width:58,height:58)).fill();NSColor.white.setFill();NSBezierPath(ovalIn:NSRect(x:x-12,y:172,width:24,height:24)).fill()}
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("icon_\(size)x\(size)\(scale==2 ? "@2x" : "").png"))
}}
