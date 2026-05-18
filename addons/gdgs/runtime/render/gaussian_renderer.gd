@tool
extends RefCounted
class_name GaussianRenderer

const RenderingDeviceContext := preload("res://addons/gdgs/runtime/render/gaussian_rendering_device_context.gd")
const RADIX := 256
const MAX_SORT_ELEMENTS_PER_SPLAT := 10

const PROJECTION_PROBE_INVOCATIONS := 0
const PROJECTION_PROBE_VISIBLE_SPLATS := 1
const PROJECTION_PROBE_DUPLICATED_SPLATS := 2
const PROJECTION_PROBE_EMITTED_SORT_ELEMENTS := 3
const PROJECTION_PROBE_MAX_SORT_END := 4
const PROJECTION_PROBE_MAX_TILE_ID := 5
const PROJECTION_PROBE_MAX_TILES_TOUCHED := 6
const PROJECTION_PROBE_ZERO_TILE_SPLATS := 7
const PROJECTION_PROBE_SORT_CAPACITY := 8
const PROJECTION_PROBE_TILE_CAPACITY := 9
const PROJECTION_PROBE_POINT_COUNT := 10
const PROJECTION_PROBE_GRID_WIDTH := 11
const PROJECTION_PROBE_GRID_HEIGHT := 12
const PROJECTION_PROBE_ERROR_FLAGS := 13
const PROJECTION_PROBE_GUARD_ABORT_COUNT := 14
const PROJECTION_PROBE_FIRST_FAILURE_STAGE := 15
const PROJECTION_PROBE_FIRST_FAILURE_ID := 16
const PROJECTION_PROBE_FIRST_FAILURE_VALUE0 := 17
const PROJECTION_PROBE_FIRST_FAILURE_VALUE1 := 18
const PROJECTION_PROBE_MAX_REQUESTED_SORT_END := 19
const PROJECTION_PROBE_MAX_REQUESTED_TILE_ID := 20
const PROJECTION_PROBE_NON_FINITE_FAILURE_COUNT := 21
const PROJECTION_PROBE_SORT_OVERFLOW_GUARD_COUNT := 22
const PROJECTION_PROBE_TILE_GUARD_COUNT := 23

const SCRATCH_PROBE_SIGNATURE_WORD0 := 0
const SCRATCH_PROBE_SIGNATURE_WORD1 := 1
const SCRATCH_PROBE_SIGNATURE_WORD2 := 2
const SCRATCH_PROBE_SIGNATURE_WORD3 := 3
const SCRATCH_PROBE_PROJECTION_INVOCATIONS := 4
const SCRATCH_PROBE_PROJECTION_VISIBLE_SPLATS := 5
const SCRATCH_PROBE_PROJECTION_STAGE_BITS := 6
const SCRATCH_PROBE_PROJECTION_MAX_REQUESTED_SORT_END := 7

const SCRATCH_PROJECTION_STAGE_ENTRY := 1 << 0
const SCRATCH_PROJECTION_STAGE_VISIBLE := 1 << 1
const SCRATCH_PROJECTION_STAGE_CULLED_WRITE := 1 << 2
const SCRATCH_PROJECTION_STAGE_SORT_RESERVED := 1 << 3
const SCRATCH_PROJECTION_STAGE_SORT_WRITTEN := 1 << 4

const PROJECTION_ERROR_FLAG_NON_FINITE := 1 << 0
const PROJECTION_ERROR_FLAG_SORT_OVERFLOW := 1 << 1
const PROJECTION_ERROR_FLAG_TILE_OOB := 1 << 2
const PROJECTION_ERROR_FLAG_RECT_INVALID := 1 << 3

const PROJECTION_FAILURE_NONE := 0
const PROJECTION_FAILURE_VIEW_POS_NON_FINITE := 1
const PROJECTION_FAILURE_CLIP_POS_NON_FINITE := 2
const PROJECTION_FAILURE_COVARIANCE_NON_FINITE := 3
const PROJECTION_FAILURE_DETERMINANT_NON_FINITE := 4
const PROJECTION_FAILURE_EIGENVALUES_NON_FINITE := 5
const PROJECTION_FAILURE_IMAGE_POS_NON_FINITE := 6
const PROJECTION_FAILURE_RADIUS_NON_FINITE := 7
const PROJECTION_FAILURE_RECT_INVALID := 8
const PROJECTION_FAILURE_SORT_OVERFLOW := 9
const PROJECTION_FAILURE_TILE_ID_OOB := 10
const PROJECTION_FAILURE_VIEW_DEPTH_NON_FINITE := 11
const PROJECTION_FAILURE_CONIC_NON_FINITE := 12
const PROJECTION_FAILURE_COLOR_NON_FINITE := 13

enum RasterDebugStage {
	FULL_PIPELINE,
	PREPARED_NO_DISPATCH,
	PROJECTION_ONLY,
	RADIX_ONLY,
	BOUNDARIES_ONLY,
	RENDER_ONLY,
	SCRATCH_ONLY
}

enum ProjectionReadbackCheckpoint {
	FULL_PACKAGE,
	DISABLED,
	HISTOGRAM_HEADER_ONLY,
	PROJECTION_PROBE_ONLY,
	SORT_KEYS_SENTINEL_ONLY,
	SORT_VALUES_SENTINEL_ONLY,
	CULLED_SPLATS_SENTINEL_ONLY,
	SCRATCH_PROJECTION_MIRROR_ONLY
}

var _once_logs := {}

func render_for_compositor(
	state_cache: GaussianGpuStateCache,
	scene_registry: GaussianSceneRegistry,
	texture_size: Vector2i,
	camera_transform: Transform3D,
	camera_projection: Projection,
	camera_world_position: Vector3,
	depth_capture_alpha: float = 0.5,
	debug_raster_stage: int = RasterDebugStage.FULL_PIPELINE,
	debug_projection_readback_checkpoint: int = ProjectionReadbackCheckpoint.FULL_PACKAGE
) -> Dictionary:
	state_cache.flush_pending_cleanup()

	if not scene_registry.has_gpu_data():
		if state_cache.has_render_states():
			state_cache.cleanup_all()
		return {}

	var point_count := scene_registry.get_point_count()
	var safe_size := Vector2i(maxi(texture_size.x, 1), maxi(texture_size.y, 1))
	var state = state_cache.get_or_create_render_state(safe_size)
	_update_camera_from_transform(state, camera_transform, camera_projection)
	state.camera_world_position = camera_world_position
	state.depth_capture_alpha = clampf(depth_capture_alpha, 0.0, 1.0)

	var unique_data_size := scene_registry.get_point_data_byte().size()

	if state.context == null or state.needs_gpu_rebuild:
		state_cache.rebuild_gpu_state(state, point_count, unique_data_size, scene_registry.get_instance_count())
	if state.context == null:
		return {}

	if state.needs_splat_upload:
		state_cache.upload_splats(state, scene_registry.get_point_data_byte(), scene_registry.get_splat_instance_ids_byte())
	if state.needs_instance_upload:
		state_cache.upload_instance_transforms(state, scene_registry.get_instance_transforms_byte())

	if state.camera_push_constants.is_empty():
		return {}

	_log_once(
		"rd_seam_correction",
		"[gdgs] seam correction compositor_path_uses_global_rd=%s raster_path_uses_global_rd=%s local_device_submit_sync_exercised=%s" % [
			str(RenderingServer.get_rendering_device() != null),
			str(state.context.device == RenderingServer.get_rendering_device()),
			"false"
		]
	)
	_log_once(
		"direct_dispatch_isolation",
		"[gdgs] renderer using direct dispatch isolation for radix/boundary passes"
	)
	_log_once(
		"raster_stage_gate",
		"[gdgs] renderer raster stage gate=%s" % _raster_stage_name(debug_raster_stage)
	)
	_log_once(
		"projection_readback_checkpoint_gate",
		"[gdgs] renderer projection readback checkpoint=%s" % _projection_readback_checkpoint_name(debug_projection_readback_checkpoint)
	)

	_rasterize_state(state, point_count, debug_raster_stage, debug_projection_readback_checkpoint)
	if state.descriptors.has("render_texture") and state.descriptors.has("depth_texture"):
		var color_texture: RID = state.descriptors["render_texture"].rid
		var depth_texture: RID = state.descriptors["depth_texture"].rid
		_log_once(
			"render_targets_ready",
			"[gdgs] renderer prepared compositor textures color_valid=%s depth_valid=%s texture_size=%s point_count=%d" % [
				str(color_texture.is_valid()),
				str(depth_texture.is_valid()),
				str(state.texture_size),
				point_count
			]
		)
		return {
			"color_alpha_texture": color_texture,
			"depth_texture": depth_texture,
			"debug_sync_snapshot": _post_projection_sync_snapshot(state)
		}
	return {}

func _rasterize_state(state, point_count: int, debug_raster_stage: int, debug_projection_readback_checkpoint: int) -> void:
	if state.context == null:
		return

	_assert_projection_preconditions(state, point_count)

	var uniforms := RenderingDeviceContext.create_push_constant([
		state.camera_world_position.x,
		state.camera_world_position.y,
		state.camera_world_position.z,
		Time.get_ticks_msec() * 1e-3,
		state.texture_size.x,
		state.texture_size.y,
		point_count,
		0
	])
	state.context.device.buffer_update(state.descriptors["uniforms"].rid, 0, 8 * 4, uniforms)
	state.context.device.buffer_clear(state.descriptors["histogram"].rid, 0, 4 + 4 * RADIX * 4)
	state.context.device.buffer_clear(state.descriptors["tile_bounds"].rid, 0, state.tile_dims.x * state.tile_dims.y * 2 * 4)
	state.context.device.buffer_update(state.descriptors["scratch_probe"].rid, 0, int(state.diagnostics.get("scratch_probe_words", 0)) * 4, _scratch_probe_seed_bytes())
	state.context.device.buffer_update(state.descriptors["projection_probe"].rid, 0, int(state.diagnostics.get("projection_probe_words", 0)) * 4, _projection_probe_seed_bytes(state, point_count))
	state.context.device.buffer_update(state.descriptors["sort_keys"].rid, 0, 4 * 4, _uint_words_byte_array([0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF]))
	state.context.device.buffer_update(state.descriptors["sort_values"].rid, 0, 4 * 4, _uint_words_byte_array([0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF]))
	state.context.device.buffer_update(state.descriptors["culled_splats"].rid, 0, 4 * 4, _uint_words_byte_array([0x7FC00000, 0x7FC00000, 0x7FC00000, 0x7FC00000]))
	_log_stage("prepared", state, point_count, {
		"raster_stage_gate": _raster_stage_name(debug_raster_stage),
		"projection_readback_checkpoint": _projection_readback_checkpoint_name(debug_projection_readback_checkpoint),
		"projection_push_constant_bytes": state.camera_push_constants.size(),
		"projection_push_constant_layout": str(state.diagnostics.get("projection_push_constant_layout", "unknown")),
		"projection_group_count": state.diagnostics.get("projection_group_count", -1),
		"tile_bounds_capacity": state.diagnostics.get("tile_bounds_capacity", -1),
		"sort_capacity": state.diagnostics.get("num_sort_elements_max", -1)
	})

	if debug_raster_stage == RasterDebugStage.PREPARED_NO_DISPATCH:
		_log_stage("prepared_no_dispatch_gate", state, point_count)
		return

	if debug_raster_stage == RasterDebugStage.SCRATCH_ONLY:
		assert(state.shaders.get("scratch_probe", RID()).is_valid(), "Scratch probe shader must be valid before scratch_only dispatch")
		assert(state.descriptors.get("scratch_probe", null) != null and state.descriptors["scratch_probe"].rid.is_valid(), "Scratch probe buffer must be valid before scratch_only dispatch")
		assert(state.pipelines.has("gsplat_scratch_probe"), "Scratch probe pipeline must exist before scratch_only dispatch")
		var scratch_compute_list: int = state.context.compute_list_begin()
		_log_stage("scratch_dispatch_begin", state, point_count, {
			"scratch_probe_bytes": state.diagnostics.get("scratch_probe_bytes", -1),
			"scratch_shader_valid": str(state.shaders.get("scratch_probe", RID()).is_valid()),
			"scratch_buffer_valid": str(state.descriptors["scratch_probe"].rid.is_valid())
		})
		state.pipelines["gsplat_scratch_probe"].call(state.context, scratch_compute_list, PackedByteArray())
		state.context.compute_list_end()
		_log_scratch_probe_readback(state, point_count)
		_log_stage("scratch_only_gate", state, point_count)
		return

	state.last_projection_dispatch_serial += 1
	var projection_dispatch_serial := int(state.last_projection_dispatch_serial)
	var compute_list: int = state.context.compute_list_begin()
	var projection_details := _projection_diagnostic_details(state, point_count)
	projection_details["projection_dispatch_serial"] = projection_dispatch_serial
	_log_stage("projection_begin", state, point_count, projection_details)
	state.pipelines["gsplat_projection"].call(state.context, compute_list, state.camera_push_constants)
	_log_stage("projection_end", state, point_count, {
		"projection_dispatch_serial": projection_dispatch_serial,
		"push_constant_bytes": state.camera_push_constants.size(),
		"push_constant_layout": str(state.diagnostics.get("projection_push_constant_layout", "unknown")),
		"projection_group_count": state.diagnostics.get("projection_group_count", -1),
		"gpu_generation": int(state.gpu_generation),
		"cleanup_request_serial": int(state.last_cleanup_request_serial),
		"cleanup_request_reason": state.last_cleanup_reason,
		"projection_resource_snapshot": JSON.stringify(_projection_resource_snapshot(state))
	})
	state.context.compute_list_end()
	_run_projection_post_dispatch_checkpoint(state, point_count, debug_projection_readback_checkpoint)

	if debug_raster_stage == RasterDebugStage.PROJECTION_ONLY:
		_log_stage("projection_only_gate", state, point_count)
		return

	compute_list = state.context.compute_list_begin()
	for radix_shift_pass in range(4):
		var radix_input_offset := point_count * MAX_SORT_ELEMENTS_PER_SPLAT * (radix_shift_pass % 2)
		var radix_output_offset := point_count * MAX_SORT_ELEMENTS_PER_SPLAT * (1 - (radix_shift_pass % 2))
		assert(radix_input_offset < int(state.diagnostics.get("num_sort_elements_max", 0)) * 2, "Radix input offset exceeds allocated sort capacity")
		assert(radix_output_offset < int(state.diagnostics.get("num_sort_elements_max", 0)) * 2, "Radix output offset exceeds allocated sort capacity")
		_log_stage(
			"radix_pass_begin",
			state,
			point_count,
			{
				"pass": radix_shift_pass,
				"radix_input_offset": radix_input_offset,
				"radix_output_offset": radix_output_offset
			}
		)
		state.pipelines["radix_sort_upsweep"].call(
			state.context,
			compute_list,
			RenderingDeviceContext.create_exact_push_constant([
				radix_shift_pass,
				radix_input_offset
			])
		)
		state.pipelines["radix_sort_spine"].call(
			state.context,
			compute_list,
			RenderingDeviceContext.create_exact_push_constant([radix_shift_pass])
		)
		state.pipelines["radix_sort_downsweep"].call(
			state.context,
			compute_list,
			RenderingDeviceContext.create_exact_push_constant([
				radix_shift_pass,
				radix_input_offset,
				radix_output_offset
			])
		)
		_log_stage(
			"radix_pass_end",
			state,
			point_count,
			{
				"pass": radix_shift_pass,
				"radix_input_offset": radix_input_offset,
				"radix_output_offset": radix_output_offset
			}
		)
	state.context.compute_list_end()

	if debug_raster_stage == RasterDebugStage.RADIX_ONLY:
		_log_stage("radix_only_gate", state, point_count)
		return

	compute_list = state.context.compute_list_begin()
	_assert_boundary_preconditions(state, point_count)
	_log_stage("boundaries_begin", state, point_count, {
		"tile_dims": str(state.tile_dims),
		"tile_bounds_capacity": state.diagnostics.get("tile_bounds_capacity", -1),
		"sort_capacity": state.diagnostics.get("num_sort_elements_max", -1)
	})
	state.pipelines["gsplat_boundaries"].call(state.context, compute_list, PackedByteArray())
	_log_stage("boundaries_end", state, point_count, {"tile_dims": str(state.tile_dims)})
	state.context.compute_list_end()

	if debug_raster_stage == RasterDebugStage.BOUNDARIES_ONLY:
		_log_stage("boundaries_only_gate", state, point_count)
		return

	compute_list = state.context.compute_list_begin()
	var render_push_constant := RenderingDeviceContext.create_push_constant([0.0, -1, state.depth_capture_alpha, 0.0])
	_log_stage("render_begin", state, point_count, {"push_constant_bytes": render_push_constant.size()})
	state.pipelines["gsplat_render"].call(
		state.context,
		compute_list,
		render_push_constant
	)
	_log_stage("render_end", state, point_count, {"push_constant_bytes": render_push_constant.size()})
	state.context.compute_list_end()

	if debug_raster_stage == RasterDebugStage.RENDER_ONLY:
		_log_stage("render_only_gate", state, point_count)
		return

	_log_stage("rasterize_state_return", state, point_count)

func _assert_projection_preconditions(state, point_count: int) -> void:
	assert(state.texture_size.x > 0 and state.texture_size.y > 0, "Projection output size must stay positive")
	assert(state.tile_dims.x > 0 and state.tile_dims.y > 0, "Projection tile dims must stay positive")
	assert(state.tile_dims == (state.texture_size + Vector2i(15, 15)) / 16, "Projection tile dims do not match texture size")
	assert(point_count > 0, "Projection point count must be positive")
	assert(state.camera_push_constants.size() == int(state.diagnostics.get("projection_push_constant_bytes_expected", 128)), "Projection push constant must stay 128 bytes")
	assert(int(state.camera_push_constants.size() / 4) == int(state.diagnostics.get("projection_push_constant_floats_expected", 32)), "Projection push constant must stay 32 floats")
	assert(int(state.diagnostics.get("projection_splat_stride_bytes_expected", 0)) == 60 * 4, "Projection splat stride must stay 240 bytes")
	assert(int(state.diagnostics.get("projection_culled_stride_bytes_expected", 0)) == 16 * 4, "Projection culled stride must stay 64 bytes")
	assert(int(state.diagnostics.get("projection_group_count", 0)) == ceili(point_count / 256.0), "Projection group count drifted from expected point-count-derived launch")
	assert(int(state.diagnostics.get("point_count_capacity", 0)) == point_count, "Projection state capacity no longer matches point count")
	assert(state.descriptors.has("projection_probe") and state.descriptors["projection_probe"].rid.is_valid(), "Projection probe buffer must exist before projection dispatch")

func _assert_boundary_preconditions(state, point_count: int) -> void:
	assert(state.tile_dims.x * state.tile_dims.y > 0, "Boundary pass requires at least one tile")
	assert(int(state.diagnostics.get("tile_bounds_capacity", 0)) == state.tile_dims.x * state.tile_dims.y, "Tile bounds capacity must match tile grid")
	assert(int(state.diagnostics.get("num_sort_elements_max", 0)) == point_count * MAX_SORT_ELEMENTS_PER_SPLAT, "Sort capacity drifted from point-count bounds assumption")

func _projection_diagnostic_details(state, point_count: int) -> Dictionary:
	return {
		"push_constant_bytes": state.camera_push_constants.size(),
		"push_constant_layout": str(state.diagnostics.get("projection_push_constant_layout", "unknown")),
		"push_constant_floats": int(state.camera_push_constants.size() / 4),
		"expected_group_count": state.diagnostics.get("projection_group_count", -1),
		"tile_bounds_capacity": state.diagnostics.get("tile_bounds_capacity", -1),
		"sort_capacity": state.diagnostics.get("num_sort_elements_max", -1),
		"max_tile_id": maxi(int(state.diagnostics.get("tile_bounds_capacity", 0)) - 1, -1),
		"splat_stride_bytes": state.diagnostics.get("projection_splat_stride_bytes_expected", -1),
		"culled_stride_bytes": state.diagnostics.get("projection_culled_stride_bytes_expected", -1),
		"point_count": point_count,
		"gpu_generation": int(state.gpu_generation),
		"cleanup_request_serial": int(state.last_cleanup_request_serial),
		"cleanup_request_reason": state.last_cleanup_reason,
		"projection_resource_snapshot": JSON.stringify(_projection_resource_snapshot(state))
	}

func _post_projection_sync_snapshot(state) -> Dictionary:
	return {
		"gpu_generation": int(state.gpu_generation),
		"projection_dispatch_serial": int(state.last_projection_dispatch_serial),
		"cleanup_request_serial": int(state.last_cleanup_request_serial),
		"cleanup_request_reason": state.last_cleanup_reason,
		"projection_resource_snapshot": _projection_resource_snapshot(state)
	}

func _projection_probe_seed_bytes(state, point_count: int) -> PackedByteArray:
	return _uint_words_byte_array([
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		int(state.diagnostics.get("num_sort_elements_max", 0)),
		int(state.diagnostics.get("tile_bounds_capacity", 0)),
		point_count,
		state.tile_dims.x,
		state.tile_dims.y,
		0,
		0,
		PROJECTION_FAILURE_NONE,
		0xFFFFFFFF,
		0,
		0,
		0,
		0,
		0,
		0,
		0
	])

func _scratch_probe_seed_bytes() -> PackedByteArray:
	return _uint_words_byte_array([
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0
	])

func _uint_words_byte_array(words: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(words.size() * 4)
	bytes.fill(0)
	for i in range(words.size()):
		bytes.encode_u32(i * 4, int(words[i]))
	return bytes

func _decode_u32_words(data: PackedByteArray) -> PackedInt32Array:
	var word_count := int(data.size() / 4)
	var words := PackedInt32Array()
	words.resize(word_count)
	for i in range(word_count):
		words[i] = int(data.decode_u32(i * 4))
	return words

func _format_u32_words_hex(data: PackedByteArray) -> String:
	var hex_words: Array[String] = []
	for i in range(int(data.size() / 4)):
		hex_words.append("0x%08x" % data.decode_u32(i * 4))
	return ",".join(hex_words)


func _probe_word(words: PackedInt32Array, index: int, fallback: int = -1) -> int:
	return words[index] if index >= 0 and index < words.size() else fallback

func _projection_error_flags_hex(value: int) -> String:
	return "0x%08x" % (value & 0xFFFFFFFF)

func _projection_failure_stage_name(value: int) -> String:
	match value:
		PROJECTION_FAILURE_NONE:
			return "none"
		PROJECTION_FAILURE_VIEW_POS_NON_FINITE:
			return "view_pos_non_finite"
		PROJECTION_FAILURE_CLIP_POS_NON_FINITE:
			return "clip_pos_non_finite"
		PROJECTION_FAILURE_COVARIANCE_NON_FINITE:
			return "covariance_non_finite"
		PROJECTION_FAILURE_DETERMINANT_NON_FINITE:
			return "determinant_non_finite"
		PROJECTION_FAILURE_EIGENVALUES_NON_FINITE:
			return "eigenvalues_non_finite"
		PROJECTION_FAILURE_IMAGE_POS_NON_FINITE:
			return "image_pos_non_finite"
		PROJECTION_FAILURE_RADIUS_NON_FINITE:
			return "radius_non_finite"
		PROJECTION_FAILURE_RECT_INVALID:
			return "rect_invalid"
		PROJECTION_FAILURE_SORT_OVERFLOW:
			return "sort_overflow_guarded"
		PROJECTION_FAILURE_TILE_ID_OOB:
			return "tile_id_oob_guarded"
		PROJECTION_FAILURE_VIEW_DEPTH_NON_FINITE:
			return "view_depth_non_finite"
		PROJECTION_FAILURE_CONIC_NON_FINITE:
			return "conic_non_finite"
		PROJECTION_FAILURE_COLOR_NON_FINITE:
			return "color_non_finite"
		_:
			return "unknown(%d)" % value

func _projection_probe_log_fields(projection_probe_words: PackedInt32Array) -> Dictionary:
	var sort_capacity := _probe_word(projection_probe_words, PROJECTION_PROBE_SORT_CAPACITY)
	var probe_tile_capacity := _probe_word(projection_probe_words, PROJECTION_PROBE_TILE_CAPACITY)
	var probe_error_flags := _probe_word(projection_probe_words, PROJECTION_PROBE_ERROR_FLAGS, 0)
	var probe_first_failure_stage := _probe_word(projection_probe_words, PROJECTION_PROBE_FIRST_FAILURE_STAGE, PROJECTION_FAILURE_NONE)
	var probe_max_sort_end := _probe_word(projection_probe_words, PROJECTION_PROBE_MAX_SORT_END)
	var probe_max_requested_sort_end := _probe_word(projection_probe_words, PROJECTION_PROBE_MAX_REQUESTED_SORT_END)
	var probe_max_tile_id := _probe_word(projection_probe_words, PROJECTION_PROBE_MAX_TILE_ID)
	var probe_max_requested_tile_id := _probe_word(projection_probe_words, PROJECTION_PROBE_MAX_REQUESTED_TILE_ID)
	return {
		"probe_words": str(projection_probe_words),
		"probe_invocations": _probe_word(projection_probe_words, PROJECTION_PROBE_INVOCATIONS),
		"probe_visible_splats": _probe_word(projection_probe_words, PROJECTION_PROBE_VISIBLE_SPLATS),
		"probe_duplicated_splats": _probe_word(projection_probe_words, PROJECTION_PROBE_DUPLICATED_SPLATS),
		"probe_emitted_sort_elements": _probe_word(projection_probe_words, PROJECTION_PROBE_EMITTED_SORT_ELEMENTS),
		"probe_max_sort_end": probe_max_sort_end,
		"probe_max_sort_end_within_capacity": str(probe_max_sort_end >= 0 and probe_max_sort_end <= sort_capacity),
		"probe_max_tile_id": probe_max_tile_id,
		"probe_max_tile_id_within_capacity": str(probe_max_tile_id >= 0 and probe_max_tile_id < probe_tile_capacity),
		"probe_max_tiles_touched": _probe_word(projection_probe_words, PROJECTION_PROBE_MAX_TILES_TOUCHED),
		"probe_zero_tile_splats": _probe_word(projection_probe_words, PROJECTION_PROBE_ZERO_TILE_SPLATS),
		"probe_error_flags": probe_error_flags,
		"probe_error_flags_hex": _projection_error_flags_hex(probe_error_flags),
		"probe_guard_abort_count": _probe_word(projection_probe_words, PROJECTION_PROBE_GUARD_ABORT_COUNT),
		"probe_first_failure_stage": probe_first_failure_stage,
		"probe_first_failure_stage_name": _projection_failure_stage_name(probe_first_failure_stage),
		"probe_first_failure_id": _probe_word(projection_probe_words, PROJECTION_PROBE_FIRST_FAILURE_ID),
		"probe_first_failure_value0": _probe_word(projection_probe_words, PROJECTION_PROBE_FIRST_FAILURE_VALUE0),
		"probe_first_failure_value1": _probe_word(projection_probe_words, PROJECTION_PROBE_FIRST_FAILURE_VALUE1),
		"probe_max_requested_sort_end": probe_max_requested_sort_end,
		"probe_max_requested_sort_end_within_capacity": str(probe_max_requested_sort_end >= 0 and probe_max_requested_sort_end <= sort_capacity),
		"probe_max_requested_tile_id": probe_max_requested_tile_id,
		"probe_max_requested_tile_id_within_capacity": str(probe_max_requested_tile_id >= 0 and probe_max_requested_tile_id < probe_tile_capacity),
		"probe_non_finite_failure_count": _probe_word(projection_probe_words, PROJECTION_PROBE_NON_FINITE_FAILURE_COUNT),
		"probe_sort_overflow_guard_count": _probe_word(projection_probe_words, PROJECTION_PROBE_SORT_OVERFLOW_GUARD_COUNT),
		"probe_tile_guard_count": _probe_word(projection_probe_words, PROJECTION_PROBE_TILE_GUARD_COUNT)
	}

func _run_projection_post_dispatch_checkpoint(state, point_count: int, checkpoint: int) -> void:
	var checkpoint_name := _projection_readback_checkpoint_name(checkpoint)
	_log_stage("projection_post_dispatch_checkpoint_begin", state, point_count, {
		"checkpoint": checkpoint_name
	})
	match checkpoint:
		ProjectionReadbackCheckpoint.FULL_PACKAGE:
			_log_projection_post_dispatch_evidence(state, point_count)
		ProjectionReadbackCheckpoint.DISABLED:
			_log_stage("projection_post_dispatch_checkpoint_disabled", state, point_count, {
				"checkpoint": checkpoint_name
			})
		ProjectionReadbackCheckpoint.HISTOGRAM_HEADER_ONLY:
			_log_projection_histogram_header_readback(state, point_count)
		ProjectionReadbackCheckpoint.PROJECTION_PROBE_ONLY:
			_log_projection_probe_readback(state, point_count)
		ProjectionReadbackCheckpoint.SORT_KEYS_SENTINEL_ONLY:
			_log_projection_sort_keys_sentinel_readback(state, point_count)
		ProjectionReadbackCheckpoint.SORT_VALUES_SENTINEL_ONLY:
			_log_projection_sort_values_sentinel_readback(state, point_count)
		ProjectionReadbackCheckpoint.CULLED_SPLATS_SENTINEL_ONLY:
			_log_projection_culled_splats_sentinel_readback(state, point_count)
		ProjectionReadbackCheckpoint.SCRATCH_PROJECTION_MIRROR_ONLY:
			_log_projection_scratch_mirror_readback(state, point_count)
		_:
			_log_stage("projection_post_dispatch_checkpoint_unknown", state, point_count, {
				"checkpoint": checkpoint_name
			})
	_log_stage("projection_post_dispatch_checkpoint_end", state, point_count, {
		"checkpoint": checkpoint_name,
		"gpu_generation": int(state.gpu_generation),
		"projection_dispatch_serial": int(state.last_projection_dispatch_serial),
		"projection_resource_snapshot": JSON.stringify(_projection_resource_snapshot(state))
	})

func _log_projection_histogram_header_readback(state, point_count: int) -> void:
	_log_stage("projection_readback_histogram_header_begin", state, point_count, {
		"histogram_valid": str(state.descriptors["histogram"].rid.is_valid())
	})
	var histogram_data: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["histogram"].rid, 0, 4)
	var sort_buffer_size: int = histogram_data.decode_u32(0) if histogram_data.size() >= 4 else -1
	var sort_capacity := int(state.diagnostics.get("num_sort_elements_max", 0))
	_log_stage("projection_readback_histogram_header_end", state, point_count, {
		"histogram_bytes": histogram_data.size(),
		"sort_buffer_size": sort_buffer_size,
		"sort_capacity": sort_capacity,
		"sort_within_capacity": str(sort_buffer_size >= 0 and sort_buffer_size <= sort_capacity)
	})

func _log_projection_probe_readback(state, point_count: int) -> void:
	_log_stage("projection_readback_projection_probe_begin", state, point_count, {
		"projection_probe_valid": str(state.descriptors["projection_probe"].rid.is_valid())
	})
	var projection_probe_data: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["projection_probe"].rid, 0, int(state.diagnostics.get("projection_probe_words", 0)) * 4)
	var projection_probe_words: PackedInt32Array = _decode_u32_words(projection_probe_data)
	_log_stage("projection_readback_projection_probe_end", state, point_count, _projection_probe_log_fields(projection_probe_words))

func _log_projection_scratch_mirror_readback(state, point_count: int) -> void:
	_log_stage("projection_readback_scratch_mirror_begin", state, point_count, {
		"scratch_probe_valid": str(state.descriptors["scratch_probe"].rid.is_valid())
	})
	var scratch_data: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["scratch_probe"].rid, 0, int(state.diagnostics.get("scratch_probe_words", 0)) * 4)
	_log_stage("projection_readback_scratch_mirror_end", state, point_count, _scratch_probe_log_fields(scratch_data))

func _log_projection_sort_keys_sentinel_readback(state, point_count: int) -> void:
	_log_stage("projection_readback_sort_keys_sentinel_begin", state, point_count, {
		"sort_keys_valid": str(state.descriptors["sort_keys"].rid.is_valid())
	})
	var first_sort_keys: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["sort_keys"].rid, 0, 4 * 4)
	_log_stage("projection_readback_sort_keys_sentinel_end", state, point_count, {
		"first_sort_keys": _format_u32_words_hex(first_sort_keys)
	})

func _log_projection_sort_values_sentinel_readback(state, point_count: int) -> void:
	_log_stage("projection_readback_sort_values_sentinel_begin", state, point_count, {
		"sort_values_valid": str(state.descriptors["sort_values"].rid.is_valid())
	})
	var first_sort_values: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["sort_values"].rid, 0, 4 * 4)
	_log_stage("projection_readback_sort_values_sentinel_end", state, point_count, {
		"first_sort_values": _format_u32_words_hex(first_sort_values)
	})

func _log_projection_culled_splats_sentinel_readback(state, point_count: int) -> void:
	_log_stage("projection_readback_culled_splats_sentinel_begin", state, point_count, {
		"culled_buffer_valid": str(state.descriptors["culled_splats"].rid.is_valid())
	})
	var first_culled_words: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["culled_splats"].rid, 0, 4 * 4)
	_log_stage("projection_readback_culled_splats_sentinel_end", state, point_count, {
		"first_culled_words": _format_u32_words_hex(first_culled_words)
	})

func _log_projection_post_dispatch_evidence(state, point_count: int) -> void:
	_log_stage("projection_post_dispatch_full_package_begin", state, point_count)
	var histogram_data: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["histogram"].rid, 0, 4)
	var sort_buffer_size: int = histogram_data.decode_u32(0) if histogram_data.size() >= 4 else -1
	var sort_capacity := int(state.diagnostics.get("num_sort_elements_max", 0))
	var projection_probe_data: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["projection_probe"].rid, 0, int(state.diagnostics.get("projection_probe_words", 0)) * 4)
	var projection_probe_words: PackedInt32Array = _decode_u32_words(projection_probe_data)
	var scratch_data: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["scratch_probe"].rid, 0, int(state.diagnostics.get("scratch_probe_words", 0)) * 4)
	var first_sort_keys: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["sort_keys"].rid, 0, 4 * 4)
	var first_sort_values: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["sort_values"].rid, 0, 4 * 4)
	var first_culled_words: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["culled_splats"].rid, 0, 4 * 4)
	var extras := {
		"histogram_bytes": histogram_data.size(),
		"sort_buffer_size": sort_buffer_size,
		"sort_capacity": sort_capacity,
		"sort_within_capacity": str(sort_buffer_size >= 0 and sort_buffer_size <= sort_capacity),
		"first_sort_keys": _format_u32_words_hex(first_sort_keys),
		"first_sort_values": _format_u32_words_hex(first_sort_values),
		"first_culled_words": _format_u32_words_hex(first_culled_words),
		"culled_buffer_valid": str(state.descriptors["culled_splats"].rid.is_valid()),
		"sort_keys_valid": str(state.descriptors["sort_keys"].rid.is_valid()),
		"sort_values_valid": str(state.descriptors["sort_values"].rid.is_valid()),
		"histogram_valid": str(state.descriptors["histogram"].rid.is_valid()),
		"scratch_probe_valid": str(state.descriptors["scratch_probe"].rid.is_valid())
	}
	extras.merge(_projection_probe_log_fields(projection_probe_words))
	extras.merge(_scratch_probe_log_fields(scratch_data))
	_log_stage("projection_post_dispatch", state, point_count, extras)
	_log_stage("projection_post_dispatch_full_package_end", state, point_count)

func _scratch_probe_log_fields(scratch_data: PackedByteArray) -> Dictionary:
	var scratch_words_hex: Array[String] = []
	for i in range(int(scratch_data.size() / 4)):
		scratch_words_hex.append("0x%08x" % scratch_data.decode_u32(i * 4))
	var scratch_words := _decode_u32_words(scratch_data)
	var scratch_signature_ok := scratch_words.size() >= 4 \
		and scratch_words_hex[SCRATCH_PROBE_SIGNATURE_WORD0] == "0x47534744" \
		and scratch_words_hex[SCRATCH_PROBE_SIGNATURE_WORD1] == "0x00000001" \
		and scratch_words_hex[SCRATCH_PROBE_SIGNATURE_WORD2] == "0x00000001" \
		and scratch_words_hex[SCRATCH_PROBE_SIGNATURE_WORD3] == "0x5a5aa5a5"
	var projection_stage_bits := _probe_word(scratch_words, SCRATCH_PROBE_PROJECTION_STAGE_BITS, 0)
	return {
		"scratch_words": ",".join(scratch_words_hex),
		"scratch_signature_ok": str(scratch_signature_ok),
		"scratch_projection_invocations": _probe_word(scratch_words, SCRATCH_PROBE_PROJECTION_INVOCATIONS, 0),
		"scratch_projection_visible_splats": _probe_word(scratch_words, SCRATCH_PROBE_PROJECTION_VISIBLE_SPLATS, 0),
		"scratch_projection_stage_bits": projection_stage_bits,
		"scratch_projection_stage_bits_hex": "0x%08x" % (projection_stage_bits & 0xFFFFFFFF),
		"scratch_projection_entered": str((projection_stage_bits & SCRATCH_PROJECTION_STAGE_ENTRY) != 0),
		"scratch_projection_visible_path": str((projection_stage_bits & SCRATCH_PROJECTION_STAGE_VISIBLE) != 0),
		"scratch_projection_culled_write": str((projection_stage_bits & SCRATCH_PROJECTION_STAGE_CULLED_WRITE) != 0),
		"scratch_projection_sort_reserved": str((projection_stage_bits & SCRATCH_PROJECTION_STAGE_SORT_RESERVED) != 0),
		"scratch_projection_sort_written": str((projection_stage_bits & SCRATCH_PROJECTION_STAGE_SORT_WRITTEN) != 0),
		"scratch_projection_max_requested_sort_end": _probe_word(scratch_words, SCRATCH_PROBE_PROJECTION_MAX_REQUESTED_SORT_END, 0)
	}

func _log_scratch_probe_readback(state, point_count: int) -> void:
	var scratch_data: PackedByteArray = state.context.device.buffer_get_data(state.descriptors["scratch_probe"].rid, 0, int(state.diagnostics.get("scratch_probe_words", 0)) * 4)
	var extras := _scratch_probe_log_fields(scratch_data)
	extras.merge({
		"scratch_probe_valid": str(state.descriptors["scratch_probe"].rid.is_valid()),
		"histogram_valid": str(state.descriptors["histogram"].rid.is_valid())
	})
	_log_stage("scratch_post_dispatch", state, point_count, extras)

func _update_camera_from_transform(state, camera_transform: Transform3D, camera_projection: Projection) -> void:
	var view := Projection(camera_transform.affine_inverse())
	if view != state.camera_view or camera_projection != state.camera_projection:
		state.camera_view = view
		state.camera_projection = camera_projection
		state.camera_push_constants = RenderingDeviceContext.create_push_constant(
			_projection_to_column_major_floats(view) + _projection_to_column_major_floats(camera_projection)
		)

func _projection_to_column_major_floats(matrix: Projection) -> Array:
	return [
		matrix.x[0], matrix.x[1], matrix.x[2], matrix.x[3],
		matrix.y[0], matrix.y[1], matrix.y[2], matrix.y[3],
		matrix.z[0], matrix.z[1], matrix.z[2], matrix.z[3],
		matrix.w[0], matrix.w[1], matrix.w[2], matrix.w[3]
	]

func _log_once(key: String, message: String) -> void:
	if _once_logs.get(key, false):
		return
	_once_logs[key] = true
	print(message)

func _log_stage(stage: String, state, point_count: int, extras: Dictionary = {}) -> void:
	var details := [
		"[gdgs] renderer stage=%s" % stage,
		"point_count=%d" % point_count,
		"texture_size=%s" % str(state.texture_size),
		"tile_dims=%s" % str(state.tile_dims)
	]
	for key in extras.keys():
		details.append("%s=%s" % [str(key), str(extras[key])])
	print(" ".join(details))

func _raster_stage_name(value: int) -> String:
	match value:
		RasterDebugStage.FULL_PIPELINE:
			return "full_pipeline"
		RasterDebugStage.PREPARED_NO_DISPATCH:
			return "prepared_no_dispatch"
		RasterDebugStage.PROJECTION_ONLY:
			return "projection_only"
		RasterDebugStage.RADIX_ONLY:
			return "radix_only"
		RasterDebugStage.BOUNDARIES_ONLY:
			return "boundaries_only"
		RasterDebugStage.RENDER_ONLY:
			return "render_only"
		RasterDebugStage.SCRATCH_ONLY:
			return "scratch_only"
		_:
			return "unknown(%d)" % value

func _projection_readback_checkpoint_name(value: int) -> String:
	match value:
		ProjectionReadbackCheckpoint.FULL_PACKAGE:
			return "full_package"
		ProjectionReadbackCheckpoint.DISABLED:
			return "disabled"
		ProjectionReadbackCheckpoint.HISTOGRAM_HEADER_ONLY:
			return "histogram_header_only"
		ProjectionReadbackCheckpoint.PROJECTION_PROBE_ONLY:
			return "projection_probe_only"
		ProjectionReadbackCheckpoint.SORT_KEYS_SENTINEL_ONLY:
			return "sort_keys_sentinel_only"
		ProjectionReadbackCheckpoint.SORT_VALUES_SENTINEL_ONLY:
			return "sort_values_sentinel_only"
		ProjectionReadbackCheckpoint.CULLED_SPLATS_SENTINEL_ONLY:
			return "culled_splats_sentinel_only"
		ProjectionReadbackCheckpoint.SCRATCH_PROJECTION_MIRROR_ONLY:
			return "scratch_projection_mirror_only"
		_:
			return "unknown(%d)" % value

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
