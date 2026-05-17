@tool
extends RefCounted
class_name GaussianGpuStateCache

const RenderingDeviceContext := preload("res://addons/gdgs/runtime/render/gaussian_rendering_device_context.gd")

const TILE_SIZE := 16
const WORKGROUP_SIZE := 512
const RADIX := 256
const PARTITION_DIVISION := 8
const PARTITION_SIZE := PARTITION_DIVISION * WORKGROUP_SIZE
const MAX_RENDER_STATES := 4
const FLOATS_PER_SPLAT := 60
const FLOATS_PER_CULLED_SPLAT := 16
const BYTES_PER_FLOAT := 4
const MAX_SORT_ELEMENTS_PER_SPLAT := 10
const PROJECTION_PROBE_WORDS := 24
const SCRATCH_PROBE_WORDS := 8

const SHADER_PATH_PROJECTION := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_projection.glsl"
const SHADER_PATH_RADIX_UPSWEEP := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_upsweep.glsl"
const SHADER_PATH_RADIX_SPINE := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_spine.glsl"
const SHADER_PATH_RADIX_DOWNSWEEP := "res://addons/gdgs/runtime/render/shaders/compute/radix_sort_downsweep.glsl"
const SHADER_PATH_BOUNDARIES := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_boundaries.glsl"
const SHADER_PATH_RENDER := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_render.glsl"
const SHADER_PATH_SCRATCH_PROBE := "res://addons/gdgs/runtime/render/shaders/compute/gsplat_scratch_probe.glsl"

class RenderState:
	extends RefCounted

	var texture_size := Vector2i.ONE
	var tile_dims := Vector2i.ONE
	var camera_projection: Projection
	var camera_view: Projection
	var camera_push_constants := PackedByteArray()
	var camera_world_position := Vector3.ZERO
	var depth_capture_alpha := 0.5
	var diagnostics := {}
	var last_projection_dispatch_serial := 0
	var gpu_generation := 0
	var last_cleanup_request_serial := 0
	var last_cleanup_reason := "none"
	var last_cleanup_projection_snapshot := {}
	var needs_gpu_rebuild := true
	var needs_splat_upload := false
	var needs_instance_upload := false
	var context: GdgsRenderingDeviceContext
	var shaders: Dictionary = {}
	var pipelines: Dictionary = {}
	var descriptor_sets: Dictionary = {}
	var descriptors: Dictionary = {}

var _render_states: Dictionary = {}
var _render_state_lru: Array = []
var _pending_gpu_cleanup := false

func has_render_states() -> bool:
	return not _render_states.is_empty()

func request_cleanup(reason: String = "registry_change") -> void:
	var active_dispatch_serials: Array[String] = []
	for state in _render_states.values():
		state.last_cleanup_request_serial = int(state.last_projection_dispatch_serial)
		state.last_cleanup_reason = reason
		state.last_cleanup_projection_snapshot = _projection_resource_snapshot(state)
		active_dispatch_serials.append("%s:%d" % [str(state.texture_size), int(state.last_projection_dispatch_serial)])
	print("[gdgs] gpu_state_cache request_cleanup pending=%s active_states=%d reason=%s dispatch_serials=%s" % [
		str(_pending_gpu_cleanup),
		_render_states.size(),
		reason,
		"[" + ", ".join(active_dispatch_serials) + "]"
	])
	_pending_gpu_cleanup = true

func flush_pending_cleanup() -> void:
	if _pending_gpu_cleanup:
		var cleanup_summaries: Array[String] = []
		for state in _render_states.values():
			cleanup_summaries.append("%s:g%d:d%d:req_d%d:%s" % [
				str(state.texture_size),
				int(state.gpu_generation),
				int(state.last_projection_dispatch_serial),
				int(state.last_cleanup_request_serial),
				str(state.last_cleanup_reason)
			])
		print("[gdgs] gpu_state_cache flush_pending_cleanup active_states=%d summaries=%s" % [_render_states.size(), "[" + ", ".join(cleanup_summaries) + "]"])
		cleanup_all()

func get_or_create_render_state(texture_size: Vector2i):
	var state: RenderState = _render_states.get(texture_size, null)
	if state == null:
		state = RenderState.new()
		state.texture_size = texture_size
		state.tile_dims = (texture_size + Vector2i(TILE_SIZE - 1, TILE_SIZE - 1)) / TILE_SIZE
		_render_states[texture_size] = state
	_touch_render_state(texture_size)
	_enforce_render_state_cache_limit()
	return state

func mark_all_render_states_needs_gpu_rebuild() -> void:
	for state in _render_states.values():
		state.needs_gpu_rebuild = true

func mark_all_render_states_needs_splat_upload(value: bool) -> void:
	for state in _render_states.values():
		state.needs_splat_upload = value

func mark_all_render_states_needs_instance_upload(value: bool) -> void:
	for state in _render_states.values():
		state.needs_instance_upload = value

func rebuild_gpu_state(state, point_count: int, unique_data_size: int, instance_count: int) -> void:
	cleanup_state(state)
	if point_count <= 0:
		return

	state.context = RenderingDeviceContext.create(RenderingServer.get_rendering_device())

	state.shaders["projection"] = state.context.load_shader(SHADER_PATH_PROJECTION)
	state.shaders["radix_upsweep"] = state.context.load_shader(SHADER_PATH_RADIX_UPSWEEP)
	state.shaders["radix_spine"] = state.context.load_shader(SHADER_PATH_RADIX_SPINE)
	state.shaders["radix_downsweep"] = state.context.load_shader(SHADER_PATH_RADIX_DOWNSWEEP)
	state.shaders["boundaries"] = state.context.load_shader(SHADER_PATH_BOUNDARIES)
	state.shaders["render"] = state.context.load_shader(SHADER_PATH_RENDER)
	state.shaders["scratch_probe"] = state.context.load_shader(SHADER_PATH_SCRATCH_PROBE)
	assert(state.shaders["scratch_probe"].is_valid(), "Scratch probe shader failed to load")

	var num_sort_elements_max := point_count * MAX_SORT_ELEMENTS_PER_SPLAT
	var num_partitions := (num_sort_elements_max + PARTITION_SIZE - 1) / PARTITION_SIZE
	var max_boundary_workgroups := ceili(num_sort_elements_max / 256.0)
	var block_dims := PackedInt32Array()
	block_dims.resize(6)
	block_dims.fill(1)
	# Keep the legacy grid-dimensions buffer populated for shader compatibility, but
	# use direct dispatch for the sort/boundary passes. This isolates the renderer from
	# the dispatch-indirect path while preserving the existing worst-case work sizes.
	block_dims[0] = num_partitions
	block_dims[3] = max_boundary_workgroups

	state.descriptors["splats"] = state.context.create_storage_buffer(unique_data_size)
	state.descriptors["culled_splats"] = state.context.create_storage_buffer(point_count * FLOATS_PER_CULLED_SPLAT * BYTES_PER_FLOAT)
	state.descriptors["grid_dimensions"] = state.context.create_storage_buffer(6 * 4, block_dims.to_byte_array())
	state.descriptors["histogram"] = state.context.create_storage_buffer(4 + (1 + 4 * RADIX + num_partitions * RADIX) * 4)
	state.descriptors["sort_keys"] = state.context.create_storage_buffer(num_sort_elements_max * 4 * 2)
	state.descriptors["sort_values"] = state.context.create_storage_buffer(num_sort_elements_max * 4 * 2)
	state.descriptors["splat_instance_ids"] = state.context.create_storage_buffer(point_count * 4 * 2)
	state.descriptors["instance_transforms"] = state.context.create_storage_buffer(instance_count * 16 * BYTES_PER_FLOAT)
	state.descriptors["uniforms"] = state.context.create_uniform_buffer(8 * 4)
	state.descriptors["tile_bounds"] = state.context.create_storage_buffer(state.tile_dims.x * state.tile_dims.y * 2 * 4)
	state.descriptors["tile_splat_pos"] = state.context.create_storage_buffer(4 * 4)
	state.descriptors["scratch_probe"] = state.context.create_storage_buffer(SCRATCH_PROBE_WORDS * 4)
	state.descriptors["projection_probe"] = state.context.create_storage_buffer(PROJECTION_PROBE_WORDS * 4)
	state.descriptors["render_texture"] = state.context.create_texture(state.texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	state.descriptors["depth_texture"] = state.context.create_texture(state.texture_size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)

	var projection_set: RID = state.context.create_descriptor_set([
		state.descriptors["splats"],
		state.descriptors["culled_splats"],
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["sort_values"],
		state.descriptors["grid_dimensions"],
		state.descriptors["splat_instance_ids"],
		state.descriptors["instance_transforms"],
		state.descriptors["uniforms"],
		state.descriptors["projection_probe"],
		state.descriptors["scratch_probe"]
	], state.shaders["projection"], 0)
	state.descriptor_sets["projection"] = projection_set

	var radix_upsweep_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"]
	], state.shaders["radix_upsweep"], 0)
	state.descriptor_sets["radix_upsweep"] = radix_upsweep_set

	var radix_spine_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"]
	], state.shaders["radix_spine"], 0)
	state.descriptor_sets["radix_spine"] = radix_spine_set

	var radix_downsweep_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["sort_values"]
	], state.shaders["radix_downsweep"], 0)
	state.descriptor_sets["radix_downsweep"] = radix_downsweep_set

	var boundaries_set: RID = state.context.create_descriptor_set([
		state.descriptors["histogram"],
		state.descriptors["sort_keys"],
		state.descriptors["tile_bounds"]
	], state.shaders["boundaries"], 0)
	state.descriptor_sets["boundaries"] = boundaries_set

	var render_set: RID = state.context.create_descriptor_set([
		state.descriptors["culled_splats"],
		state.descriptors["sort_values"],
		state.descriptors["tile_bounds"],
		state.descriptors["tile_splat_pos"],
		state.descriptors["render_texture"],
		state.descriptors["depth_texture"]
	], state.shaders["render"], 0)
	state.descriptor_sets["render"] = render_set

	var scratch_probe_set: RID = state.context.create_descriptor_set([
		state.descriptors["scratch_probe"]
	], state.shaders["scratch_probe"], 0)
	state.descriptor_sets["scratch_probe"] = scratch_probe_set
	assert(scratch_probe_set.is_valid(), "Scratch probe uniform set failed to create")

	state.pipelines["gsplat_projection"] = state.context.create_pipeline("gsplat_projection", [ceili(point_count / 256.0), 1, 1], [projection_set], state.shaders["projection"])
	state.pipelines["radix_sort_upsweep"] = state.context.create_pipeline("radix_sort_upsweep", [num_partitions, 1, 1], [radix_upsweep_set], state.shaders["radix_upsweep"])
	state.pipelines["radix_sort_spine"] = state.context.create_pipeline("radix_sort_spine", [RADIX, 1, 1], [radix_spine_set], state.shaders["radix_spine"])
	state.pipelines["radix_sort_downsweep"] = state.context.create_pipeline("radix_sort_downsweep", [num_partitions, 1, 1], [radix_downsweep_set], state.shaders["radix_downsweep"])
	state.pipelines["gsplat_boundaries"] = state.context.create_pipeline("gsplat_boundaries", [max_boundary_workgroups, 1, 1], [boundaries_set], state.shaders["boundaries"])
	state.pipelines["gsplat_render"] = state.context.create_pipeline("gsplat_render", [state.tile_dims.x, state.tile_dims.y, 1], [render_set], state.shaders["render"])
	state.pipelines["gsplat_scratch_probe"] = state.context.create_pipeline("gsplat_scratch_probe", [1, 1, 1], [scratch_probe_set], state.shaders["scratch_probe"])

	state.gpu_generation += 1
	state.diagnostics = {
		"gpu_generation": state.gpu_generation,
		"point_count_capacity": point_count,
		"instance_count_capacity": instance_count,
		"texture_size": state.texture_size,
		"tile_dims": state.tile_dims,
		"tile_count": state.tile_dims.x * state.tile_dims.y,
		"tile_bounds_capacity": state.tile_dims.x * state.tile_dims.y,
		"num_sort_elements_max": num_sort_elements_max,
		"num_partitions": num_partitions,
		"max_boundary_workgroups": max_boundary_workgroups,
		"projection_group_count": ceili(point_count / 256.0),
		"projection_push_constant_bytes_expected": 128,
		"projection_push_constant_floats_expected": 32,
		"projection_push_constant_layout": "mat4 view + mat4 projection",
		"projection_splat_stride_bytes_expected": FLOATS_PER_SPLAT * BYTES_PER_FLOAT,
		"projection_culled_stride_bytes_expected": FLOATS_PER_CULLED_SPLAT * BYTES_PER_FLOAT,
		"projection_probe_words": PROJECTION_PROBE_WORDS,
		"scratch_probe_words": SCRATCH_PROBE_WORDS,
		"scratch_probe_bytes": SCRATCH_PROBE_WORDS * 4
	}

	print("[gdgs] gpu_state_cache rebuild_gpu_state texture_size=%s gpu_generation=%d projection_dispatch_serial=%d snapshot=%s" % [
		str(state.texture_size),
		int(state.gpu_generation),
		int(state.last_projection_dispatch_serial),
		JSON.stringify(_projection_resource_snapshot(state))
	])
	state.needs_gpu_rebuild = false
	state.needs_splat_upload = true
	state.needs_instance_upload = true

func upload_splats(state, point_data_byte: PackedByteArray, splat_instance_ids_byte: PackedByteArray) -> void:
	if state.context == null or point_data_byte.is_empty() or splat_instance_ids_byte.is_empty():
		return
	assert(point_data_byte.size() == int(state.diagnostics.get("point_count_capacity", 0)) * FLOATS_PER_SPLAT * BYTES_PER_FLOAT, "Projection splat upload size drifted from shader contract")
	assert(splat_instance_ids_byte.size() == int(state.diagnostics.get("point_count_capacity", 0)) * 2 * BYTES_PER_FLOAT, "Projection instance-id upload size drifted from shader contract")
	state.context.device.buffer_update(state.descriptors["splats"].rid, 0, point_data_byte.size(), point_data_byte)
	state.context.device.buffer_update(state.descriptors["splat_instance_ids"].rid, 0, splat_instance_ids_byte.size(), splat_instance_ids_byte)
	state.needs_splat_upload = false

func upload_instance_transforms(state, instance_transforms_byte: PackedByteArray) -> void:
	if state.context == null or instance_transforms_byte.is_empty():
		return
	assert(instance_transforms_byte.size() == int(state.diagnostics.get("instance_count_capacity", 0)) * 16 * BYTES_PER_FLOAT, "Projection instance-transform upload size drifted from shader contract")
	state.context.device.buffer_update(state.descriptors["instance_transforms"].rid, 0, instance_transforms_byte.size(), instance_transforms_byte)
	state.needs_instance_upload = false

func cleanup_state(state) -> void:
	if state == null:
		return
	if state.context != null:
		print("[gdgs] gpu_state_cache cleanup_state texture_size=%s gpu_generation=%d last_projection_dispatch_serial=%d last_cleanup_request_serial=%d last_cleanup_reason=%s projection_probe_valid=%s scratch_probe_valid=%s snapshot=%s request_snapshot=%s" % [
			str(state.texture_size),
			int(state.gpu_generation),
			int(state.last_projection_dispatch_serial),
			int(state.last_cleanup_request_serial),
			state.last_cleanup_reason,
			str(state.descriptors.has("projection_probe") and state.descriptors["projection_probe"].rid.is_valid()),
			str(state.descriptors.has("scratch_probe") and state.descriptors["scratch_probe"].rid.is_valid()),
			JSON.stringify(_projection_resource_snapshot(state)),
			JSON.stringify(state.last_cleanup_projection_snapshot)
		])
		state.last_cleanup_projection_snapshot = _projection_resource_snapshot(state)
		state.context.free()
		state.context = null
	state.shaders.clear()
	state.pipelines.clear()
	state.descriptor_sets.clear()
	state.descriptors.clear()
	state.needs_gpu_rebuild = true
	state.needs_splat_upload = true
	state.needs_instance_upload = true

func cleanup_all() -> void:
	for state in _render_states.values():
		cleanup_state(state)
	_render_states.clear()
	_render_state_lru.clear()
	_pending_gpu_cleanup = false

func _touch_render_state(texture_size: Vector2i) -> void:
	var existing_index := _render_state_lru.find(texture_size)
	if existing_index != -1:
		_render_state_lru.remove_at(existing_index)
	_render_state_lru.push_back(texture_size)

func _enforce_render_state_cache_limit() -> void:
	while _render_state_lru.size() > MAX_RENDER_STATES:
		var stale_size = _render_state_lru[0]
		_render_state_lru.remove_at(0)
		var stale_state = _render_states.get(stale_size, null)
		if stale_state != null:
			cleanup_state(stale_state)
			_render_states.erase(stale_size)

func _rid_string(rid: RID) -> String:
	return "RID(%d)" % rid.get_id() if rid.is_valid() else "RID()"

func _descriptor_rid_string(state, key: String) -> String:
	if not state.descriptors.has(key):
		return "RID()"
	return _rid_string(state.descriptors[key].rid)

func _descriptor_set_rid_string(state, key: String) -> String:
	if not state.descriptor_sets.has(key):
		return "RID()"
	return _rid_string(state.descriptor_sets[key])

func _pipeline_snapshot_string(state, key: String) -> String:
	if not state.pipelines.has(key):
		return "missing"
	var pipeline_callable: Callable = state.pipelines[key]
	return "Callable(valid=%s)" % str(pipeline_callable.is_valid())

func _projection_resource_snapshot(state) -> Dictionary:
	var tracked_resources := {
		"projection_probe": _descriptor_rid_string(state, "projection_probe"),
		"scratch_probe": _descriptor_rid_string(state, "scratch_probe"),
		"histogram": _descriptor_rid_string(state, "histogram"),
		"sort_keys": _descriptor_rid_string(state, "sort_keys"),
		"sort_values": _descriptor_rid_string(state, "sort_values"),
		"culled_splats": _descriptor_rid_string(state, "culled_splats"),
		"tile_bounds": _descriptor_rid_string(state, "tile_bounds"),
		"render_texture": _descriptor_rid_string(state, "render_texture"),
		"depth_texture": _descriptor_rid_string(state, "depth_texture")
	}
	var alias_groups := {}
	for resource_name in tracked_resources.keys():
		var resource_rid: String = tracked_resources[resource_name]
		if resource_rid == "RID()":
			continue
		if not alias_groups.has(resource_rid):
			alias_groups[resource_rid] = []
		alias_groups[resource_rid].append(resource_name)
	var duplicate_alias_groups := {}
	for resource_rid in alias_groups.keys():
		var alias_members: Array = alias_groups[resource_rid]
		if alias_members.size() > 1:
			duplicate_alias_groups[resource_rid] = alias_members
	var snapshot := {
		"gpu_generation": int(state.gpu_generation),
		"texture_size": str(state.texture_size),
		"last_projection_dispatch_serial": int(state.last_projection_dispatch_serial),
		"projection_set": _descriptor_set_rid_string(state, "projection"),
		"scratch_probe_set": _descriptor_set_rid_string(state, "scratch_probe"),
		"projection_pipeline": _pipeline_snapshot_string(state, "gsplat_projection"),
		"scratch_pipeline": _pipeline_snapshot_string(state, "gsplat_scratch_probe"),
		"projection_probe": tracked_resources["projection_probe"],
		"scratch_probe": tracked_resources["scratch_probe"],
		"histogram": tracked_resources["histogram"],
		"sort_keys": tracked_resources["sort_keys"],
		"sort_values": tracked_resources["sort_values"],
		"culled_splats": tracked_resources["culled_splats"],
		"tile_bounds": tracked_resources["tile_bounds"],
		"render_texture": tracked_resources["render_texture"],
		"depth_texture": tracked_resources["depth_texture"],
		"aliasing_detected": not duplicate_alias_groups.is_empty(),
		"alias_groups": duplicate_alias_groups
	}
	return snapshot
