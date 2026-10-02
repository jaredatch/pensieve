import Foundation

enum ConflictSide: Equatable {
    case thisMachine
    case otherMachine
}

enum ConflictKind: Equatable {
    case body
    case overlay
    case category
    case project
}

/// One conflicted path with both sides' blobs. `thisMachine` = git stage 3 (the replayed local
/// commit - THIS machine); `otherMachine` = git stage 2 (origin/main - the OTHER machine).
/// nil = that side is absent, DISTINCT from "" (empty).
struct ConflictItem: Equatable {
    let path: String
    let kind: ConflictKind
    let thisMachine: String?
    let otherMachine: String?
}

struct ConflictSet: Equatable {
    let items: [ConflictItem]
}

/// The user's choice for one conflicted path, carrying the blobs they SAW so resolve can prove the
/// world didn't move under the choice. Single unified payload type.
struct ResolutionPick: Equatable {
    let side: ConflictSide
    let expectedThis: String?
    let expectedOther: String?
}

/// Result of inspecting: real conflicts to show, or the conflict cleared itself upstream.
enum ConflictInspection: Equatable {
    case conflicts(ConflictSet)
    case cleared(SyncOutcome)
}
