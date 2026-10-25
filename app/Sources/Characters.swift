import AppKit

// Historical case names are internal preference values only. The public build
// offers one original, code-drawn character and bundles no third-party art.
enum PetCharacter: String, CaseIterable {
    case portrait, blueberry, chibi
    static let allCases: [PetCharacter] = [.chibi]
    var title: String { L("小团 · 原创伙伴", "Mochi · Original companion") }
    var minimumHeight: CGFloat { 140 }
    var maximumHeight: CGFloat { 360 }
    var defaultHeight: CGFloat { 220 }
    var heightKey: String { "companionHeight" }
    func clampedHeight(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultHeight }
        return min(maximumHeight, max(minimumHeight, value))
    }
    func jumpHeight(for height: CGFloat) -> CGFloat { min(32, height * 0.12) }
    func headroom(for height: CGFloat) -> CGFloat { 0 }
    func sidePadding(for width: CGFloat) -> CGFloat { 0 }
}

struct ChibiArtwork {
    static let canvasSize = NSSize(width: 256, height: 300)
    let standing: NSImage
    let left: [NSImage]
    let right: [NSImage]
    static func load(resourceURL: URL) -> ChibiArtwork? {
        ChibiArtwork(standing: OriginalArtwork.image(),
            left: (0..<8).map { OriginalArtwork.image(facing: -1, phase: Double($0) * .pi / 4) },
            right: (0..<8).map { OriginalArtwork.image(facing: 1, phase: Double($0) * .pi / 4) })
    }
    func image(for pose: PetRoamPose) -> NSImage {
        switch pose {
        case .standing: return standing
        case let .walking(facing, frame):
            let frames = facing == .left ? left : right
            return frames.indices.contains(frame) ? frames[frame] : standing
        }
    }
}

/// Mochi: an original mint-and-cream seedling companion. All shapes below are
/// authored for this project and licensed under MIT with the application code.
/// Frames are rendered once at 3x resolution; idle rendering needs no draw loop.
enum OriginalArtwork {
    static func image(facing: Int = 0, phase: Double = 0, blink: Bool = false) -> NSImage {
        let size = ChibiArtwork.canvasSize, scale: CGFloat = 3
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width*scale),pixelsHigh:Int(size.height*scale),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
        let mint=NSColor(calibratedRed:0.27,green:0.65,blue:0.57,alpha:1)
        let dark=NSColor(calibratedRed:0.15,green:0.35,blue:0.32,alpha:1)
        let cream=NSColor(calibratedRed:1,green:0.96,blue:0.83,alpha:1)
        let light=NSColor(calibratedRed:0.69,green:0.87,blue:0.71,alpha:1)
        let peach=NSColor(calibratedRed:0.96,green:0.66,blue:0.47,alpha:1)
        let step:CGFloat = facing == 0 ? 0:CGFloat(sin(phase))
        let bounce:CGFloat = facing == 0 ? 0:abs(CGFloat(cos(phase)))*3
        let look = CGFloat(facing)*12
        func oval(_ rect:NSRect,_ color:NSColor){color.setFill();NSBezierPath(ovalIn:rect).fill()}
        func round(_ rect:NSRect,_ radius:CGFloat,_ color:NSColor){color.setFill();NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill()}
        func line(_ points:[NSPoint],_ color:NSColor,_ width:CGFloat){let p=NSBezierPath();p.move(to:points[0]);for q in points.dropFirst(){p.line(to:q)};p.lineWidth=width;p.lineCapStyle = .round;color.setStroke();p.stroke()}
        // Ground contact follows the planted foot; shadows never change position.
        oval(NSRect(x:52,y:8,width:152,height:17),dark.withAlphaComponent(0.13))
        let leftX:CGFloat=77-step*12, rightX:CGFloat=145+step*12
        let leftY:CGFloat=14+max(0,step)*10,rightY:CGFloat=14+max(0,-step)*10
        round(NSRect(x:leftX,y:leftY,width:36,height:28),13,mint)
        round(NSRect(x:rightX,y:rightY,width:36,height:28),13,mint)
        // Arms oppose the same-side foot through a half-cycle phase offset.
        oval(NSRect(x:27+step*6,y:85-step*12+bounce,width:35,height:54),mint)
        oval(NSRect(x:194-step*6,y:85+step*12+bounce,width:35,height:54),mint)
        let body=NSBezierPath(roundedRect:NSRect(x:43,y:27+bounce,width:170,height:202),xRadius:79,yRadius:79)
        cream.setFill();body.fill();dark.withAlphaComponent(0.75).setStroke();body.lineWidth=3;body.stroke()
        // Soft mint cap and two asymmetric leaves make a seedling silhouette.
        let cap=NSBezierPath();cap.move(to:NSPoint(x:58,y:192+bounce));cap.curve(to:NSPoint(x:198,y:192+bounce),controlPoint1:NSPoint(x:66,y:254+bounce),controlPoint2:NSPoint(x:183,y:254+bounce));cap.curve(to:NSPoint(x:58,y:192+bounce),controlPoint1:NSPoint(x:166,y:213+bounce),controlPoint2:NSPoint(x:91,y:210+bounce));cap.close();mint.setFill();cap.fill()
        line([NSPoint(x:126,y:225+bounce),NSPoint(x:127,y:255+bounce)],dark,5)
        let leaf=NSBezierPath();leaf.move(to:NSPoint(x:126,y:251+bounce));leaf.curve(to:NSPoint(x:86,y:283+bounce),controlPoint1:NSPoint(x:89,y:247+bounce),controlPoint2:NSPoint(x:82,y:267+bounce));leaf.curve(to:NSPoint(x:126,y:251+bounce),controlPoint1:NSPoint(x:118,y:286+bounce),controlPoint2:NSPoint(x:135,y:270+bounce));mint.setFill();leaf.fill()
        let leaf2=NSBezierPath();leaf2.move(to:NSPoint(x:128,y:251+bounce));leaf2.curve(to:NSPoint(x:169,y:275+bounce),controlPoint1:NSPoint(x:127,y:274+bounce),controlPoint2:NSPoint(x:149,y:284+bounce));leaf2.curve(to:NSPoint(x:128,y:251+bounce),controlPoint1:NSPoint(x:167,y:251+bounce),controlPoint2:NSPoint(x:146,y:245+bounce));light.setFill();leaf2.fill()
        line([NSPoint(x:130,y:253+bounce),NSPoint(x:154,y:267+bounce)],dark.withAlphaComponent(0.35),2)
        // Face turns toward actual travel. The cap has no mirrored costume cues.
        for x:CGFloat in [95+look,153+look] {
            if blink {line([NSPoint(x:x-6,y:156+bounce),NSPoint(x:x+6,y:156+bounce)],dark,4)}
            else {oval(NSRect(x:x-5,y:150+bounce,width:10,height:15),dark);oval(NSRect(x:x-2,y:159+bounce,width:3,height:4),.white)}
        }
        oval(NSRect(x:70+look,y:131+bounce,width:24,height:12),peach.withAlphaComponent(0.65))
        oval(NSRect(x:160+look,y:131+bounce,width:24,height:12),peach.withAlphaComponent(0.65))
        let smile=NSBezierPath();smile.move(to:NSPoint(x:117+look,y:139+bounce));smile.curve(to:NSPoint(x:133+look,y:139+bounce),controlPoint1:NSPoint(x:122+look,y:132+bounce),controlPoint2:NSPoint(x:128+look,y:132+bounce));smile.lineWidth=3;smile.lineCapStyle = .round;dark.setStroke();smile.stroke()
        // A tiny seed on the belly, no lettering or third-party insignia.
        oval(NSRect(x:112,y:65+bounce,width:31,height:40),light.withAlphaComponent(0.6))
        line([NSPoint(x:127,y:72+bounce),NSPoint(x:127,y:96+bounce)],mint.withAlphaComponent(0.6),2)
        NSGraphicsContext.restoreGraphicsState()
        let image=NSImage(size:size);image.addRepresentation(rep);return image
    }
}

func blueberryDisplayImage(_ image:NSImage)->NSImage? { image }
