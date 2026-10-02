import Darwin

/// Mach exposes each thread's run state, but not its semaphore wait reason through thread_info.
/// Count all waiting threads without claiming that they are blocked on semaphores. Release every
/// send right and the task_threads allocation so repeated failures do not leak diagnostic state.
enum TestThreadCensus {
    static func capture() -> String {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threads, &count)
        guard result == KERN_SUCCESS, let threads else { return "task_threads failed: \(result)" }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var waiting = 0
        var unknown = 0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            if status != KERN_SUCCESS { unknown += 1 } else if info.run_state == TH_STATE_WAITING { waiting += 1 }
        }
        return "task_threads count=\(count); waiting=\(waiting); unknown=\(unknown); semaphore waits=unavailable"
    }
}
