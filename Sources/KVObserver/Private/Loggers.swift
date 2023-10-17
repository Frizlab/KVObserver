import Foundation
import os.log



extension OSLog {
	
	static let kvObserver = {
		return OSLog(subsystem: loggerSubsystem, category: "KVObserver")
	}()
	
	static let kvTreeObserver = {
		return OSLog(subsystem: loggerSubsystem, category: "KVTreeObserver")
	}()
	
	private static let loggerSubsystem = "me.frizlab.kvobserver"
	
}
