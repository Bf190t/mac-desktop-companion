import Foundation
import CoreGraphics

/// Screen coordinates use AppKit's bottom-left origin, including negative displays.
enum PetRoamMode: String, CaseIterable { case horizontal, free }
enum PetRoamFacing: String { case left, right }
enum PetRoamPose: Equatable {
    case standing
    case walking(facing: PetRoamFacing, frame: Int)
}

/// Pure geometry and gait state. No windows, screen queries, timers or persistence.
struct PetRoamEngine {
    private(set) var ground: CGPoint
    private(set) var visibleFrame: CGRect
    private(set) var artworkSize: CGSize
    private(set) var mode: PetRoamMode
    private(set) var speed: CGFloat
    private(set) var facing: PetRoamFacing = .right
    private(set) var phase: CGFloat = 0
    private(set) var isWalking = false
    private(set) var remainingDuration: TimeInterval = 0
    private var direction = CGVector.zero
    private var lastDistance: CGFloat = 0
    static let edgeMargin: CGFloat = 14
    static let frameCount = 8

    init(ground: CGPoint, visibleFrame: CGRect, artworkSize: CGSize,
         mode: PetRoamMode = .horizontal, speed: CGFloat = 42) {
        self.ground = ground
        self.visibleFrame = visibleFrame
        self.artworkSize = artworkSize
        self.mode = mode
        self.speed = speed
        configure(ground: ground, visibleFrame: visibleFrame,
                  artworkSize: artworkSize, mode: mode, speed: speed)
    }

    var fitsVisibleFrame: Bool {
        artworkSize.width <= visibleFrame.width && artworkSize.height <= visibleFrame.height
    }

    /// Bounds for the window's bottom-center anchor, not the visible shoe pixels.
    var groundBounds: CGRect {
        let insetX = min(Self.edgeMargin, max(0, (visibleFrame.width - artworkSize.width) / 2))
        let insetY = min(Self.edgeMargin, max(0, (visibleFrame.height - artworkSize.height) / 2))
        let minX = visibleFrame.minX + min(artworkSize.width, visibleFrame.width) / 2 + insetX
        let maxX = max(minX, visibleFrame.maxX - artworkSize.width / 2 - insetX)
        let minY = visibleFrame.minY + insetY
        let maxY = max(minY, visibleFrame.maxY - artworkSize.height - insetY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var pose: PetRoamPose {
        guard isWalking, lastDistance > 0.000_001 else { return .standing }
        return .walking(facing: facing, frame: min(Self.frameCount - 1, Int(phase * CGFloat(Self.frameCount))))
    }

    mutating func configure(ground: CGPoint, visibleFrame: CGRect, artworkSize: CGSize,
                            mode: PetRoamMode, speed: CGFloat = 42) {
        stop()
        let values = [visibleFrame.origin.x, visibleFrame.origin.y, visibleFrame.width, visibleFrame.height]
        self.visibleFrame = values.allSatisfy { $0.isFinite } && visibleFrame.width > 0 && visibleFrame.height > 0
            ? visibleFrame : CGRect(x: 0, y: 0, width: 1, height: 1)
        self.artworkSize = CGSize(width: artworkSize.width.isFinite ? max(1, artworkSize.width) : 1,
                                  height: artworkSize.height.isFinite ? max(1, artworkSize.height) : 1)
        self.mode = mode
        self.speed = speed.isFinite ? min(100, max(1, speed)) : 42
        let b = groundBounds
        let x = ground.x.isFinite ? ground.x : b.midX
        let y = ground.y.isFinite ? ground.y : b.minY
        self.ground = constrained(CGPoint(x: x, y: y))
    }

    mutating func begin(direction requested: CGVector, duration: TimeInterval) {
        stop()
        guard fitsVisibleFrame, duration.isFinite, duration > 0,
              requested.dx.isFinite, requested.dy.isFinite else { return }
        let vector = CGVector(dx: requested.dx, dy: mode == .horizontal ? 0 : requested.dy)
        let length = hypot(vector.dx, vector.dy)
        guard length > 0, canMove(vector) else { return }
        direction = CGVector(dx: vector.dx / length, dy: vector.dy / length)
        remainingDuration = min(duration, 15)
        isWalking = true
        phase = 0
        // Do not change facing until actual movement occurs. A vertical leg
        // must retain the last real horizontal facing, including after a stop.
    }

    /// Returns actual distance travelled. Long UI stalls never cause a teleport.
    @discardableResult mutating func advance(dt: TimeInterval) -> CGFloat {
        guard isWalking, dt.isFinite, dt > 0 else { return 0 }
        let elapsed = min(dt, remainingDuration, 0.2)
        let old = ground
        let proposed = CGPoint(x: old.x + direction.dx * speed * CGFloat(elapsed),
                               y: old.y + direction.dy * speed * CGFloat(elapsed))
        ground = constrained(proposed)
        let dx = ground.x - old.x, dy = ground.y - old.y
        let distance = hypot(dx, dy)
        if dx > 0.000_001 { facing = .right }
        else if dx < -0.000_001 { facing = .left }
        lastDistance = distance
        phase = (phase + distance / max(1, artworkSize.height * 0.34)).truncatingRemainder(dividingBy: 1)
        remainingDuration = max(0, remainingDuration - dt)
        let hitBoundary = abs(ground.x - proposed.x) > 0.000_001 || abs(ground.y - proposed.y) > 0.000_001
        if distance <= 0.000_001 || remainingDuration <= 0 || hitBoundary { stop() }
        return distance
    }

    mutating func stop() {
        isWalking = false
        remainingDuration = 0
        direction = .zero
        lastDistance = 0
    }

    var availableDirections: [CGVector] {
        guard fitsVisibleFrame else { return [] }
        let pairs: [(CGFloat, CGFloat)] = mode == .horizontal
            ? [(1, 0), (-1, 0)]
            : [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)]
        return pairs.map { CGVector(dx: $0.0, dy: $0.1) }.filter { canMove($0) }
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        let b = groundBounds
        return CGPoint(x: min(b.maxX, max(b.minX, point.x)),
                       y: mode == .horizontal ? b.minY : min(b.maxY, max(b.minY, point.y)))
    }

    private func canMove(_ vector: CGVector) -> Bool {
        let length = hypot(vector.dx, vector.dy)
        guard length > 0 else { return false }
        // Exclude directions pointing into a wall instead of making a short
        // diagonal slide along it. The next leg chooses an available direction.
        let b = groundBounds
        if vector.dx < 0 && ground.x <= b.minX + 0.001 { return false }
        if vector.dx > 0 && ground.x >= b.maxX - 0.001 { return false }
        if vector.dy < 0 && ground.y <= b.minY + 0.001 { return false }
        if vector.dy > 0 && ground.y >= b.maxY - 0.001 { return false }
        let point = constrained(CGPoint(x: ground.x + vector.dx / length, y: ground.y + vector.dy / length))
        return hypot(point.x - ground.x, point.y - ground.y) > 0.000_001
    }
}

/// Main-run-loop scheduler. It owns no windows and holds no sleep assertions.
/// During rests there is one one-shot timer; movement alone uses a 14 Hz timer.
final class PetRoamController {
    static let framesPerSecond: TimeInterval = 14
    var onUpdate: ((PetRoamEngine) -> Void)?
    private(set) var engine: PetRoamEngine?
    private(set) var isRunning = false
    var current: PetRoamEngine? { engine }
    var isActive: Bool { isRunning }
    var isWalking: Bool { engine?.isWalking ?? false }
    var hasMovementTimer: Bool { movementTimer?.isValid == true }
    var hasIdleTimer: Bool { idleTimer?.isValid == true }
    var hasTimers: Bool { hasMovementTimer || hasIdleTimer }
    private var movementTimer: Timer?
    private var idleTimer: Timer?
    private var previousUptime: TimeInterval = 0

    deinit { movementTimer?.invalidate(); idleTimer?.invalidate() }

    func start(engine: PetRoamEngine) {
        cancelTimers()
        self.engine = engine
        isRunning = true
        beginNextLeg()
    }

    /// Synchronous: when this returns, there are no timers and pose is standing.
    func stop() {
        cancelTimers()
        isRunning = false
        engine?.stop()
        if let state = engine { onUpdate?(state) }
    }

    private func cancelTimers() {
        movementTimer?.invalidate(); movementTimer = nil
        idleTimer?.invalidate(); idleTimer = nil
        previousUptime = 0
    }

    private func beginNextLeg() {
        guard isRunning, var state = engine else { return }
        idleTimer = nil
        guard let direction = state.availableDirections.randomElement() else {
            state.stop(); engine = state; onUpdate?(state)
            // No room: remain standing without polling. Geometry/lifecycle
            // changes explicitly restart this controller from the app layer.
            return
        }
        state.begin(direction: direction, duration: Double.random(in: 2.5...5.0))
        engine = state
        guard state.isWalking else { return }
        previousUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.012
        movementTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard isRunning, var state = engine else { return }
        let now = ProcessInfo.processInfo.systemUptime
        state.advance(dt: max(0, now - previousUptime))
        previousUptime = now
        engine = state
        onUpdate?(state)
        // onUpdate may synchronously stop or replace this controller.
        guard isRunning, let latest = engine, !latest.isWalking else { return }
        movementTimer?.invalidate(); movementTimer = nil
        let timer = Timer(timeInterval: Double.random(in: 8...18), repeats: false) { [weak self] _ in self?.beginNextLeg() }
        timer.tolerance = 1
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
