import Darwin

/// Reads the kernel's peer identity. Request bytes never supply authentication facts.
protocol SocketPeerCredentialReading {
    func userID(of descriptor: Int32) throws -> uid_t
}

struct SocketPeerCredentials: SocketPeerCredentialReading {
    func userID(of descriptor: Int32) throws -> uid_t {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0 else {
            throw SocketError.system("getpeereid", errno)
        }
        return user
    }
}
