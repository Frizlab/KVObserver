import CoreData
import Foundation
import os.log



public final class KVTreeObserver<Object : NSObject> {
	
	private let observedSplitKeyPaths: [String: Set<[String]>]
	
	/* The observer MUST be stopped before the observed object or the observer is released. */
	private unowned var observedObject: Object?
	
	private let kvObserver: KVObserver
	private var observationIDs = Set<KVObserver.ObservingId>()
	private var subObservers = [String: [KVTreeObserver<NSObject>]]()
	
	/* For debug, but otherwise unneeded. */
	private let level: Int
	
	public convenience init(observedKeyPaths: Set<String>) {
		self.init(
			observedSplitKeyPaths: {
				let observedSplitKeyPaths = Set(observedKeyPaths.map{ $0.split(separator: ".", omittingEmptySubsequences: false).map(String.init) })
				let observedFirstLevels = Set(observedSplitKeyPaths.compactMap(\.first))
				
				var res = [String: Set<[String]>]()
				for firstLevel in observedFirstLevels {
					let sub = Set(observedSplitKeyPaths.filter{ $0.first == firstLevel }.map{ Array($0.dropFirst()) })
					if !sub.isEmpty {res[firstLevel] = sub}
				}
				return res
			}(),
			level: 0,
			kvObserver: KVObserver()
		)
	}
	
	private init(observedSplitKeyPaths: [String: Set<[String]>], level: Int, kvObserver: KVObserver) {
		self.observedSplitKeyPaths = observedSplitKeyPaths
		self.kvObserver = kvObserver
		
		self.level = level
	}
	
	deinit {
		os_log("Releasing a KVTreeObserver.", type: .debug)
	}
	
	@discardableResult
	public func startObservingIfNeeded(_ observed: Object, kvoOptions: NSKeyValueObservingOptions = [], nodeAction: @escaping (Object) -> Void = { _ in }, leafAction: @escaping (Object) -> Void) -> Bool {
		assert(observedObject == nil || observedObject === observed)
		guard observedObject == nil else {
			return false
		}
		
		observedObject = observed
		assert(observationIDs.isEmpty)
		
		/* We force initial notification to observe the whole tree right away.
		 * If the initial option was not present, we filter it before calling the handlers. */
		let hasInitial = kvoOptions.contains(.initial)
		let kvoOptions = kvoOptions.union(.initial)
		
		let observeKey = { [level] (_ keyAndSubKeys: (String, Set<[String]>)) -> KVObserver.ObservingId in
			let (key, subKeysIncludingEmtpy) = keyAndSubKeys
			let subKeys = subKeysIncludingEmtpy.filter{ !$0.isEmpty }
			let isLeaf = subKeysIncludingEmtpy.count > subKeys.count
			let isNode = !subKeys.isEmpty
			var isInitial = true
			
			/* Observe the key. */
			os_log(
				"Starting observing key “%{public}@” with subkeys %{public}@ for %{public}@<%{public}p> (level %ld).", type: .debug,
				key, subKeys, "\(type(of: observed))", observed, level
			)
			let ret = self.kvObserver.observe(object: observed, keyPath: key, kvoOptions: kvoOptions, dispatchType: .direct, handler: { [unowned self, unowned observed] (_ changes: [NSKeyValueChangeKey: Any]?) in
				defer {isInitial = false}
				guard ((observed as? NSManagedObject).map{ $0.faultingState == 0 } ?? true) else {
					return os_log(
						"Skipped observation block because faulting state is not 0 for key %{public}@ (subkeys %{public}@) of %{public}@<%{public}p> (level %ld).", type: .debug,
						key, subKeys, "\(type(of: observed))", observed, level
					)
				}
				os_log(
					"Entered observation block of key %{public}@ (subkeys %{public}@) for %{public}@<%{public}p> (level %ld).", type: .debug,
					key, subKeys, "\(type(of: observed))", observed, level
				)
				
				if !isInitial || hasInitial {
					if isNode {nodeAction(observed)}
					if isLeaf {leafAction(observed)}
				}
				
				/* First unobserve the previously observed subObjects. */
				subObservers[key]?.forEach{ $0.stopObserving() }
				subObservers.removeValue(forKey: key)
				
				/* Next observe the new subObjects if there are some and it’s needed. */
				if isNode, let value = observed.value(forKey: key) as! NSObject? {
					let observedSubObjects: [NSObject]
					switch value {
						case let orderedSet as NSOrderedSet: observedSubObjects = orderedSet.array as! [NSObject]
						case let `set` as NSSet:             observedSubObjects = `set`.allObjects as! [NSObject]
						case let array as NSArray:           observedSubObjects = array as! [NSObject]
						default:                             observedSubObjects = [value]
					}
					subObservers[key] = observedSubObjects.map{ subObject in
						let ret = KVTreeObserver<NSObject>(
							observedSplitKeyPaths: {
								let firstLevelSubkeys = subKeys.compactMap(\.first)
								var res = [String: Set<[String]>]()
								for firstLevel in firstLevelSubkeys {
									let sub = Set(subKeys.filter{ $0.first == firstLevel }.map{ Array($0.dropFirst()) })
									if !sub.isEmpty {res[firstLevel] = sub}
								}
								return res
							}(),
							level: level + 1,
							kvObserver: kvObserver
						)
						ret.startObservingIfNeeded(
							subObject,
							kvoOptions: kvoOptions,
							nodeAction: { [unowned observed] _ in nodeAction(observed) },
							leafAction: { [unowned observed] _ in leafAction(observed) }
						)
						return ret
					}
				}
			})
			return ret
		}
		
		observationIDs = Set(observedSplitKeyPaths.map(observeKey))
		return true
	}
	
	public func stopObserving() {
		subObservers.values.forEach{ $0.forEach{ $0.stopObserving() } }
		subObservers = [:]
		
		/* We cannot use observedObject here as it might be in the process of being deallocated, which is already too late to use it. */
		os_log(
			"Stop observation of key %{public}@ (level %ld).", type: .debug,
			"\(observedSplitKeyPaths.keys)", level
		)
		kvObserver.stopObserving(ids: observationIDs)
		observationIDs = []
		
		observedObject = nil
	}
	
}
