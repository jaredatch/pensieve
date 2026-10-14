enum SkillDiscoveryTitle {
    static func text(count: Int) -> String {
        let noun = count == 1 ? "Skill" : "Skills"
        return "Found \(count) \(noun)"
    }
}
