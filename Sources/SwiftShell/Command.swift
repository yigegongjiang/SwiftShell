/*
 * Released under the MIT License (MIT), http://opensource.org/licenses/MIT
 *
 * Copyright (c) 2015 Kåre Morstøl, NotTooBad Software (nottoobadsoftware.com)
 *
 */

import Dispatch
import Foundation

// MARK: exit

public func exit<T>(errormessage: T, errorcode: Int = 1, file: String = #file, line: Int = #line) -> Never {
	#if DEBUG
	main.stderror.print(file + ":\(line):", errormessage)
	#else
	main.stderror.print(errormessage)
	#endif
	exit(Int32(errorcode))
}

public func exit(_ error: Error, file: String = #file, line: Int = #line) -> Never {
	if let commanderror = error as? CommandError {
		exit(errormessage: commanderror, errorcode: commanderror.errorcode, file: file, line: line)
	} else {
		exit(errormessage: error.localizedDescription, errorcode: error._code, file: file, line: line)
	}
}

// MARK: CommandRunning

/*
 任何实现了该协议的对象，均可调用 `runxxx` 等命令以执行终端命令。
 
 该协议唯一的要求，即上下文。上下文中指定了当前命令执行的输入输出文件 FileHandle。
 对于上下文的描述，相见 `Context.swift` 文件顶部说明。
 
 可以认为，只要一个对象能够提供 Context 上下文，即可调用 `runxxx` 来执行终端命令。
 这样的设计，可以将命令 api 的调用设计的更加通用，不在仅仅局限于特定场景。
 同时，也可以非常方便形成管道式的链式调用。如：a.runxxx().runxxx()
 */
public protocol CommandRunning {
	var context: Context { get }
}

extension CommandRunning where Self: Context {
	public var context: Context { self }
}

extension CommandRunning {
	func createProcess(_ executable: String, args: [String]) -> Process {
    /*
     这里是一个巧妙的设计。对于 Process 而言，具体待执行的命令一直都具有平台通用性限制。
     在 Linux/Win 等不同系统上，用户可能将系统命令或者自定义命令放置于不同的位置。从而不能准确找到命令 path。
     
     作者这里通过自举的方式，在执行命令之前先准确找到命令 path，避免了多平台兼容性。
     */
		func path(for executable: String) -> String {
			guard !executable.contains("/") else {
				return executable
			}
			let path = self.run("/usr/bin/which", executable).stdout
			return path.isEmpty ? executable : path
		}

		let process = Process()
		process.arguments = args
		if #available(OSX 10.13, *) {
			process.executableURL = URL(fileURLWithPath: path(for: executable))
		} else {
			process.launchPath = path(for: executable)
		}

    // 这里用于将父进程的环境变量信息，携带到子进程供其使用。具体可参考：[Shell 和进程](https://www.yigegongjiang.com/2022/Shell%E5%92%8C%E8%BF%9B%E7%A8%8B/#0x03-Shell-%E5%92%8C-SubShell)
    process.environment = context.env
		if #available(OSX 10.13, *) {
			process.currentDirectoryURL = URL(fileURLWithPath: context.currentdirectory, isDirectory: true)
		} else {
			process.currentDirectoryPath = context.currentdirectory
		}

    /*
     这里是命令执行过程中跨进程通信实现的第一步，即注入 filehandle。
     通过 filehandle 对待执行命令提供输入参数，并获取输出信息。
     */
		process.standardInput = context.stdin.filehandle
		process.standardOutput = context.stdout.filehandle
		process.standardError = context.stderror.filehandle

		return process
	}
}

// MARK: CommandError

public enum CommandError: Error, Equatable {
	case returnedErrorCode(command: String, errorcode: Int)
	case inAccessibleExecutable(path: String)

	public var errorcode: Int {
		switch self {
		case let .returnedErrorCode(_, code):
			return code
		case .inAccessibleExecutable:
			return 127 // according to http://tldp.org/LDP/abs/html/exitcodes.html
		}
	}
}

extension CommandError: CustomStringConvertible {
	public var description: String {
		switch self {
		case let .inAccessibleExecutable(path):
			return "Could not execute file at path '\(path)'."
		case let .returnedErrorCode(command, code):
			return "Command '\(command)' returned with error code \(code)."
		}
	}
}

// MARK: run

/*
 专门为 run 命令接口设计。(共 4 个，run/runAsync/runAndPrint/runAsyncAndPrint)
 
 因为 run 命令是非异步的，所以需要同步执行完毕后，将执行过程产生的信息进行封装，并返回给调用者。
 */
public final class RunOutput {
	private let output: AsyncCommand
	private let rawStdout: Data
	private let rawStderror: Data

	/// The error from running the command, if any.
	public let error: CommandError?

	/// Launches command, reads all output from both standard output and standard error simultaneously,
	/// and waits until the command is finished.
	init(launch command: AsyncCommand) {
		var error: CommandError?
		var stdout = Data()
		var stderror = Data()
		let group = DispatchGroup()

    /*
     因为不在走 main/custom 上下文的输出（大概率是显示器输出），run 命令需要通过 `AsyncCommand` 对象改写 Process 的输出 filehandle
     
     这里在命令执行完毕后，通过 filehandle 读取命令输出结果。并进行适当的数据组装，以供业务消费。
     */
		do {
			// launch and read stdout and stderror.
			// see https://github.com/kareman/SwiftShell/issues/52
			try command.process.launchThrowably()

			if command.stdout.filehandle.fileDescriptor != command.stderror.filehandle.fileDescriptor {
				DispatchQueue.global().async(group: group) {
					stderror = command.stderror.readData()
				}
			}

			stdout = command.stdout.readData()
			try command.finish()
		} catch let commandError as CommandError {
			error = commandError
		} catch {
			assertionFailure("Unexpected error: \(error)")
		}

		group.wait()

		self.rawStdout = stdout
		self.rawStderror = stderror
		self.output = command
		self.error = error
	}

	/// If text is single-line, trim it.
	private static func cleanUpOutput(_ text: String) -> String {
		let afterfirstnewline = text.firstIndex(of: "\n").map(text.index(after:))
		return (afterfirstnewline == nil || afterfirstnewline == text.endIndex)
			? text.trimmingCharacters(in: .whitespacesAndNewlines)
			: text
	}

	/// Standard output, trimmed of whitespace and newline if it is single-line.
	public private(set) lazy var stdout: String = {
		guard let result = String(data: rawStdout, encoding: output.stdout.encoding) else {
			fatalError("Could not convert binary output of stdout to text using encoding \(output.stdout.encoding).")
		}
		return RunOutput.cleanUpOutput(result)
	}()

	/// Standard error, trimmed of whitespace and newline if it is single-line.
	public private(set) lazy var stderror: String = {
		guard let result = String(data: rawStderror, encoding: output.stderror.encoding) else {
			fatalError("Could not convert binary output of stderror to text using encoding \(output.stderror.encoding).")
		}
		return RunOutput.cleanUpOutput(result)
	}()

	/// The exit code of the command. Anything but 0 means there was an error.
	public var exitcode: Int { output.exitcode() }

	/// Checks if the exit code is 0.
	public var succeeded: Bool { exitcode == 0 }

  /*
   这里非常巧妙的定义了 && 和 || 符号重定义，以符合 bash 中的使用场景。并且支持 `上一个执行成功后下一个才能执行` 这样的设定。
   实际上，因为 `CommandRunning` 可以让各种数据类型遵守，已经很方便链式使用了。
   这里主要是为了符合 bash 使用习惯。
   */
	@discardableResult
	public static func && (lhs: RunOutput, rhs: @autoclosure () -> RunOutput) -> RunOutput {
		guard lhs.succeeded else { return lhs }
		return rhs()
	}
	@discardableResult
	public static func || (lhs: RunOutput, rhs: @autoclosure () -> RunOutput) -> RunOutput {
		if lhs.succeeded { return lhs }
		return rhs()
	}
}

extension CommandRunning {
	@available(*, unavailable, message: "Use `run(...).stdout` instead.")
	@discardableResult public func run(_ executable: String, _ args: Any ..., combineOutput: Bool = false) -> String {
		fatalError()
	}

  /*
   4 个命令执行接口中的 run。（run/runAsync/runAndPrint/runAsyncAndPrint）
   
   1. 不需要打印。不能使用 main 默认上下文(默认屏幕输出)。
   2. 非异步，需要等当前命令执行完毕后，进一步封装命令的执行信息(状态、结果)并提供给调用者。
   */
	@discardableResult public func run(_ executable: String, _ args: Any ..., combineOutput: Bool = false) -> RunOutput {
		let stringargs = args.flatten().map(String.init(describing:))
		let asyncCommand = AsyncCommand(unlaunched: createProcess(executable, args: stringargs), combineOutput: combineOutput)
		return RunOutput(launch: asyncCommand)
	}
}

// MARK: runAsync

/*
 4 个命令执行接口中的 runAsync 和 runAsyncAndPrint 提供。（run/runAsync/runAndPrint/runAsyncAndPrint）

 在异步场景下，需要返回业务方异步对象，以对命令执行状态、执行结果等进行访问和监听。
 当前文件没有什么特别的实现，主要是对 process 子进程进行信息透传。
 */
public class PrintedAsyncCommand {
	fileprivate let process: Process

	init(unlaunched process: Process, combineOutput: Bool) {
		self.process = process

		if combineOutput {
			process.standardError = process.standardOutput
		}
	}

	/// Calls `init(unlaunched:)`, then launches the process and exits the application on error.
	convenience init(launch process: Process, file: String, line: Int) {
		self.init(unlaunched: process, combineOutput: false)
		do {
			try process.launchThrowably()
		} catch {
			exit(errormessage: error, file: file, line: line)
		}
	}
  
	public var isRunning: Bool { process.isRunning }
	public func stop() {
		process.terminate()
	}
	public func interrupt() {
		process.interrupt()
	}
	@discardableResult public func suspend() -> Bool {
		process.suspend()
	}
	@discardableResult public func resume() -> Bool {
		process.resume()
	}

	@discardableResult public func finish() throws -> Self {
		try process.finish()
		return self
	}

	public func exitcode() -> Int {
		process.waitUntilExit()
		return Int(process.terminationStatus)
	}

	public func terminationReason() -> Process.TerminationReason {
		process.waitUntilExit()
		return process.terminationReason
	}

  /*
   命令执行完毕后，及时通知业务方，通知参数为本身。业务通过参数对命令执行结果和异常进行读取。
   */
	@discardableResult public func onCompletion(_ handler: @escaping (PrintedAsyncCommand) -> Void) -> Self {
		process.terminationHandler = { _ in
			handler(self)
		}
		return self
	}
}

/*
 4 个命令执行接口中的 run 和 runAsync 使用。（run/runAsync/runAndPrint/runAsyncAndPrint）

 相比 `runAsyncAndPrint`，`run`、`runAsync` 不需要打印，就需要改写 Process 的输出 filehandle 并在命令执行完成后进行输出读取。
 */
public final class AsyncCommand: PrintedAsyncCommand {
	public let stdout: ReadableStream
	public let stderror: ReadableStream

  /*
   因为不在走 main/custom 上下文的输出（大概率是显示器输出），所以这里需要自定义提供可写的 filehandle，并且在命令执行完毕后，通过可读的 filehandle 来读取内容。
   
   Pipe 管道可以实现这一点。把 pipe 对象给到 process，process 会主动调用可写的 filehandle 进行写入，然后外部可以通过 可读的 filehandle 进行读取。
   */
	override init(unlaunched process: Process, combineOutput: Bool) {
		let outpipe = Pipe()
		process.standardOutput = outpipe
		stdout = FileHandleStream(outpipe.fileHandleForReading, encoding: main.encoding)

		if combineOutput {
			stderror = stdout
		} else {
			let errorpipe = Pipe()
			process.standardError = errorpipe
			stderror = FileHandleStream(errorpipe.fileHandleForReading, encoding: main.encoding)
		}

		super.init(unlaunched: process, combineOutput: combineOutput)
	}

	@discardableResult public override func onCompletion(_ handler: @escaping (AsyncCommand) -> Void) -> Self {
		process.terminationHandler = { _ in
			handler(self)
		}
		return self
	}
}

extension CommandRunning {
  /*
   4 个命令执行接口中的 runAsync。（run/runAsync/runAndPrint/runAsyncAndPrint）
   
   1. 不需要打印。不能使用 main 默认上下文(默认屏幕输出)。
   2. 异步，返回异步对象。调用者通过异步对象对命令执行状态、执行结果等进行访问和监听。
   */
	public func runAsync(_ executable: String, _ args: Any ..., file: String = #file, line: Int = #line) -> AsyncCommand {
		let stringargs = args.flatten().map(String.init(describing:))
		return AsyncCommand(launch: createProcess(executable, args: stringargs), file: file, line: line)
	}

  /*
   4 个命令执行接口中的 runAsyncAndPrint。（run/runAsync/runAndPrint/runAsyncAndPrint）
   
   1. 打印。这是 Process 使用 main 上下文场景下的默认实现。
   2. 异步，返回异步对象。调用者通过异步对象对命令执行状态、执行结果等进行访问和监听。
   */
	public func runAsyncAndPrint(_ executable: String, _ args: Any ..., file: String = #file, line: Int = #line) -> PrintedAsyncCommand {
		let stringargs = args.flatten().map(String.init(describing:))
		return PrintedAsyncCommand(launch: createProcess(executable, args: stringargs), file: file, line: line)
	}
}

// MARK: runAndPrint

extension CommandRunning {
  /*
   4 个命令执行接口中的 runAndPrint。（run/runAsync/runAndPrint/runAsyncAndPrint）
   
   1. 打印。这是 Process 使用 main 上下文场景下的默认实现。
   2. 非异步，和 run 的区别是因为已经打印了，所以不需要调用者拿到命令输出信息。默认即可，不需要做处理。
   */
  public func runAndPrint(_ executable: String, _ args: Any ...) throws {
		let stringargs = args.flatten().map(String.init(describing:))
		let process = createProcess(executable, args: stringargs)

		try process.launchThrowably()
		try process.finish()
	}
}

// MARK: Global functions
/*
 4 个命令执行接口的语法糖，不再介绍。run/runAsync/runAndPrint/runAsyncAndPrint
 */
@discardableResult public func run(_ executable: String, _ args: Any ..., combineOutput: Bool = false) -> RunOutput {
	main.run(executable, args, combineOutput: combineOutput)
}
@available(*, unavailable, message: "Use `run(...).stdout` instead.")
@discardableResult public func run(_ executable: String, _ args: Any ..., combineOutput: Bool = false) -> String {
	fatalError()
}
public func runAsync(_ executable: String, _ args: Any ..., file: String = #file, line: Int = #line) -> AsyncCommand {
	main.runAsync(executable, args, file: file, line: line)
}
public func runAsyncAndPrint(_ executable: String, _ args: Any ..., file: String = #file, line: Int = #line) -> PrintedAsyncCommand {
	main.runAsyncAndPrint(executable, args, file: file, line: line)
}
public func runAndPrint(_ executable: String, _ args: Any ...) throws {
	try main.runAndPrint(executable, args)
}
