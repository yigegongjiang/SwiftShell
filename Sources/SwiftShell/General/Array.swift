/*
 * Released under the MIT License (MIT), http://opensource.org/licenses/MIT
 *
 * Copyright (c) 2015 Kåre Morstøl, NotTooBad Software (nottoobadsoftware.com)
 *
 */

/*
 将超过一维的数组拍平。
 这里使用的 flatMap 已经废弃，目前使用 `compactMap`。
 flatMap 相比 Map 而言，内部默认是 join 追加。
 compactMap 相比 flatMap，增加了非空的过滤。
 
 作者这里支持命令传参的时候，以多维拍平为一维进行解析。
 */
extension Array where Element: Any {
	func flatten() -> [Any] {
		self.flatMap { x -> [Any] in
			if let anyarray = x as? Array<Any> {
				return anyarray.map { $0 as Any }.flatten()
			}
			return [x]
		}
	}
}
