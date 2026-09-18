import Foundation
import QuartzCore

final class AngleSource {
    enum Mode {
        case sensor
        case manual(Double)
        case demo
    }

    private let sensor = LidAngleSensor()
    private var springPosition: Double
    private var springVelocity: Double = 0
    private var demoPhase: Double = 0
    private var lastTick: CFTimeInterval
    private var pendingSensorJump: Double?

    static let restingAngle: Double = 120

    private static let teleportThreshold: Double = 25

    private(set) var didTeleport = false

    func consumeTeleport() -> Bool {
        defer { didTeleport = false }
        return didTeleport
    }

    var mode: Mode = .sensor

    var hasSensor: Bool { sensor.isAvailable }

    private(set) var rawAngle: Double = AngleSource.restingAngle

    private(set) var closingVelocity: Double = 0

    var angle: Double { springPosition }

    init() {
        let initialAngle = sensor.currentAngle() ?? Self.restingAngle
        springPosition = initialAngle
        rawAngle = initialAngle
        lastTick = CACurrentMediaTime()
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 1.0 / 240.0), 1.0 / 20.0)
        lastTick = now

        let measuredTarget = currentTarget(dt: dt)
        let target = filteredTarget(measuredTarget)

        if abs(target - rawAngle) > Self.teleportThreshold {
            rawAngle = target
            springPosition = target
            springVelocity = 0
            closingVelocity = 0
            didTeleport = true
            return
        }

        let instantaneous = (rawAngle - target) / dt
        closingVelocity += (instantaneous - closingVelocity) * min(dt * 8, 1)
        rawAngle = target
        integrateSpring(toward: target, dt: dt)
    }

    private func filteredTarget(_ target: Double) -> Double {
        guard case .sensor = mode,
              abs(target - rawAngle) > Self.teleportThreshold else {
            pendingSensorJump = nil
            return target
        }

        guard let pendingSensorJump else {
            self.pendingSensorJump = target
            return rawAngle
        }

        let previousDelta = pendingSensorJump - rawAngle
        let currentDelta = target - rawAngle
        let sameDirection = previousDelta * currentDelta > 0
        let continuesMotion = abs(currentDelta) >= abs(previousDelta) - 5
        let confirmsPosition = abs(target - pendingSensorJump) < 5

        guard sameDirection, continuesMotion || confirmsPosition else {
            self.pendingSensorJump = nil
            return rawAngle
        }

        self.pendingSensorJump = nil
        return target
    }

    private func currentTarget(dt: Double) -> Double {
        switch mode {
        case .sensor:
            return sensor.currentAngle() ?? rawAngle
        case .manual(let value):
            return value
        case .demo:
            demoPhase += dt / 3.5
            let t = demoPhase.truncatingRemainder(dividingBy: 1.0)
            let openAmount = t < 0.5 ? 1 - t * 2 : (t - 0.5) * 2
            let eased = openAmount * openAmount * (3 - 2 * openAmount)
            return 5 + eased * (Self.restingAngle - 5)
        }
    }

    private func integrateSpring(toward target: Double, dt: Double) {
        let stiffness: Double = 700
        let damping = 2 * sqrt(stiffness)
        let acceleration = stiffness * (target - springPosition) - damping * springVelocity
        springVelocity += acceleration * dt
        springPosition += springVelocity * dt
    }

    func reset(to value: Double? = nil) {
        let target = value ?? sensor.currentAngle() ?? Self.restingAngle
        springPosition = target
        springVelocity = 0
        closingVelocity = 0
        rawAngle = target
        pendingSensorJump = nil
        lastTick = CACurrentMediaTime()
    }
}
