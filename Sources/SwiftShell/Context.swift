/*
 * Released under the MIT License (MIT), http://opensource.org/licenses/MIT
 *
 * Copyright (c) 2015 Kåre Morstøl, NotTooBad Software (nottoobadsoftware.com)
 *
 */

/*
 Context 上下文是命令执行的基础。
 因为命令需要提供两个核心的参数，即输入和输出 filehandle。正常而言，我们只需要在执行命令的时候，及时补充这两个 filehandle 即可。
 
 当需要执行命令的场景复杂之后，如 file/String/NSData 等各类对象均可以巧妙的调用命令接口，这时候就需要对 filehandle 进行统一管理或者定义一套标准。
 这样，在使用命令场景的时候，内部无需做任何改动，只需要外部使用者，在各自场景下提供对应的 filehandle。
 
 比如，当需要对 String 字符串直接执行命令的时候，外部需要扩展 String 的实现，以将 String 的内容写入到一个 filehandle 里面并提供给 Process 子进程。
 当然，对于 String 的实现，作者已经写好，相见 `String.swift` 文件源码。类似的还有 `Files.swift` 文件源码。
 
 以下内容不在做更多解读，本质就是约定了不同场景下命令执行的环境信息约定，供不同场景进行自定义。其中 main 是默认场景，即标准输入(键盘)和输出(显示器)。
 */

import Foundation

public protocol Context: CustomDebugStringConvertible {
  // 这里用于将父进程的环境变量信息，携带到子进程供其使用。具体可参考：[Shell 和进程](https://www.yigegongjiang.com/2022/Shell%E5%92%8C%E8%BF%9B%E7%A8%8B/#0x03-Shell-%E5%92%8C-SubShell)
	var env: [String: String] { get set }
	var stdin: ReadableStream { get set }
	var stdout: WritableStream { get set }
	var stderror: WritableStream { get set }

	/**
	 The current working directory.

	 Must be used instead of `run("cd", "...")` because all the `run` commands are executed in a
	 separate process and changing the directory there will not affect the rest of the Swift script.
	 */
	var currentdirectory: String { get set }
}

extension Context {
	/** A textual representation of this instance, suitable for debugging. */
	public var debugDescription: String {
		var result = ""
		debugPrint("stdin:", stdin, "stdout:", stdout, "stderror:", stderror, "currentdirectory:", currentdirectory, to: &result)
		debugPrint("env:", env, to: &result)
		return result
	}
}

public struct CustomContext: Context, CommandRunning {
	public var env: [String: String]
	public var stdin: ReadableStream
	public var stdout: WritableStream
	public var stderror: WritableStream

	/**
	 The current working directory.

	 Must be used instead of `run("cd", "...")` because all the `run` commands are executed in a
	 separate process and changing the directory there will not affect the rest of the Swift script.
	 */
	public var currentdirectory: String

	/** Creates a blank CustomContext where env and stdin are empty, stdout and stderror discard everything and
	 currentdirectory is the current working directory. */
	public init() {
		let encoding = String.Encoding.utf8
		env = [String: String]()
		stdin = FileHandleStream(FileHandle.nullDevice, encoding: encoding)
		stdout = FileHandleStream(FileHandle.nullDevice, encoding: encoding)
		stderror = FileHandleStream(FileHandle.nullDevice, encoding: encoding)
		currentdirectory = main.currentdirectory
	}

	/** Creates an identical copy of another Context. */
	public init(_ context: Context) {
		env = context.env
		stdin = context.stdin
		stdout = context.stdout
		stderror = context.stderror
		currentdirectory = context.currentdirectory
	}
}

private func createTempdirectory() -> String {
	let name = URL(fileURLWithPath: main.path).lastPathComponent
	let tempdirectory = URL(fileURLWithPath: NSTemporaryDirectory()) + (name + "-" + ProcessInfo.processInfo.globallyUniqueString)
	do {
		try Files.createDirectory(atPath: tempdirectory.path, withIntermediateDirectories: true, attributes: nil)
		return tempdirectory.path + "/"
	} catch let error as NSError {
		exit(errormessage: "Could not create new temporary directory '\(tempdirectory)':\n\(error.localizedDescription)", errorcode: error.code)
	} catch {
		exit(errormessage: "Unexpected error: \(error)")
	}
}

extension CommandLine {
	/** Workaround for nil crash in CommandLine.arguments when run in Xcode. */
	static var safeArguments: [String] {
		self.argc == 0 ? [] : self.arguments
	}
}

public final class MainContext: Context, CommandRunning {
	/// The default character encoding used throughout SwiftShell.
	/// Only affects stdin, stdout and stderror if they have not been used yet.
	public var encoding = String.Encoding.utf8 // TODO: get encoding from environmental variable LC_CTYPE.

	public lazy var env = ProcessInfo.processInfo.environment as [String: String]
	public lazy var stdin: ReadableStream = {
		FileHandleStream(FileHandle.standardInput, encoding: self.encoding)
	}()

	public lazy var stdout: WritableStream = {
		let stdout = StdoutStream.default
		stdout.encoding = self.encoding
		return stdout
	}()

	public lazy var stderror: WritableStream = {
		FileHandleStream(FileHandle.standardError, encoding: self.encoding)
	}()

	/**
	 The current working directory.

	 Must be used instead of `run("cd", "...")` because all the `run` commands are executed in
	 separate processes and changing the directory there will not affect the rest of the Swift script.

	 This directory is also used as the base for relative URLs.
	 */
	public var currentdirectory: String {
		get { return Files.currentDirectoryPath + "/" }
		set {
			if !Files.changeCurrentDirectoryPath(newValue) {
				exit(errormessage: "Could not change the working directory to \(newValue)")
			}
		}
	}

	/**
	 The tempdirectory is unique each time a script is run and is created the first time it is used.
	 It lies in the user's temporary directory and will be automatically deleted at some point.
	 */
	public private(set) lazy var tempdirectory: String = createTempdirectory()

	/** The arguments this executable was launched with. Use main.path to get the path. */
	public private(set) lazy var arguments: [String] = Array(CommandLine.safeArguments.dropFirst())

	/** The path to the currently running executable. Will be empty in playgrounds. */
	public private(set) lazy var path: String = CommandLine.safeArguments.first ?? ""

	fileprivate init() {}
}

public let main = MainContext()
