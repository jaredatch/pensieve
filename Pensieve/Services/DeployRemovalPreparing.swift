import Foundation

/// App adapters keep Skill-dependent path guards and legacy generation out of the daemon primitive.
protocol DeployRemovalPreparing {
    func removalOperation(skill: Skill, platform: PlatformTarget, projectPath: String?) -> DeployRemovalOperation
}
