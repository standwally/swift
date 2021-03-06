//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if _runtime(_ObjC)

import SwiftShims

@_silgen_name("swift_stdlib_CFSetGetValues")
@usableFromInline
internal
func _stdlib_CFSetGetValues(_ nss: _NSSet, _: UnsafeMutablePointer<AnyObject>)

/// Equivalent to `NSSet.allObjects`, but does not leave objects on the
/// autorelease pool.
@inlinable
internal func _stdlib_NSSet_allObjects(
  _ nss: _NSSet
) -> _HeapBuffer<Int, AnyObject> {
  let count = nss.count
  let storage = _HeapBuffer<Int, AnyObject>(
    _HeapBufferStorage<Int, AnyObject>.self, count, count)
  _stdlib_CFSetGetValues(nss, storage.baseAddress)
  return storage
}

extension _NativeSet { // Bridging
  @usableFromInline
  internal __consuming func bridged() -> _NSSet {
    // We can zero-cost bridge if our keys are verbatim
    // or if we're the empty singleton.

    // Temporary var for SOME type safety before a cast.
    let nsSet: _NSSetCore

    if _storage === _RawSetStorage.empty || count == 0 {
      nsSet = _RawSetStorage.empty
    } else if _isBridgedVerbatimToObjectiveC(Element.self) {
      nsSet = unsafeDowncast(_storage, to: _SetStorage<Element>.self)
    } else {
      nsSet = _SwiftDeferredNSSet(self)
    }

    // Cast from "minimal NSSet" to "NSSet"
    // Note that if you actually ask Swift for this cast, it will fail.
    // Never trust a shadow protocol!
    return unsafeBitCast(nsSet, to: _NSSet.self)
  }
}

/// An NSEnumerator that works with any _NativeSet of verbatim bridgeable
/// elements. Used by the various NSSet impls.
final internal class _SwiftSetNSEnumerator<Element: Hashable>
  : __SwiftNativeNSEnumerator, _NSEnumerator {

  @nonobjc internal var base: _NativeSet<Element>
  @nonobjc internal var bridgedElements: _BridgingHashBuffer?
  @nonobjc internal var nextBucket: _NativeSet<Element>.Bucket
  @nonobjc internal var endBucket: _NativeSet<Element>.Bucket

  @objc
  internal override required init() {
    _sanityCheckFailure("don't call this designated initializer")
  }

  internal init(_ base: __owned _NativeSet<Element>) {
    _sanityCheck(_isBridgedVerbatimToObjectiveC(Element.self))
    self.base = base
    self.bridgedElements = nil
    self.nextBucket = base.hashTable.startBucket
    self.endBucket = base.hashTable.endBucket
  }

  @nonobjc
  internal init(_ deferred: __owned _SwiftDeferredNSSet<Element>) {
    _sanityCheck(!_isBridgedVerbatimToObjectiveC(Element.self))
    self.base = deferred.native
    self.bridgedElements = deferred.bridgeElements()
    self.nextBucket = base.hashTable.startBucket
    self.endBucket = base.hashTable.endBucket
  }

  private func bridgedElement(at bucket: _HashTable.Bucket) -> AnyObject {
    _sanityCheck(base.hashTable.isOccupied(bucket))
    if let bridgedElements = self.bridgedElements {
      return bridgedElements[bucket]
    }
    return _bridgeAnythingToObjectiveC(base.uncheckedElement(at: bucket))
  }

  //
  // NSEnumerator implementation.
  //
  // Do not call any of these methods from the standard library!
  //

  @objc
  internal func nextObject() -> AnyObject? {
    if nextBucket == endBucket {
      return nil
    }
    let bucket = nextBucket
    nextBucket = base.hashTable.occupiedBucket(after: nextBucket)
    return self.bridgedElement(at: bucket)
  }

  @objc(countByEnumeratingWithState:objects:count:)
  internal func countByEnumerating(
    with state: UnsafeMutablePointer<_SwiftNSFastEnumerationState>,
    objects: UnsafeMutablePointer<AnyObject>,
    count: Int
  ) -> Int {
    var theState = state.pointee
    if theState.state == 0 {
      theState.state = 1 // Arbitrary non-zero value.
      theState.itemsPtr = AutoreleasingUnsafeMutablePointer(objects)
      theState.mutationsPtr = _fastEnumerationStorageMutationsPtr
    }

    if nextBucket == endBucket {
      state.pointee = theState
      return 0
    }

    // Return only a single element so that code can start iterating via fast
    // enumeration, terminate it, and continue via NSEnumerator.
    let unmanagedObjects = _UnmanagedAnyObjectArray(objects)
    unmanagedObjects[0] = self.bridgedElement(at: nextBucket)
    nextBucket = base.hashTable.occupiedBucket(after: nextBucket)
    state.pointee = theState
    return 1
  }
}

/// This class exists for Objective-C bridging. It holds a reference to a
/// _NativeSet, and can be upcast to NSSelf when bridging is necessary.  This is
/// the fallback implementation for situations where toll-free bridging isn't
/// possible. On first access, a _NativeSet of AnyObject will be constructed
/// containing all the bridged elements.
final internal class _SwiftDeferredNSSet<Element: Hashable>
  : __SwiftNativeNSSet, _NSSetCore {

  // This stored property must be stored at offset zero.  We perform atomic
  // operations on it.
  //
  // Do not access this property directly.
  @nonobjc
  private var _bridgedElements_DoNotUse: AnyObject?

  /// The unbridged elements.
  internal var native: _NativeSet<Element>

  internal init(_ native: __owned _NativeSet<Element>) {
    _sanityCheck(native.count > 0)
    _sanityCheck(!_isBridgedVerbatimToObjectiveC(Element.self))
    self.native = native
    super.init()
  }

  /// Returns the pointer to the stored property, which contains bridged
  /// Set elements.
  @nonobjc
  private var _bridgedElementsPtr: UnsafeMutablePointer<AnyObject?> {
    return _getUnsafePointerToStoredProperties(self)
      .assumingMemoryBound(to: Optional<AnyObject>.self)
  }

  /// The buffer for bridged Set elements, if present.
  @nonobjc
  private var _bridgedElements: _BridgingHashBuffer? {
    guard let ref = _stdlib_atomicLoadARCRef(object: _bridgedElementsPtr) else {
      return nil
    }
    return unsafeDowncast(ref, to: _BridgingHashBuffer.self)
  }

  /// Attach a buffer for bridged Set elements.
  @nonobjc
  private func _initializeBridgedElements(_ storage: _BridgingHashBuffer) {
    _stdlib_atomicInitializeARCRef(
      object: _bridgedElementsPtr,
      desired: storage)
  }

  @nonobjc
  internal func bridgeElements() -> _BridgingHashBuffer {
    if let bridgedElements = _bridgedElements { return bridgedElements }

    // Allocate and initialize heap storage for bridged objects.
    let bridged = _BridgingHashBuffer.allocate(
      owner: native._storage,
      hashTable: native.hashTable)
    for bucket in native.hashTable {
      let object = _bridgeAnythingToObjectiveC(
        native.uncheckedElement(at: bucket))
      bridged.initialize(at: bucket, to: object)
    }

    // Atomically put the bridged elements in place.
    _initializeBridgedElements(bridged)
    return _bridgedElements!
  }

  @objc
  internal required init(objects: UnsafePointer<AnyObject?>, count: Int) {
    _sanityCheckFailure("don't call this designated initializer")
  }

  @objc(copyWithZone:)
  internal func copy(with zone: _SwiftNSZone?) -> AnyObject {
    // Instances of this class should be visible outside of standard library as
    // having `NSSet` type, which is immutable.
    return self
  }

  @objc(member:)
  internal func member(_ object: AnyObject) -> AnyObject? {
    guard let element = _conditionallyBridgeFromObjectiveC(object, Element.self)
    else { return nil }

    let (bucket, found) = native.find(element)
    guard found else { return nil }
    let bridged = bridgeElements()
    return bridged[bucket]
  }

  @objc
  internal func objectEnumerator() -> _NSEnumerator {
    return _SwiftSetNSEnumerator<Element>(self)
  }

  @objc
  internal var count: Int {
    return native.count
  }

  @objc(countByEnumeratingWithState:objects:count:)
  internal func countByEnumerating(
    with state: UnsafeMutablePointer<_SwiftNSFastEnumerationState>,
    objects: UnsafeMutablePointer<AnyObject>?,
    count: Int
  ) -> Int {
    defer { _fixLifetime(self) }
    let hashTable = native.hashTable

    var theState = state.pointee
    if theState.state == 0 {
      theState.state = 1 // Arbitrary non-zero value.
      theState.itemsPtr = AutoreleasingUnsafeMutablePointer(objects)
      theState.mutationsPtr = _fastEnumerationStorageMutationsPtr
      theState.extra.0 = CUnsignedLong(hashTable.startBucket.offset)
    }

    // Test 'objects' rather than 'count' because (a) this is very rare anyway,
    // and (b) the optimizer should then be able to optimize away the
    // unwrapping check below.
    if _slowPath(objects == nil) {
      return 0
    }

    let unmanagedObjects = _UnmanagedAnyObjectArray(objects!)
    var bucket = _HashTable.Bucket(offset: Int(theState.extra.0))
    let endBucket = hashTable.endBucket
    _precondition(bucket == endBucket || hashTable.isOccupied(bucket),
      "Invalid fast enumeration state")

    // Only need to bridge once, so we can hoist it out of the loop.
    let bridgedElements = bridgeElements()

    var stored = 0
    for i in 0..<count {
      if bucket == endBucket { break }
      unmanagedObjects[i] = bridgedElements[bucket]
      stored += 1
      bucket = hashTable.occupiedBucket(after: bucket)
    }
    theState.extra.0 = CUnsignedLong(bucket.offset)
    state.pointee = theState
    return stored
  }
}

@usableFromInline
@_fixed_layout
internal struct _CocoaSet {
  @usableFromInline
  internal let object: _NSSet

  @inlinable
  internal init(_ object: __owned _NSSet) {
    self.object = object
  }
}

extension _CocoaSet {
  @usableFromInline
  @_effects(releasenone)
  internal func member(for index: Index) -> AnyObject {
    return index.element
  }

  @inlinable
  internal func member(for element: AnyObject) -> AnyObject? {
    return object.member(element)
  }
}

extension _CocoaSet: Equatable {
  @usableFromInline
  internal static func ==(lhs: _CocoaSet, rhs: _CocoaSet) -> Bool {
    return _stdlib_NSObject_isEqual(lhs.object, rhs.object)
  }
}

extension _CocoaSet: _SetBuffer {
  @usableFromInline
  internal typealias Element = AnyObject

  @inlinable
  internal var startIndex: Index {
    return Index(self, startIndex: ())
  }

  @inlinable
  internal var endIndex: Index {
    return Index(self, endIndex: ())
  }

  @inlinable
  internal func index(after i: Index) -> Index {
    var i = i
    formIndex(after: &i)
    return i
  }

  @usableFromInline
  @_effects(releasenone)
  internal func formIndex(after i: inout Index) {
    _precondition(i.base.object === self.object, "Invalid index")
    _precondition(i.currentKeyIndex < i.allKeys.value,
      "Cannot increment endIndex")
    i.currentKeyIndex += 1
  }

  @usableFromInline
  internal func index(for element: AnyObject) -> Index? {
    // Fast path that does not involve creating an array of all keys.  In case
    // the key is present, this lookup is a penalty for the slow path, but the
    // potential savings are significant: we could skip a memory allocation and
    // a linear search.
    if !contains(element) {
      return nil
    }

    let allKeys = _stdlib_NSSet_allObjects(object)
    var keyIndex = -1
    for i in 0..<allKeys.value {
      if _stdlib_NSObject_isEqual(element, allKeys[i]) {
        keyIndex = i
        break
      }
    }
    _sanityCheck(keyIndex >= 0,
        "Key was found in fast path, but not found later?")
    return Index(self, allKeys, keyIndex)
  }

  @inlinable
  internal var count: Int {
    return object.count
  }

  @inlinable
  internal func contains(_ element: AnyObject) -> Bool {
    return object.member(element) != nil
  }

  @usableFromInline
  internal func element(at i: Index) -> AnyObject {
    let element: AnyObject? = i.element
    _sanityCheck(element != nil, "Item not found in underlying NSSet")
    return element!
  }
}

extension _CocoaSet {
  @_fixed_layout // FIXME(sil-serialize-all)
  @usableFromInline
  internal struct Index {
    // Assumption: we rely on NSDictionary.getObjects when being
    // repeatedly called on the same NSDictionary, returning items in the same
    // order every time.
    // Similarly, the same assumption holds for NSSet.allObjects.

    /// A reference to the NSSet, which owns members in `allObjects`,
    /// or `allKeys`, for NSSet and NSDictionary respectively.
    @usableFromInline // FIXME(sil-serialize-all)
    internal let base: _CocoaSet
    // FIXME: swift-3-indexing-model: try to remove the cocoa reference, but
    // make sure that we have a safety check for accessing `allKeys`.  Maybe
    // move both into the dictionary/set itself.

    /// An unowned array of keys.
    @usableFromInline // FIXME(sil-serialize-all)
    internal var allKeys: _HeapBuffer<Int, AnyObject>

    /// Index into `allKeys`
    @usableFromInline // FIXME(sil-serialize-all)
    internal var currentKeyIndex: Int

    @inlinable // FIXME(sil-serialize-all)
    internal init(_ base: __owned _CocoaSet, startIndex: ()) {
      self.base = base
      self.allKeys = _stdlib_NSSet_allObjects(base.object)
      self.currentKeyIndex = 0
    }

    @inlinable // FIXME(sil-serialize-all)
    internal init(_ base: __owned _CocoaSet, endIndex: ()) {
      self.base = base
      self.allKeys = _stdlib_NSSet_allObjects(base.object)
      self.currentKeyIndex = allKeys.value
    }

    @inlinable // FIXME(sil-serialize-all)
    internal init(
      _ base: __owned _CocoaSet,
      _ allKeys: __owned _HeapBuffer<Int, AnyObject>,
      _ currentKeyIndex: Int
    ) {
      self.base = base
      self.allKeys = allKeys
      self.currentKeyIndex = currentKeyIndex
    }
  }
}

extension _CocoaSet.Index {
  @inlinable
  @nonobjc
  internal var element: AnyObject {
    _precondition(currentKeyIndex < allKeys.value,
      "Attempting to access Set elements using an invalid index")
    return allKeys[currentKeyIndex]
  }

  @usableFromInline
  @nonobjc
  internal var age: Int32 {
    @_effects(releasenone)
    get {
      return _HashTable.age(for: base.object)
    }
  }
}

extension _CocoaSet.Index: Equatable {
  @inlinable
  internal static func == (lhs: _CocoaSet.Index, rhs: _CocoaSet.Index) -> Bool {
    _precondition(lhs.base.object === rhs.base.object,
      "Comparing indexes from different sets")
    return lhs.currentKeyIndex == rhs.currentKeyIndex
  }
}

extension _CocoaSet.Index: Comparable {
  @inlinable
  internal static func < (lhs: _CocoaSet.Index, rhs: _CocoaSet.Index) -> Bool {
    _precondition(lhs.base.object === rhs.base.object,
      "Comparing indexes from different sets")
    return lhs.currentKeyIndex < rhs.currentKeyIndex
  }
}

extension _CocoaSet: Sequence {
  @usableFromInline
  final internal class Iterator {
    // Cocoa Set iterator has to be a class, otherwise we cannot
    // guarantee that the fast enumeration struct is pinned to a certain memory
    // location.

    // This stored property should be stored at offset zero.  There's code below
    // relying on this.
    internal var _fastEnumerationState: _SwiftNSFastEnumerationState =
      _makeSwiftNSFastEnumerationState()

    // This stored property should be stored right after
    // `_fastEnumerationState`.  There's code below relying on this.
    internal var _fastEnumerationStackBuf = _CocoaFastEnumerationStackBuf()

    internal let base: _CocoaSet

    internal var _fastEnumerationStatePtr:
      UnsafeMutablePointer<_SwiftNSFastEnumerationState> {
      return _getUnsafePointerToStoredProperties(self).assumingMemoryBound(
        to: _SwiftNSFastEnumerationState.self)
    }

    internal var _fastEnumerationStackBufPtr:
      UnsafeMutablePointer<_CocoaFastEnumerationStackBuf> {
      return UnsafeMutableRawPointer(_fastEnumerationStatePtr + 1)
        .assumingMemoryBound(to: _CocoaFastEnumerationStackBuf.self)
    }

    // These members have to be word-sized integers, they cannot be limited to
    // Int8 just because our storage holds 16 elements: fast enumeration is
    // allowed to return inner pointers to the container, which can be much
    // larger.
    internal var itemIndex: Int = 0
    internal var itemCount: Int = 0

    internal init(_ base: __owned _CocoaSet) {
      self.base = base
    }
  }

  @usableFromInline
  internal __consuming func makeIterator() -> Iterator {
    return Iterator(self)
  }
}

extension _CocoaSet.Iterator: IteratorProtocol {
  @usableFromInline
  internal typealias Element = AnyObject

  @usableFromInline
  internal func next() -> Element? {
    if itemIndex < 0 {
      return nil
    }
    let base = self.base
    if itemIndex == itemCount {
      let stackBufCount = _fastEnumerationStackBuf.count
      // We can't use `withUnsafeMutablePointer` here to get pointers to
      // properties, because doing so might introduce a writeback storage, but
      // fast enumeration relies on the pointer identity of the enumeration
      // state struct.
      itemCount = base.object.countByEnumerating(
        with: _fastEnumerationStatePtr,
        objects: UnsafeMutableRawPointer(_fastEnumerationStackBufPtr)
          .assumingMemoryBound(to: AnyObject.self),
        count: stackBufCount)
      if itemCount == 0 {
        itemIndex = -1
        return nil
      }
      itemIndex = 0
    }
    let itemsPtrUP =
    UnsafeMutableRawPointer(_fastEnumerationState.itemsPtr!)
      .assumingMemoryBound(to: AnyObject.self)
    let itemsPtr = _UnmanagedAnyObjectArray(itemsPtrUP)
    let key: AnyObject = itemsPtr[itemIndex]
    itemIndex += 1
    return key
  }
}

//===--- Bridging ---------------------------------------------------------===//

extension Set {
  @inlinable
  public __consuming func _bridgeToObjectiveCImpl() -> _NSSetCore {
    switch _variant {
    case .native(let nativeSet):
      return nativeSet.bridged()
    case .cocoa(let cocoaSet):
      return cocoaSet.object
    }
  }

  /// Returns the native Dictionary hidden inside this NSDictionary;
  /// returns nil otherwise.
  public static func _bridgeFromObjectiveCAdoptingNativeStorageOf(
    _ s: __owned AnyObject
  ) -> Set<Element>? {

    // Try all three NSSet impls that we currently provide.

    if let deferred = s as? _SwiftDeferredNSSet<Element> {
      return Set(_native: deferred.native)
    }

    if let nativeStorage = s as? _SetStorage<Element> {
      return Set(_native: _NativeSet(nativeStorage))
    }

    if s === _RawSetStorage.empty {
      return Set()
    }

    // FIXME: what if `s` is native storage, but for different key/value type?
    return nil
  }
}

#endif // _runtime(_ObjC)
