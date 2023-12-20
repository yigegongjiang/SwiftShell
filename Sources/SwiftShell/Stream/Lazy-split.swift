//
// Released under the MIT License (MIT), http://opensource.org/licenses/MIT
//
// Copyright (c) 2015 Kåre Morstøl, NotTooBad Software (nottoobadsoftware.com)
//

/*
 当前文件，设计了两套串联的延迟迭代器，用于持续对闭包进行调用并解析闭包的输出内容。
 
 # 当前设计目的
 当前的设计，是为延迟读取文本服务的。 详见 `Streram.swift` 文件中 `ReadableStream.lines()` 注释说明。
 
 比如，某个日志文件通过其他进程每 1 秒写入一个数字和换行符，如 `1\n2\n3\n4\n5\n6\n7\n8\n9 ...` 内容，
 要对当前文件持续读取，可以通过 filehandle 的 readabilityHandler 回调来做，这是被动监听的方式，详见 `ReadableStream.onOutput(_:)`。
 还有一种主动读取的方式，即通过 filehandle 的 availableData 属性，详见 `FileHandle.readSome(encoding:)`。
 
 通过定时调用 readSome 接口可以拿到文本内容，如第 1 次读取为 `1\n2\n3\n`，第 2 次读取为 `4\n5\n6\n7\n`。
 但这对业务方来说可能不太友好，业务需要自行做解析。且每次解析的行数还不一致，比如这里第一次解析出来 1/2/3，第二次解析出来 4/5/6/7
 如果有一种方案，可以持续性的向业务输出 1、2、3、4、5 ，比如下面这样：
 ```
 for i in 0...1000 { -> 模拟定时操作，这里定时间隔为 0，立刻进行下次读取
   for v in input.lines() {
     print("the line is:\(v)") -> 持续性获取 1、2、3、4、5、6、7、8、9
     Thread.sleep(forTimeInterval: 0.5) -> 模拟业务处理数据，当前耗时 0.5s
   }
 }
 ```
 在以上代码中，业务获取数据的速度 0.5s 短于日志生产实际 1s，即消费者耗时小于生产者。
 当取不到数据的时候，`for v in input.lines()` 迭代器完成，走到下一个定时。
 那么业务会频繁的执行定时任务，有一半的时间都获取不到数据。能取到数据的时候均为独立的单行文本。
 
 如果把延迟修改为 3s，会是另一种情况。这个时候消费耗时大于生产耗时，定时操作基本就不会执行了，只会一直卡在 for...in 中持续的获取数据。
 因为此时 `for v in input.lines()` 迭代器一直可以获取到数据，从而不会停止。
 
 这种场景对业务来说会比较友好：
 1. 每次都能够获取到单独的行数据，避免了业务定时调用 readSome 获取到不同长度的数据后还要做行解析的操作。
 2. 若业务拿到数据后处理耗时较长，还能够不停的基于迭代器持续获取最新数据，避免了定时器可能会延迟的问题。（比如定时器 1分钟，那么下一次拿数据需要很久）
 
 # 技术方案
 
 作者的技术方案是通过两层嵌套的延迟迭代器来完成。
 第一层延迟迭代器，作为管家服务。主要是调用 readSome 获取最新数据，然后给第二层延迟迭代器消费。当数据消费完后，管家主动调用 readSome 再次获取最新数据，一直反复该流程。
 第二层延迟迭代器，主要对管家给到的数据进行 `行解析`，把每次解析的数据给到管家，管家再返回给业务。
 
 这样，基于 lazy Iterator 模式，通过 lines 接口将两层迭代器均封装在内部，给外部的实现就是源源不断的提供了行数据。
 */

extension Collection where Element: Equatable {
	/// Returns everything before the first occurrence of ‘separator’ as 'head', and everything after it as 'tail'.
	/// Including empty sequences if ‘separator’ is first or last.
	///
	/// If ‘separator’ is not found then ‘head’ contains everything and 'tail' is nil.
	func splitOnce(separator: Element) -> (head: SubSequence, tail: SubSequence?) {
		guard let nextindex = firstIndex(of: separator) else { return (self[...], nil) }
		return (self[..<nextindex], self[index(after: nextindex)...])
	}
}

/// A sequence from splitting a Collection lazily.
public struct LazySplitSequence<Base: Collection>: IteratorProtocol, LazySequenceProtocol where
	Base.Element: Equatable {
	public fileprivate(set) var remaining: Base.SubSequence?
	public let separator: Base.Element
	public let allowEmptySlices: Bool

	/// Creates a lazy sequence by splitting a Collection repeatedly.
	///
	/// - Parameters:
	///   - base: The Collection to split.
	///   - separator: The element of `base` to split over.
	///   - allowEmptySlices: If there are two or more separators in a row, or `base` begins or ends with
	///     a separator, should empty slices be emitted? Defaults to false.
	public init(_ base: Base, separator: Base.Element, allowEmptySlices: Bool = false) {
		self.separator = separator
		self.remaining = base[...]
		self.allowEmptySlices = allowEmptySlices
	}

	/// The contents of ‘base’ up to the next occurrence of ‘separator’.
	public mutating func next() -> Base.SubSequence? {
		guard let remaining = self.remaining else { return nil }
		let (head, tail) = remaining.splitOnce(separator: separator)
		self.remaining = tail
		return (!allowEmptySlices && head.isEmpty) ? next() : head
	}
}

extension LazyCollectionProtocol where Elements.Element: Equatable {
	/// Creates a lazy sequence by splitting this Collection repeatedly.
	///
	/// - Parameters:
	///   - separator: The element of this collection to split over.
	///   - allowEmptySlices: If there are two or more separators in a row, or this Collection begins or ends with
	///     a separator, should empty slices be emitted? Defaults to false.
	public func split(
		separator: Elements.Element, allowEmptySlices: Bool = false) -> LazySplitSequence<Elements> {
		LazySplitSequence(self.elements, separator: separator, allowEmptySlices: allowEmptySlices)
	}
}

/// A sequence from splitting a series of Collections lazily, as if they were one Collection.
public struct PartialSourceLazySplitSequence<Base: Collection>: IteratorProtocol, LazySequenceProtocol where
	Base.Element: Equatable,
	Base.SubSequence: RangeReplaceableCollection {
	private var gs: LazyMapSequence<AnyIterator<Base>, LazySplitSequence<Base>>.Iterator
	private var g: LazySplitSequence<Base>?

	/// Creates a lazy sequence by splitting a series of collections repeatedly, as if they were one collection.
	///
	/// - Parameters:
	///   - bases: A function which returns the next collection in the series each time it is called,
	///     or nil if there are no more collections.
	///   - separator: The element of ‘bases’ to split over.
	public init(_ bases: @escaping () -> Base?, separator: Base.Element) {
		gs = AnyIterator(bases).lazy.map {
			LazySplitSequence($0, separator: separator, allowEmptySlices: true).makeIterator()
		}.makeIterator()
	}

	/// The contents of ‘bases’ up to the next occurrence of ‘separator’.
	public mutating func next() -> Base.SubSequence? {
		// Requires g handling repeated calls to next() after it is empty.
		// When g.remaining becomes nil there is always one item left in g.
		guard let head = g?.next() else {
			self.g = self.gs.next()
			return self.g == nil ? nil : next()
		}
		if g?.remaining == nil, let next = next() {
			return head + next
		}
		return head
	}
}
