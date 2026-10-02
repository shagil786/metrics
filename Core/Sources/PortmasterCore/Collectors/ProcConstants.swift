// proc_pidinfo buffer-size constants. The PROC_PID*_SIZE macros use sizeof()
// expressions that do not import into Swift, so they are computed here.
import Foundation

let PM_PROC_PIDTBSDINFO_SIZE = Int32(MemoryLayout<proc_bsdinfo>.size)
let PM_PROC_PIDTASKINFO_SIZE = Int32(MemoryLayout<proc_taskinfo>.size)

/// Kernel exit-in-progress flag (proc_info.h PROC_FLAG_INEXIT) — zombies.
/// Note: bit 0x1 is PROC_FLAG_SYSTEM, not zombie.
let PM_PROC_PBI_ZOMBIE: UInt32 = 0x00000004
