import Foundation
import CMT

var probeHandler: ((UnsafePointer<TFTouch>?, Int) -> Void)?
private let probeLock = NSLock()

func probeFrame(_ touches: UnsafePointer<TFTouch>?, _ count: Int) {
    probeLock.lock(); probeHandler?(touches, count); probeLock.unlock()
}
