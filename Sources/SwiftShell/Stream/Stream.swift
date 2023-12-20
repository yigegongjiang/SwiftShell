//
// Released under the MIT License (MIT), http://opensource.org/licenses/MIT
//
// Copyright (c) 2015 Kåre Morstøl, NotTooBad Software (nottoobadsoftware.com)
//

import Foundation

extension FileHandle {
  /*
   这里根据 availableData 从文件指针获取到文件尾的数据，并将文件指针更新到文件尾。（第一次为默认打开文件，文件指针位于文件头。）
   
   对于日志文件等持续写入的场景，可以通过该 api，持续的对文件进行新增内容的读取。
   
   这种方式为主动获取，外部需要有定时的能力，主动调用 readSome 来获取距离上一次的新增数据。
   */
	public func readSome(encoding: String.Encoding) -> String? {
		let data = self.availableData

		guard !data.isEmpty else { return nil }
		guard let result = String(data: data, encoding: encoding) else {
			fatalError("Could not convert binary data to text.")
		}

		return result
	}

  /*
   强制从文件指针获取到文件尾。对于默认打开的文件，文件指针处于文件头。
   这种方式为主动获取，一次性获取全部的文件内容。
   */
	public func read(encoding: String.Encoding) -> String {
		let data = self.readDataToEndOfFile()

		guard let result = String(data: data, encoding: encoding) else {
			fatalError("Could not convert binary data to text.")
		}

		return result
	}
}

extension FileHandle {
  /*
   Filehandle 的文件写入本身只支持二进制流。这里开放语法糖，支持外部文本输入调用。
   
   FileHandle 是文件的抽象描述，而文件不仅仅是磁盘文件，对于硬件如显示器也是文件。
   如果当前 FileHandle 是默认输出，则 write 的内容将显示在显示器中。
   */
	public func write(_ string: String, encoding: String.Encoding = .utf8) {
		#if !(os(macOS) || os(tvOS))
		guard !string.isEmpty else { return }
		#endif
		guard let data = string.data(using: encoding, allowLossyConversion: false) else {
			fatalError("Could not convert text to binary data.")
		}
		self.write(data)
	}
}

/*
 ！！！`ReadableStream`和`WritableStream`为命令行操作的核心 Api。
 ！！！read 和 write 是一套 stream 协议，通过 `代理模式` 操作内部持有 filehandle 对象。
 ！！！filehandle 对象是两套协议的核心，具体而言，这两套协议主要的工作，就是对 filehandle 进行封装，使得外部无需感知具体的文件操作。
 
 命令行执行过程中，需要通过 Process Api 跨进程获取数据，是通过对 FileHandle 进行写入和读取完成的。
 默认情况下，FileHandle 可通过默认的 stdin/stdout 完成，即键盘输入和显示器输出，此时外部无法拦截并捕获数据。
 
 `ReadableStream`和`WritableStream` 则定义了一套接口，以对 FileHandle 进行 read/write，同时将 FileHandle 提供给 Process。
 如此，Process 命令的 read 和 write，转为由当前 sdk 控制。
 
 read 和 write 是相对当前使用者为参考系的。
 可以对符合 read 协议的对象`直接读取`，也可以将其 filehandle 对象提供给 process，process 对自动对 filehandle 进行`读取`。
 可以对符合 write 协议的对象`直接写入`，也可以将其 filehandle 对象提供给 process，process 对自动对 filehandle 进行`写入`。
 对于不同的操作对象，需要及时调整相应的对象，以使得操作过程中可以顺利执行 `读取` 和 `写入` 操作。
 
 示例 1：
 可以自定义 file path 以打开一个文件并生成 `ReadableStream` 对象。
 此时可以通过 read/readxxx/onOutput 等语法糖 api 主动或者被动的拿到文件数据。
 也可以将该对象的 filehandle 给到 Process stdin ，此时命令行子进程会直接操作 filehandle 读取内容作为当前命令的输入。相似于管道。
 举例子(伪代码)：open("filepath").toFileReadableStream().run("cat")
 
 示例 2：
 对于 String/NSData 等对象，它们自身存储有数据，这些数据可以经过一些自定义操作并输出 `ReadableStream` 对象。而后，外部可以操作该对象以读取 String/NSData 等内容。
 如 String，可以定义一个 Pipe 管道(Pipe 本质就是 FileHandle)，将 String 文本通过 pipe.writeFileHandle 写入管道，此时就可以通过 pipe.readFileHandle 进行读取。
 举例子(伪代码)："this is String".toStringReadableStream().run("cat")
 */
public protocol ReadableStream: AnyObject, TextOutputStreamable, CommandRunning {
	var encoding: String.Encoding { get set }
	var filehandle: FileHandle { get }

  /*
   下面两个 api，通过代理模式，对 FileHandle 对同名扩展进行访问，使得外部无需感知到 Filehandle 的存在。
   */
	func readSome() -> String?
	func read() -> String
}

extension ReadableStream {
  
  /*
   FileHandle 代理模式的实现。
   */
	public func readSome() -> String? {
		filehandle.readSome(encoding: encoding)
	}
	public func read() -> String {
		filehandle.read(encoding: encoding)
	}

  /*
   将文件流按行延迟读取(文件内容是二进制的，需要有 \n 换行符，这里会根据 \n 符号进行分割)。
   1. lines 需要外部通过 for...in 或 next 等迭代器方式读取，读取值为行文本。
   2. 还需要在更外层以定时器等方式调用，以主动获取文件中随时可能新增的内容。
   
   for i in 0...1000 { -> 定时器按时调用 lines 接口，以持续获取文件新增内容，如`3\n5\n8\n12\n`
     for v in input.lines() { -> 每次获取的内容根据 \n 进行分割，每次输出一项，如 `3`、`5`、`8`、`12`
       print("the line is:\(v)")
     }
     Thread.sleep(forTimeInterval: 4)
   }
   
   lines 的具体实现，依赖 lazy-split.swift 文件的双层 lazy 迭代器，实现的非常巧妙。相见该文件。
   */
	public func lines() -> LazySequence<AnySequence<String>> {
		return AnySequence(PartialSourceLazySplitSequence({ self.readSome() }, separator: "\n").map(String.init)).lazy
	}

  /*
   这里提供一个语法糖，直接对 `ReadableStream` 对象调用 `write` 接口将读取的内容输出到 `WritableStream`，相当于 Pipe 操作。
   
   readObj.write(writeObj)
   */
	public func write<Target: TextOutputStream>(to target: inout Target) {
		while let text = self.readSome() { target.write(text) }
	}

  /*
   相见 `Command.swift` 文件中 `CommandRunning` 协议的介绍。
   
   这里提供 `ReadableStream` 对象的上下文，以实现直接对 `ReadableStream` 对象的链式命令调用。
   
   上下文中的 stdin，指定为当前对象。
   这样在初始化 Process 的时候，会将 `ReadableStream` 的 filehandle 给到 Process stdin，由 Process 读取 filehandle 的内容作为下一个命令的输入。
   
   举例子(伪代码)：
   `open("filepath").toFileReadableStream().run("cat")`
   这里通过打开一个文件并转换为 readableStream 对象，而后因实现了 `CommandRunning` 协议，可使用协议中定义的 run 命令。
   此时 run 命令会使用当前 readableStream 对象的 filehandle 作为命令的输入。
   */
	public var context: Context {
		var context = CustomContext(main)
		context.stdin = self
		return context
	}

  /*
   同 `func readSome() -> String?`，不过直接读取二进制内容并返回。由调用方进行二进制原始内容的解析处理。
   */
	public func readSomeData() -> Data? {
		let data = filehandle.availableData
		return !data.isEmpty ? data : nil
	}

  /*
   同 `func read() -> String`，解析同上。
   */
	@discardableResult public func readData() -> Data {
		filehandle.readDataToEndOfFile()
	}
}

extension ReadableStream {
  /*
   这里通过设置 FileHandle 的监听回调，主动获取文件中的新增数据并返回给业务。
   
   和 `func readSome() -> String?` 的区别是，业务不需要设置定时器来捕获随时可能新增的数据，只需要被动接收数据就可以。
   */
	public func onOutput(_ handler: @escaping (ReadableStream) -> Void) {
		filehandle.readabilityHandler = { [weak self] _ in
			self.map(handler)
		}
	}
	public func onStringOutput(_ handler: @escaping (String) -> Void) {
		self.onOutput { stream in
			if let output = stream.readSome() {
				handler(output)
			}
		}
	}
}

/*
 和 `ReadableStream` 相对应。写入没有读取需要很多中格式包装，所以 Api 比较简单。
 */
public protocol WritableStream: AnyObject, TextOutputStream {
	var encoding: String.Encoding { get set }
	var filehandle: FileHandle { get }

  /*
   下面两个 api，通过代理模式操作 FileHandle 对象，使得外部无需感知到 Filehandle 的存在。
   */
	func write(_ x: String)
	func close()
}

extension WritableStream {
	public func write(_ x: String) {
		filehandle.write(x, encoding: encoding)
	}
	public func close() {
		filehandle.closeFile()
	}

  /*
   是对 write 的格式包装。模拟 Swift 里面 foundation print 函数的实现。
   在 `FileHandle.write(_:encoding:)` 中，我们说到若当前 FileHandle 是默认输出，则写入文本会显示在显示器上。
   
   这里定义 print Api，会对写入的内容进行一些格式化，然后使用自定义的分割符输出到显示器中。
   
   如：
   let w = FileHandleStream(FileHandle.standardInput, encoding: .utf8) // 显示器做标准输出，FileHandleStream 实现了 `WritableStream` 协议
   w.write("1\n2\n3\n")
   // 1
   // 2
   // 3
   w.print(1,"2",3)
   // 1 2 3
   */
	@warn_unqualified_access
	public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
		var iterator = items.lazy.map(String.init(describing:)).makeIterator()
		iterator.next().map(write)
		while let item = iterator.next() {
			write(separator)
			write(item)
		}
		write(terminator)
	}

	public func write(data: Data) {
		filehandle.write(data)
	}
}

/*
 这里作者自定义了一个屏幕输出 Filehandle 对象。
 本来可以直接通过 `FileHandleStream(FileHandle.standardInput, encoding: self.encoding)` 进行定义，无需专门写一个屏幕输出对象。
 
 不过，考虑到 Swift Foundation print api 内部肯定有一些对 filehandle.write 对包装逻辑。
 这里作者为了严丝合缝的对标开发过程中的 print 屏幕输出，重写了 write api，直接桥接到 系统 print 函数中。
 */
public class StdoutStream: WritableStream {
	public var encoding: String.Encoding = .utf8
	public let filehandle = FileHandle.standardOutput

	private init() {}

	public static var `default`: StdoutStream { StdoutStream() }

	public func write(_ x: String) {
		Swift.print(x, terminator: "")
	}

	public func close() {}
}

/*
 这里是点睛之笔，作者聚合了 read 和 write 的两个包装协议，使得使用者只需要一套 api 即可定义同时符合两条协议的实现。
 具体是 read 还是 write，是通过 filehandle 和 使用者具体场景来区分的。即：如果使用者给的 filehandle 是 read handle，则使用者可以放心使用 read api，但需要自行保障不使用 write 操作。
 对同一个文件将 read 和 write 使用两个 filehandle 区分开，是一个良好的习惯，这会减少文件的 seek 文件指针紊乱带来的麻烦。
 
 当然，使用者也可以在具体场景下抛弃这个习惯，定义一个 filehandle 具有 可读可写 属性。`FileHandle(forUpdating: path)，forUpdating 可读可写`
 这个时候，当前的聚合对象，可以同时执行 read 和 write 操作。但这样依旧还是不建议的。
 */
public class FileHandleStream: ReadableStream, WritableStream {
	public let filehandle: FileHandle
	public var encoding: String.Encoding

	public init(_ filehandle: FileHandle, encoding: String.Encoding) {
		self.filehandle = filehandle
		self.encoding = encoding
	}
}

/*
 作者自定义了一套管道的实现。
 实际上是对系统管道的两个 filehandle 进行剥离，从而抽象出符合当前 `WritableStream` 和 `ReadableStream` 的形式，以方便使用这两套协议的 api。
 */
public func streams() -> (WritableStream, ReadableStream) {
	let pipe = Pipe()
	return (FileHandleStream(pipe.fileHandleForWriting, encoding: .utf8), FileHandleStream(pipe.fileHandleForReading, encoding: .utf8))
}
