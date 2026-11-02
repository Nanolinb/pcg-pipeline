class_name PCGRandomStream
extends RefCounted

# v0.14 公共内核：一条已派生的确定性随机流句柄。
# 持有主种子、派生方案版本与规范化作用域键，保证随机结果可恢复、可审计。
# 业务代码只经由本句柄采样，禁止触碰全局随机状态。

var master_seed: String = ""
var derivation_version: int = 1
var stream_key: String = ""
var stream_seed: int = 0
var rng: RandomNumberGenerator = null


func _init(p_master_seed: String = "", p_derivation_version: int = 1,
		p_stream_key: String = "", p_stream_seed: int = 0) -> void:
	master_seed = p_master_seed
	derivation_version = p_derivation_version
	stream_key = p_stream_key
	stream_seed = p_stream_seed
	rng = RandomNumberGenerator.new()
	rng.seed = p_stream_seed


func seed_info() -> Dictionary:
	return {
		"master_seed": master_seed,
		"derivation_version": derivation_version,
		"scope": stream_key,
	}


func randi() -> int:
	return rng.randi()


func randf() -> float:
	return rng.randf()


func randf_range(from: float, to: float) -> float:
	return rng.randf_range(from, to)


func randi_range(from: int, to: int) -> int:
	return rng.randi_range(from, to)


func pick_index(count: int) -> int:
	return rng.randi_range(0, count - 1) if count > 0 else -1
