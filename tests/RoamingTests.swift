import Foundation
import CoreGraphics

@main struct RoamingTests {
    static func main() {
        var checks = 0
        func check(_ test: @autoclosure () -> Bool, _ name: String) { precondition(test(), name); checks += 1 }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a-b) < 0.000_01 }
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1000)
        let size = CGSize(width: 156, height: 220)
        var e = PetRoamEngine(ground: CGPoint(x:-960,y:100),visibleFrame:screen,artworkSize:size)
        check(e.pose == .standing && !e.isWalking,"default standing")
        check(close(e.ground.y,screen.minY+14),"horizontal ground at visible bottom")
        e.begin(direction:CGVector(dx:-1,dy:0),duration:3)
        check(e.pose == .standing && e.facing == .right,"no facing change before actual movement")
        let before=e.ground;let moved=e.advance(dt:0.1)
        check(close(moved,4.2) && close(before.x-e.ground.x,moved),"actual left distance")
        check(e.facing == .left,"left from actual dx")
        if case .walking(let face,let frame)=e.pose {check(face == .left && (0..<8).contains(frame),"left pose frame")} else {preconditionFailure("walking pose")}
        check(close(e.phase,moved/(size.height*0.34)),"phase from actual distance")
        let stopped=e.ground;e.stop();_ = e.advance(dt:10)
        check(e.pose == .standing && e.ground == stopped,"stop standing, no movement")
        e.configure(ground:CGPoint(x:-950,y:100),visibleFrame:screen,artworkSize:size,mode:.free)
        e.begin(direction:CGVector(dx:0,dy:1),duration:2);let vy=e.ground.y;_ = e.advance(dt:0.1)
        check(e.facing == .left && close(e.ground.y-vy,4.2),"vertical retains left")
        e.stop();e.begin(direction:CGVector(dx:1,dy:-1),duration:3);let diag=e.ground;_ = e.advance(dt:0.1)
        check(close(hypot(e.ground.x-diag.x,e.ground.y-diag.y),4.2),"diagonal normalized")
        check(e.facing == .right,"diagonal maps right")
        e.configure(ground:CGPoint(x:10000,y:10000),visibleFrame:screen,artworkSize:size,mode:.free)
        check(e.ground.x == e.groundBounds.maxX && e.ground.y == e.groundBounds.maxY,"outside position clamped")
        check(e.availableDirections.count == 3,"top right excludes outward vectors")
        e.begin(direction:CGVector(dx:1,dy:0),duration:2);check(!e.isWalking,"outward wall direction refuses")
        e.configure(ground:CGPoint(x:e.groundBounds.maxX-1,y:100),visibleFrame:screen,artworkSize:size,mode:.free)
        e.begin(direction:CGVector(dx:1,dy:0),duration:2);let edgeMove=e.advance(dt:0.1)
        check(close(edgeMove,1) && e.pose == .standing,"boundary uses actual distance and stands")
        check(close(e.phase,1/(size.height*0.34)),"boundary does not advance planned full stride")
        e.configure(ground:CGPoint(x:-960,y:100),visibleFrame:screen,artworkSize:size,mode:.free)
        e.begin(direction:CGVector(dx:1,dy:0),duration:2);let stalled=e.ground;_ = e.advance(dt:100)
        check(close(e.ground.x-stalled.x,42*0.2) && !e.isWalking,"stall cap and expiry")
        e.begin(direction:CGVector(dx:1,dy:0),duration:0.05);_ = e.advance(dt:0.1)
        check(!e.isWalking && e.pose == .standing,"finite leg ends standing")
        let saved=e.ground;e.begin(direction:CGVector(dx:CGFloat.nan,dy:0),duration:3)
        check(!e.isWalking && e.ground == saved,"nonfinite direction rejected")
        e.begin(direction:CGVector(dx:0,dy:0),duration:3);check(!e.isWalking,"zero vector rejected")
        for h:CGFloat in [140,220,360] {
            e.configure(ground:CGPoint(x:-10000,y:-10000),visibleFrame:screen,artworkSize:CGSize(width:h*256/360,height:h),mode:.free)
            check(e.ground.x-e.artworkSize.width/2 >= screen.minX && e.ground.y >= screen.minY,"size fits lower bounds")
            e.begin(direction:CGVector(dx:1,dy:1),duration:15)
            for _ in 0..<200 {_ = e.advance(dt:0.1)}
            check(e.ground.x+e.artworkSize.width/2<=screen.maxX+0.001 && e.ground.y+h<=screen.maxY+0.001,"size stays upper bounds")
        }
        e.configure(ground:.zero,visibleFrame:CGRect(x:0,y:0,width:80,height:80),artworkSize:size,mode:.free)
        check(!e.fitsVisibleFrame && e.availableDirections.isEmpty,"too small screen disables movement")
        e.begin(direction:CGVector(dx:1,dy:0),duration:3);check(!e.isWalking,"oversize cannot roam")
        e.configure(ground:CGPoint(x:CGFloat.nan,y:CGFloat.infinity),visibleFrame:screen,artworkSize:size,mode:.free,speed:CGFloat.nan)
        check(e.ground.x.isFinite && e.ground.y.isFinite && e.speed == 42,"finite fallback state")
        check(e.availableDirections.allSatisfy { $0.dx != 0 || $0.dy != 0 },"no zero candidate")
        let controller=PetRoamController();controller.start(engine:e)
        check(controller.isRunning && controller.hasMovementTimer && !controller.hasIdleTimer,"movement timer only")
        controller.stop()
        check(!controller.isRunning && !controller.hasTimers && controller.engine?.pose == .standing,"synchronous stop cancels timers")
        var updates=0
        controller.onUpdate={ state in if state.isWalking {updates += 1;controller.stop()} }
        controller.start(engine:e)
        RunLoop.main.run(until:Date().addingTimeInterval(0.18))
        check(updates==1 && !controller.hasTimers && !controller.isRunning,"callback stop cannot resurrect idle timer")
        controller.onUpdate=nil
        controller.start(engine:e)
        RunLoop.main.run(until:Date().addingTimeInterval(5.4))
        check(controller.isRunning && !controller.isWalking && controller.hasIdleTimer && !controller.hasMovementTimer,"rest uses only one-shot timer")
        check(controller.engine?.pose == .standing,"rest standing")
        controller.stop()
        check(!controller.hasTimers && !controller.isRunning,"rest timer fully cancelled")
        print("PASS \(checks) roaming assertions")
    }
}
