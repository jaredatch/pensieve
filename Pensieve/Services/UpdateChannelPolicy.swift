enum UpdateChannelPolicy {
    static let betaUpdatesEnabledKey = "betaUpdatesEnabled"

    static func allowedChannels(betaOptIn: Bool) -> Set<String> {
        betaOptIn ? ["beta"] : []
    }
}
