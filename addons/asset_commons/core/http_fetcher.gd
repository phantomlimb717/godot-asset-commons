@tool
extends Node
## Concurrency-limited HTTP client. Must be inside the scene tree (HTTPRequest
## nodes are created as children). All calls are coroutines: use `await`.

signal _slot_freed

## Requests run in named lanes with separate concurrency limits, so bulk
## background work (thumbnails) never blocks user actions (file lists, downloads).
const LANES := {"default": 6, "background": 6}

var user_agent := "GodotAssetCommons"

var _active := {"default": 0, "background": 0}


## Returns {ok, code, error, body}. With `to_file`, the body is streamed to that
## absolute path instead and `body` is empty. `lane` is "default" or "background".
func fetch(url: String, to_file := "", lane := "default") -> Dictionary:
	while _active[lane] >= LANES[lane]:
		await _slot_freed
	_active[lane] += 1

	var req := HTTPRequest.new()
	req.use_threads = true
	req.timeout = 120.0
	req.download_file = to_file
	add_child(req)

	var result: Array = [HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray()]
	if req.request(url, PackedStringArray(["User-Agent: " + user_agent])) == OK:
		result = await req.request_completed
	req.queue_free()

	_active[lane] -= 1
	_slot_freed.emit()

	var code: int = result[1]
	var ok: bool = result[0] == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	var error := ""
	if not ok:
		error = "HTTP %d" % code if result[0] == HTTPRequest.RESULT_SUCCESS else "network error %d" % result[0]
	return {"ok": ok, "code": code, "error": error, "body": result[3]}


func fetch_json(url: String) -> Dictionary:
	var res := await fetch(url)
	if res.ok:
		res["data"] = JSON.parse_string((res.body as PackedByteArray).get_string_from_utf8())
		if res.data == null:
			res.ok = false
			res.error = "invalid JSON"
	return res


## Downloads every job ({url, file}) in parallel (bounded by the default lane).
## `on_file_done(job, result)` is called as each finishes. Returns the failures.
func fetch_all(jobs: Array, on_file_done := Callable()) -> Array:
	var state := {"pending": jobs.size(), "failures": []}
	if jobs.is_empty():
		return []
	var finished := _Latch.new()
	for job in jobs:
		_fetch_job(job, state, finished, on_file_done)
	if state.pending > 0:
		await finished.done
	return state.failures


func _fetch_job(job: Dictionary, state: Dictionary, finished: _Latch, on_file_done: Callable) -> void:
	var res := await fetch(job.url, job.file)
	if not res.ok:
		state.failures.append({"job": job, "error": res.error})
	if on_file_done.is_valid():
		on_file_done.call(job, res)
	state.pending -= 1
	if state.pending == 0:
		finished.done.emit()


class _Latch:
	signal done
