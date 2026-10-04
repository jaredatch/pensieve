import CYaml
import Foundation
import Yams

/// The only safe construction path for untrusted YAML.
///
/// libyaml's event stream is checked before Yams composes or constructs a value. This keeps
/// non-scalar mapping keys away from Yams' force-unwrapped string-key constructor and bounds the
/// work caused by aliases and nested merges before Yams expands them. Reported node tags are capped
/// both before and after repairing UTF-8, before Yams can copy them through construction. A checked
/// Yams integer constructor makes an overflowing base-60 value fall back to its scalar string.
enum CheckedYAMLLoader {
    static let maximumDepth = 64
    static let maximumAliasExpansionCost = 100_000
    static let maximumMergeNestingDepth = 4
    static let maximumTagByteCount = 256
    static let implicitScalarTagByteCount = "tag:yaml.org,2002:timestamp".utf8.count
    private static let implicitSequenceTagByteCount = "tag:yaml.org,2002:seq".utf8.count
    private static let implicitMappingTagByteCount = "tag:yaml.org,2002:map".utf8.count
    static let resolver = Resolver.default

    struct Document {
        let root: Node?
        let value: Any?
        let rootIsFlowMapping: Bool
    }

    enum LoaderError: Error, Equatable {
        case invalidYAML
        case nonScalarKey
        case nestingTooDeep
        case expandedSizeTooLarge
        case explicitMergeTag
        case mergeNestingTooDeep
        case tagTooLong
    }

    private static let checkedConstructor: Constructor = {
        var scalarMap = Constructor.defaultScalarMap
        let yamsInteger = scalarMap[.int]
        scalarMap[.int] = { scalar in
            guard !sexagesimalIntegerWouldOverflow(scalar) else { return nil }
            return yamsInteger?(scalar)
        }
        return Constructor(scalarMap)
    }()

    static func load(yaml: String) throws -> Any? {
        _ = try validate(yaml)
        return try Yams.load(yaml: yaml, resolver, checkedConstructor)
    }

    /// SkillParser needs both the composed node for source-preservation metadata and its value.
    /// Construction remains inside this chokepoint so a caller cannot bypass event validation.
    static func composeAndLoad(yaml: String) throws -> Document {
        let rootIsFlowMapping = try validate(yaml)
        let root = try Yams.compose(yaml: yaml, resolver, checkedConstructor)
        return Document(root: root, value: root?.any, rootIsFlowMapping: rootIsFlowMapping)
    }

    /// Compose an untrusted bare scalar once through the checked path for the writer's quoting
    /// oracle. The compatibility flag identifies the checked integer fallback that older builds
    /// cannot construct safely; other resolved tags may still construct as the original String.
    static func inspectBareScalar(yaml: String) throws -> (value: Any?, requiresLegacyIntegerQuote: Bool) {
        let inspected = try composeAndLoad(yaml: yaml)
        guard let root = inspected.root else {
            return (value: nil, requiresLegacyIntegerQuote: false)
        }
        return (
            value: inspected.value,
            requiresLegacyIntegerQuote: root.tag == Tag(.int)
                && root.scalar.map(sexagesimalIntegerWouldOverflow) == true
        )
    }

    static func matchesImplicitMergeKey(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        switch bytes.count {
        case 2:
            return bytes[0] == 0x3C && bytes[1] == 0x3C
        case 3:
            return bytes[0] == 0x3C && bytes[1] == 0x3C
                && (0x0A...0x0D).contains(bytes[2])
        case 4:
            return bytes[0] == 0x3C && bytes[1] == 0x3C
                && ((bytes[2] == 0x0D && bytes[3] == 0x0A)
                    || (bytes[2] == 0xC2 && bytes[3] == 0x85))
        case 5:
            return bytes[0] == 0x3C && bytes[1] == 0x3C
                && bytes[2] == 0xE2 && bytes[3] == 0x80
                && (bytes[4] == 0xA8 || bytes[4] == 0xA9)
        default:
            return false
        }
    }

    /// Returns the first document's root style from its start event. Yams 6.2.2 takes a mapping's
    /// style from the end event instead, where libyaml leaves the style field zeroed.
    private static func validate(_ yaml: String) throws -> Bool {
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) == 1 else { throw LoaderError.invalidYAML }
        defer { yaml_parser_delete(&parser) }

        let bytes = yaml.utf8CString
        return try bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { throw LoaderError.invalidYAML }
            return try baseAddress.withMemoryRebound(to: UInt8.self, capacity: buffer.count) { input in
                yaml_parser_set_input_string(&parser, input, buffer.count - 1)
                var validator = EventValidator()
                var reachedEnd = false
                var rootFlow: Bool?
                while !reachedEnd {
                    var event = yaml_event_t()
                    guard yaml_parser_parse(&parser, &event) == 1 else {
                        throw LoaderError.invalidYAML
                    }
                    defer { yaml_event_delete(&event) }
                    if rootFlow == nil,
                       [YAML_SCALAR_EVENT, YAML_SEQUENCE_START_EVENT, YAML_MAPPING_START_EVENT].contains(event.type) {
                        rootFlow = event.type == YAML_MAPPING_START_EVENT
                            && event.data.mapping_start.style == YAML_FLOW_MAPPING_STYLE
                    }
                    reachedEnd = event.type == YAML_STREAM_END_EVENT
                    try validator.consume(event)
                }
                return rootFlow ?? false
            }
        }
    }

    private static func sexagesimalIntegerWouldOverflow(_ scalar: Node.Scalar) -> Bool {
        guard scalar.style == .any || scalar.style == .plain else { return false }
        guard scalar.string.contains(":") else { return false }
        var value = scalar.string.replacingOccurrences(of: "_", with: "")

        let sign = value.hasPrefix("-") ? -1 : 1
        if value.hasPrefix("-") || value.hasPrefix("+") { value.removeFirst() }
        let components = value.components(separatedBy: ":")
        let digits = components.compactMap(Int.init)
        guard digits.count == components.count else { return false }

        var base = 1
        var result = 0
        for digit in digits.reversed() {
            let (term, termOverflow) = digit.multipliedReportingOverflow(by: base)
            let (sum, sumOverflow) = result.addingReportingOverflow(term)
            let (nextBase, baseOverflow) = base.multipliedReportingOverflow(by: 60)
            if termOverflow || sumOverflow || baseOverflow { return true }
            result = sum
            base = nextBase
        }
        return result.multipliedReportingOverflow(by: sign).overflow
    }
}

private extension CheckedYAMLLoader {
    enum NodeKind {
        case scalar
        case sequence
        case mapping
    }

    struct NodeInfo {
        let kind: NodeKind
        let expandedCost: Int
        let constructedDepth: Int
        let hasExplicitMergeTag: Bool
        let isImplicitMergeKey: Bool
        let mergeValueDepth: Int
    }

    struct Frame {
        let kind: NodeKind
        let anchor: String?
        var expandedCost: Int
        var maximumChildDepth = 0
        var maximumSequenceItemMergeValueDepth = 0
        var rootMergeNestingDepth = 0
        var expectsMappingKey: Bool
        var nextValueIsMerge = false

        init(kind: NodeKind, anchor: String?, tagByteCount: Int) {
            self.kind = kind
            self.anchor = anchor
            expandedCost = 1 + tagByteCount
            expectsMappingKey = kind == .mapping
        }
    }

    struct EventValidator {
        private var frames: [Frame] = []
        private var anchors: [String: NodeInfo] = [:]
        private var aliasExpansionCost = 0

        mutating func consume(_ event: yaml_event_t) throws {
            switch event.type {
            case YAML_DOCUMENT_START_EVENT:
                guard frames.isEmpty else { throw LoaderError.invalidYAML }
                anchors.removeAll(keepingCapacity: true)
                aliasExpansionCost = 0
            case YAML_DOCUMENT_END_EVENT:
                guard frames.isEmpty else { throw LoaderError.invalidYAML }
            case YAML_NO_EVENT:
                throw LoaderError.invalidYAML
            default:
                try consumeNodeEvent(event)
            }
        }

        private mutating func consumeNodeEvent(_ event: yaml_event_t) throws {
            switch event.type {
            case YAML_SCALAR_EVENT:
                let tag = try decodedTag(event.data.scalar.tag)
                let anchor = decodedString(event.data.scalar.anchor)
                try completeNode(
                    NodeInfo(
                        kind: .scalar,
                        expandedCost: scalarCost(event, tag: tag),
                        constructedDepth: 1,
                        hasExplicitMergeTag: tag == "tag:yaml.org,2002:merge",
                        isImplicitMergeKey: isImplicitMergeKey(event, tag: tag),
                        mergeValueDepth: 0
                    ),
                    anchor: anchor
                )
            case YAML_ALIAS_EVENT:
                guard let name = decodedString(event.data.alias.anchor),
                      let aliased = anchors[name] else {
                    throw LoaderError.invalidYAML
                }
                aliasExpansionCost = try boundedAliasExpansionSum(
                    aliasExpansionCost,
                    aliased.expandedCost
                )
                try completeNode(aliased, anchor: nil)
            case YAML_SEQUENCE_START_EVENT:
                try startContainer(
                    kind: .sequence,
                    anchor: decodedString(event.data.sequence_start.anchor),
                    tag: try decodedTag(event.data.sequence_start.tag),
                    implicitTagByteCount: implicitSequenceTagByteCount
                )
            case YAML_MAPPING_START_EVENT:
                try startContainer(
                    kind: .mapping,
                    anchor: decodedString(event.data.mapping_start.anchor),
                    tag: try decodedTag(event.data.mapping_start.tag),
                    implicitTagByteCount: implicitMappingTagByteCount
                )
            case YAML_SEQUENCE_END_EVENT:
                try endContainer(expected: .sequence)
            case YAML_MAPPING_END_EVENT:
                try endContainer(expected: .mapping)
            default:
                break
            }
        }

        private mutating func startContainer(
            kind: NodeKind,
            anchor: String?,
            tag: String?,
            implicitTagByteCount: Int
        ) throws {
            try checkDepth()
            if isMappingKey { throw LoaderError.nonScalarKey }
            frames.append(Frame(
                kind: kind,
                anchor: anchor,
                tagByteCount: tagByteCount(tag, whenNonSpecific: implicitTagByteCount)
            ))
        }

        private mutating func endContainer(expected: NodeKind) throws {
            guard let frame = frames.popLast(), frame.kind == expected else {
                throw LoaderError.invalidYAML
            }
            if frame.kind == .mapping, !frame.expectsMappingKey {
                throw LoaderError.invalidYAML
            }
            try completeNode(
                NodeInfo(
                    kind: frame.kind,
                    expandedCost: frame.expandedCost,
                    constructedDepth: frame.maximumChildDepth + 1,
                    hasExplicitMergeTag: false,
                    isImplicitMergeKey: false,
                    mergeValueDepth: frame.kind == .mapping
                        ? frame.rootMergeNestingDepth + 1
                        : frame.maximumSequenceItemMergeValueDepth
                ),
                anchor: frame.anchor
            )
        }

        private mutating func completeNode(
            _ node: NodeInfo,
            anchor: String?
        ) throws {
            if frames.count + node.constructedDepth > maximumDepth {
                throw LoaderError.nestingTooDeep
            }
            if isMappingKey, node.kind != .scalar { throw LoaderError.nonScalarKey }
            if isMappingKey, node.hasExplicitMergeTag { throw LoaderError.explicitMergeTag }
            if let anchor { anchors[anchor] = node }

            guard !frames.isEmpty else { return }
            let index = frames.index(before: frames.endIndex)
            frames[index].expandedCost += node.expandedCost
            frames[index].maximumChildDepth = max(
                frames[index].maximumChildDepth,
                node.constructedDepth
            )
            if frames[index].kind == .sequence, node.kind == .mapping {
                frames[index].maximumSequenceItemMergeValueDepth = max(
                    frames[index].maximumSequenceItemMergeValueDepth,
                    node.mergeValueDepth
                )
            }
            if frames[index].kind == .mapping {
                if frames[index].expectsMappingKey {
                    frames[index].nextValueIsMerge = node.isImplicitMergeKey
                } else if frames[index].nextValueIsMerge {
                    frames[index].rootMergeNestingDepth = max(
                        frames[index].rootMergeNestingDepth,
                        node.mergeValueDepth
                    )
                    if frames[index].rootMergeNestingDepth > maximumMergeNestingDepth {
                        throw LoaderError.mergeNestingTooDeep
                    }
                    frames[index].nextValueIsMerge = false
                }
                frames[index].expectsMappingKey.toggle()
            }
        }

        private var isMappingKey: Bool {
            frames.last?.kind == .mapping && frames.last?.expectsMappingKey == true
        }

        private func checkDepth() throws {
            if frames.count + 1 > maximumDepth { throw LoaderError.nestingTooDeep }
        }

        private func boundedAliasExpansionSum(_ left: Int, _ right: Int) throws -> Int {
            guard right <= maximumAliasExpansionCost,
                  left <= maximumAliasExpansionCost - right else {
                throw LoaderError.expandedSizeTooLarge
            }
            return left + right
        }

        private func scalarCost(_ event: yaml_event_t, tag: String?) -> Int {
            let length = Int(event.data.scalar.length)
            return 1 + length + tagByteCount(
                tag,
                whenNonSpecific: implicitScalarTagByteCount
            )
        }

        private func tagByteCount(_ tag: String?, whenNonSpecific defaultCount: Int) -> Int {
            guard let tag else { return defaultCount }
            return tag == "!" ? defaultCount : tag.utf8.count
        }

        private func isImplicitMergeKey(_ event: yaml_event_t, tag: String?) -> Bool {
            let hasImplicitTag = event.data.scalar.tag == nil
                ? event.data.scalar.style == YAML_PLAIN_SCALAR_STYLE
                : tag == nil
            guard hasImplicitTag,
                  let valuePointer = event.data.scalar.value else {
                return false
            }
            let valueBytes = UnsafeBufferPointer(
                start: valuePointer,
                count: Int(event.data.scalar.length)
            )
            return CheckedYAMLLoader.matchesImplicitMergeKey(valueBytes)
        }

        private func decodedTag(_ pointer: UnsafePointer<UInt8>?) throws -> String? {
            guard let pointer else { return nil }
            var length = 0
            while length <= maximumTagByteCount, pointer[length] != 0 {
                length += 1
            }
            guard length <= maximumTagByteCount else { throw LoaderError.tagTooLong }
            let bytes = UnsafeBufferPointer(start: pointer, count: length)
            // A failable decode would diverge from Yams for malformed tag escapes.
            // swiftlint:disable:next optional_data_string_conversion
            let tag = String(decoding: bytes, as: UTF8.self)
            guard tag.utf8.count <= maximumTagByteCount else { throw LoaderError.tagTooLong }
            return tag.isEmpty ? nil : tag
        }

        private func decodedString(_ pointer: UnsafePointer<UInt8>?) -> String? {
            String.decodeCString(pointer, as: UTF8.self, repairingInvalidCodeUnits: true)?.result
        }
    }
}
