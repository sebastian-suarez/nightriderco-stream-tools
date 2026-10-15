import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("outputs/NIGHTRIDERCO/03_OBS/transitions")
let scratch = root.appendingPathComponent("work/native_motion60")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let destination = out.appendingPathComponent("nightriderco-ice-wipe-QHD-60fps-alpha.mov")
// Preserve previous versions; this renderer only writes new PNG frames.
let width = 2560, height = 1440, fps: Int32 = 60, frames = 72
let space = CGColorSpaceCreateDeviceRGB()
let slate = CGColor(red: 11/255, green: 17/255, blue: 24/255, alpha: 1)
let steel = CGColor(red: 21/255, green: 35/255, blue: 48/255, alpha: 1)
let ice = CGColor(red: 116/255, green: 223/255, blue: 1, alpha: 1)
let snow = CGColor(red: 241/255, green: 246/255, blue: 248/255, alpha: 1)
func ease(_ t: Double) -> Double { return t*t*(3 - 2*t) }
func saveImage(_ image: CGImage, _ url: URL) {
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Cannot create PNG") }
    CGImageDestinationAddImage(dst, image, nil)
    guard CGImageDestinationFinalize(dst) else { fatalError("Cannot save PNG") }
}
func polygon(_ c: CGContext, _ p: [CGPoint], _ color: CGColor) {
    c.beginPath(); c.move(to:p[0]); for v in p.dropFirst() { c.addLine(to:v) }; c.closePath()
    c.setFillColor(color); c.fillPath()
}
func render(_ c: CGContext, _ index: Int) {
    c.clear(CGRect(x:0,y:0,width:width,height:height))
    if index == 0 { return }
    let time = Double(index) / Double(fps)
    let h = Double(height), w = Double(width), skew = 520.0
    let arrival = time < 0.45
    let departure = time >= 0.75
    var left = -skew-100, right = w+skew+100
    if arrival { right = -skew-120 + (w+2*skew+240)*ease(min(1, max(0, time/0.45))) }
    if departure { left = -skew-120 + (w+2*skew+240)*ease(min(1, max(0, (time-0.75)/0.35))) }
    let shape = [CGPoint(x:left-skew/2,y:0), CGPoint(x:right-skew/2,y:0), CGPoint(x:right+skew/2,y:h), CGPoint(x:left+skew/2,y:h)]
    c.saveGState(); c.beginPath(); c.addLines(between:shape); c.closePath(); c.clip()
    c.setFillColor(slate); c.fill(CGRect(x:0,y:0,width:width,height:height))
    polygon(c,[CGPoint(x:w*0.38,y:0),CGPoint(x:w*0.73,y:0),CGPoint(x:w*0.92,y:h),CGPoint(x:w*0.57,y:h)],steel)
    polygon(c,[CGPoint(x:-300,y:0),CGPoint(x:230,y:0),CGPoint(x:w*0.30,y:h),CGPoint(x:0,y:h)],steel)
    c.setStrokeColor(CGColor(red:116/255,green:223/255,blue:1,alpha:0.10));c.setLineWidth(2)
    for x in stride(from: -500.0, through: w+500, by: 320) {
        c.beginPath();c.move(to:CGPoint(x:x,y:0));c.addLine(to:CGPoint(x:x+skew,y:h));c.strokePath()
    }
    // The leading edge is a solid ice blade. The cover is opaque at the cut point.
    let edge = departure ? left+54 : right // accents stay on the moving boundary; offscreen during hold
    let band = 42.0
    polygon(c,[CGPoint(x:edge-skew/2-band,y:0),CGPoint(x:edge-skew/2,y:0),CGPoint(x:edge+skew/2,y:h),CGPoint(x:edge+skew/2-band,y:h)],ice)
    polygon(c,[CGPoint(x:edge-skew/2-band-12,y:0),CGPoint(x:edge-skew/2-band-6,y:0),CGPoint(x:edge+skew/2-band-6,y:h),CGPoint(x:edge+skew/2-band-12,y:h)],snow)
    c.restoreGState()
}
let frameFolder=scratch.appendingPathComponent("frames")
try FileManager.default.createDirectory(at:frameFolder,withIntermediateDirectories:true)
for i in 0..<frames {
    let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
    render(ctx,i)
    let img=ctx.makeImage()!
    saveImage(img,frameFolder.appendingPathComponent(String(format:"frame-%03d.png",i)))
}
print("Rendered 72 RGBA frames, 2560 x 1440, 60 fps")
