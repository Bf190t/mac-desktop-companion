import AppKit
import Foundation

private final class ZoomDelegate: NSObject, NSWindowDelegate {
    var requestedStandardFrame: NSRect?
    func windowWillUseStandardFrame(_ window:NSWindow, defaultFrame:NSRect)->NSRect {
        let result=DesktopWindowBehavior.standardFrame(for:window,defaultFrame:defaultFrame)
        requestedStandardFrame=result
        return result
    }
}

@main
struct WindowBehaviorTests {
    static func main() {
        var checks:[String:Bool]=[:]
        func check(_ name:String,_ value:Bool){checks[name]=value}
        func near(_ lhs:NSRect,_ rhs:NSRect)->Bool {
            abs(lhs.origin.x-rhs.origin.x)<1 && abs(lhs.origin.y-rhs.origin.y)<1 && abs(lhs.width-rhs.width)<1 && abs(lhs.height-rhs.height)<1
        }
        func inside(_ frame:NSRect,_ visible:NSRect)->Bool {
            frame.minX>=visible.minX-0.01 && frame.minY>=visible.minY-0.01 && frame.maxX<=visible.maxX+0.01 && frame.maxY<=visible.maxY+0.01
        }
        let visible=NSRect(x:0,y:38,width:1440,height:830)
        let preserved=NSRect(x:120,y:160,width:500,height:550)
        check("already_visible_frame_preserved",near(DesktopWindowBehavior.constrainedFrame(preserved,visibleFrame:visible),preserved))
        let oversized=NSRect(x:-250,y:-400,width:2600,height:1800)
        let reduced=DesktopWindowBehavior.constrainedFrame(oversized,visibleFrame:visible)
        check("oversized_window_shrinks_to_display",near(reduced,visible))
        let outside=NSRect(x:1800,y:1000,width:440,height:530)
        let clamped=DesktopWindowBehavior.constrainedFrame(outside,visibleFrame:visible)
        check("offscreen_origin_clamped",inside(clamped,visible) && clamped.size == outside.size)
        let negativeScreen=NSRect(x:-1920,y:-1080,width:1920,height:1056)
        let negativeWindow=NSRect(x:-2500,y:-1700,width:430,height:550)
        let negativeResult=DesktopWindowBehavior.constrainedFrame(negativeWindow,visibleFrame:negativeScreen)
        check("negative_monitor_coordinates_supported",inside(negativeResult,negativeScreen) && negativeResult.size == negativeWindow.size)
        let smallScreen=NSRect(x:400,y:100,width:320,height:250)
        let smallResult=DesktopWindowBehavior.constrainedFrame(preserved,visibleFrame:smallScreen)
        check("smaller_display_has_priority_over_prior_size",near(smallResult,smallScreen))
        var allInside=true
        for x in stride(from:-3000,through:3000,by:500) {
            for y in stride(from:-2000,through:2000,by:500) {
                let f=NSRect(x:x,y:y,width:620,height:430)
                allInside = allInside && inside(DesktopWindowBehavior.constrainedFrame(f,visibleFrame:negativeScreen),negativeScreen)
            }
        }
        check("range_of_offscreen_positions_clamped",allInside)

        let app=NSApplication.shared
        app.setActivationPolicy(.accessory)
        let w=NSWindow(contentRect:NSRect(x:120,y:120,width:500,height:550),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.isReleasedWhenClosed=false
        let minimum=NSSize(width:390,height:430)
        DesktopWindowBehavior.configure(w,minimumContentSize:minimum)
        check("resizable_style_enabled",w.styleMask.contains(.resizable))
        check("content_minimum_configured",w.contentMinSize == minimum)
        check("fullscreen_disabled",w.collectionBehavior.contains(.fullScreenNone))
        check("fullscreen_tiling_disabled",w.collectionBehavior.contains(.fullScreenDisallowsTiling))
        check("no_fullscreen_primary_or_auxiliary",!w.collectionBehavior.contains(.fullScreenPrimary) && !w.collectionBehavior.contains(.fullScreenAuxiliary))
        check("native_green_button_enabled",w.standardWindowButton(.zoomButton)?.isEnabled == true)
        check("no_persistent_frame_autosave_in_test",w.frameAutosaveName.isEmpty)
        let availableScreens=NSScreen.screens
        let delegate=ZoomDelegate();w.delegate=delegate
        let original=w.frame
        var maximized: NSRect?
        var restored: NSRect?
        var skipped:[String]=[]
        if availableScreens.isEmpty {
            // A headless runner can still validate all geometry and window
            // configuration above. Native zoom needs an actual visible screen.
            skipped=["zoom_delegate_invoked", "zoom_uses_screen_visible_frame", "zoom_stays_within_visible_screen",
                     "zoom_does_not_enter_fullscreen_style", "second_zoom_restores_user_frame",
                     "restored_window_not_fullscreen"]
        } else {
            w.performZoom(nil)
            RunLoop.main.run(until:Date().addingTimeInterval(0.4))
            maximized=w.frame
            check("zoom_delegate_invoked",delegate.requestedStandardFrame != nil)
            if let standard=delegate.requestedStandardFrame {
                check("zoom_uses_screen_visible_frame",near(w.frame,standard))
                check("zoom_stays_within_visible_screen",availableScreens.contains{near(standard,$0.visibleFrame)})
            }
            check("zoom_does_not_enter_fullscreen_style",!w.styleMask.contains(.fullScreen))
            w.performZoom(nil)
            RunLoop.main.run(until:Date().addingTimeInterval(0.4))
            restored=w.frame
            check("second_zoom_restores_user_frame",near(w.frame,original))
            check("restored_window_not_fullscreen",!w.styleMask.contains(.fullScreen))
        }
        w.close()
        let out:[String:Any]=["checks":checks,"passed":checks.values.filter{$0}.count,
            "allPassed":checks.values.allSatisfy{$0},"nativeWindowShown":false,
            "screens":availableScreens.map{NSStringFromRect($0.visibleFrame)},
            "originalFrame":NSStringFromRect(original),
            "maximizedFrame":maximized.map{NSStringFromRect($0)} ?? "not tested",
            "restoredFrame":restored.map{NSStringFromRect($0)} ?? "not tested",
            "standardFrame":delegate.requestedStandardFrame.map{NSStringFromRect($0)} ?? "none",
            "skipped":skipped,
            "skipReason":availableScreens.isEmpty ? "SKIP native zoom: no NSScreen is available (headless session)":"none",
            "nativeZoomTested":!availableScreens.isEmpty,
            "actualMouseResizeTested":false,
            "testType":"geometry and window configuration; native AppKit performZoom only with a visible screen; no user/system settings modified"]
        let data=try! JSONSerialization.data(withJSONObject:out,options:[.prettyPrinted,.sortedKeys])
        print(String(data:data,encoding:.utf8)!)
        exit(checks.values.allSatisfy{$0} ? 0:1)
    }
}
