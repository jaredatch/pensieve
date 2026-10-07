import Foundation

/// App adapters keep Skill-dependent path guards and legacy generation out of the daemon primitive.
protocol DeployRemovalPreparing {
    func removalOperation(skill: Skill, platform: PlatformTarget, projectPath: String?) -> DeployRemovalOperation
}

// Explicit witnesses may share these operations when their leaf deletion is already unchecked.
// Real filesystem adapters prepare their own direct FileService deletion instead.
extension LinkServiceProtocol {
    func adapterRemovalOperation(skill: Skill, platform: PlatformTarget,
                                 projectPath: String?) -> DeployRemovalOperation {
        DeployRemovalOperation(classify: {
            try self.ownsArtifact(skill: skill, platform: platform, projectPath: projectPath)
        }, delete: { try self.unlink(skill: skill, platform: platform, projectPath: projectPath) })
    }
}

extension CursorCompilerProtocol {
    func adapterRemovalOperation(skill: Skill, projectPath: String?) -> DeployRemovalOperation {
        DeployRemovalOperation(classify: { try self.ownsArtifact(skill: skill, projectPath: projectPath) },
            delete: { try self.remove(skill: skill, projectPath: projectPath) })
    }
}
