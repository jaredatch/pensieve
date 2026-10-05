import SwiftData
@testable import Pensieve

/// Wraps the public SwiftData backing-data boundary after a real deletion. Scalar/transformable
/// property reads are recorded instead of turning the unsafe access into a process trap.
/// Context/identifier metadata and all relationships/writes delegate unchanged; this probes retired
/// property access, not SwiftData's deletion, query, or persistence implementation.
final class DeletedSkillReadProbe: BackingData {
    typealias Model = Skill
    private var wrapped: any BackingData<Skill>
    private(set) var propertyReads: [PartialKeyPath<Skill>] = []

    init(wrapping wrapped: any BackingData<Skill>) { self.wrapped = wrapped }
    required init(for modelType: Skill.Type) { wrapped = Skill.createBackingData() }
    var persistentModelID: PersistentIdentifier? {
        get { wrapped.persistentModelID }
        set { wrapped.persistentModelID = newValue }
    }
    var metadata: Any { wrapped.metadata }

    func getValue<Value: Decodable>(forKey key: KeyPath<Skill, Value>) -> Value {
        propertyReads.append(key)
        return wrapped.getValue(forKey: key)
    }
    func getValue<Value: PersistentModel>(forKey key: KeyPath<Skill, Value>) -> Value {
        wrapped.getValue(forKey: key)
    }
    func getValue<Value: PersistentModel>(forKey key: KeyPath<Skill, Value?>) -> Value? {
        wrapped.getValue(forKey: key)
    }
    func getValue<Value: RelationshipCollection, OtherModel>(forKey key: KeyPath<Skill, Value>) -> Value
        where OtherModel == Value.PersistentElement {
        wrapped.getValue(forKey: key)
    }
    func getValue<Value: Decodable & RelationshipCollection, OtherModel>(forKey key: KeyPath<Skill, Value>) -> Value
        where OtherModel == Value.PersistentElement {
        wrapped.getValue(forKey: key)
    }
    func getTransformableValue<Value>(forKey key: KeyPath<Skill, Value>) -> Value {
        propertyReads.append(key)
        return wrapped.getTransformableValue(forKey: key)
    }
    func setValue<Value: Encodable>(forKey key: KeyPath<Skill, Value>, to value: Value) {
        wrapped.setValue(forKey: key, to: value)
    }
    func setValue<Value: PersistentModel>(forKey key: KeyPath<Skill, Value>, to value: Value) {
        wrapped.setValue(forKey: key, to: value)
    }
    func setValue<Value: PersistentModel>(forKey key: KeyPath<Skill, Value?>, to value: Value?) {
        wrapped.setValue(forKey: key, to: value)
    }
    func setValue<Value: RelationshipCollection, OtherModel>(forKey key: KeyPath<Skill, Value>, to value: Value)
        where OtherModel == Value.PersistentElement {
        wrapped.setValue(forKey: key, to: value)
    }
    func setValue<Value: Encodable & RelationshipCollection, OtherModel>(forKey key: KeyPath<Skill, Value>, to value: Value)
        where OtherModel == Value.PersistentElement {
        wrapped.setValue(forKey: key, to: value)
    }
    func setTransformableValue<Value>(forKey key: KeyPath<Skill, Value>, to value: Value) {
        wrapped.setTransformableValue(forKey: key, to: value)
    }
}
