extends RefCounted
## Fire-and-forget processes that do not pile up as zombies.
##
## OS.create_process never waits for its child, so every finished busctl/xprop stayed <defunct>
## under OpenGamepadUI (183 of them after an evening on the Air Y). OS.is_process_running() reaps
## a finished child (waitpid WNOHANG), so each spawn first sweeps the earlier ones.

static var _pids: Array[int] = []


static func run(command: String, args: Array) -> int:
	reap()
	var pid := OS.create_process(command, PackedStringArray(args))
	if pid > 0:
		_pids.append(pid)
	return pid


static func reap() -> void:
	_pids = _pids.filter(func(pid: int) -> bool: return OS.is_process_running(pid))
