@tool
class_name GaussianCompositorEffect
extends CompositorEffect

const WORKGROUP_SIZE := 16
const MANAGER_SCRIPT := preload("res://addons/gdgs/runtime/render/gaussian_render_manager.gd")
const DIRECT_TEXTURE_SHADER := preload("res://addons/gdgs/runtime/debug/shaders/direct_texture_overlay.gdshader")
const DIRECT_TEXTURE_WORLD_OVERLAY_NAME := "_GdgsDirectTextureWorldOverlay"
const DIRECT_TEXTURE_CANVAS_LAYER_NAME := "_GdgsDirectTextureCanvasLayer"
const DIRECT_TEXTURE_CANVAS_RECT_NAME := "_GdgsDirectTextureCanvasRect"
const DEFAULT_TEXTURE_USAGE_BITS := 0x18B

enum DisplayMode {
	COMPOSITOR,
	DIRECT_TEXTURE_WORLD,
	DIRECT_TEXTURE_CANVAS,
	NO_PRESENT
}

enum DebugView {
	COMPOSITE,
	GS_ALPHA,
	GS_COLOR,
	GS_DEPTH,
	SCENE_DEPTH,
	DEPTH_REJECT_MASK
}

enum CompositorDebugStage {
	FULL_PIPELINE,
	CALLBACK_ONLY,
	RASTER_ONLY_NO_WRITEBACK
}

@export_range(0.0, 1.0, 0.001) var alpha_cutoff := 0.01
@export_range(0.0, 1.0, 0.001) var depth_bias := 0.05
@export_range(0.0, 1.0, 0.001) var depth_test_min_alpha := 0.05
@export_range(0.0, 1.0, 0.001) var depth_capture_alpha = 0.5
@export_enum("Compositor", "Direct Texture (World Overlay)", "Direct Texture (Canvas Overlay)", "No Present") var display_mode: int:
	set(value):
		_display_mode = clampi(value, DisplayMode.COMPOSITOR, DisplayMode.NO_PRESENT)
		if not _display_mode_uses_overlay(_display_mode):
			_queue_direct_texture_presentation(DisplayMode.COMPOSITOR, RID())
	get:
		return _display_mode
@export_enum("Composite", "GS Alpha", "GS Color", "GS Depth", "Scene Depth", "Depth Reject Mask") var debug_view: int = DebugView.COMPOSITE
@export var ignore_scene_depth_in_composite := false
@export_enum("Full Pipeline", "Callback Only", "Raster Only (No Writeback)") var debug_compositor_stage: int = CompositorDebugStage.FULL_PIPELINE
@export_enum("Full Pipeline", "Prepared / No Dispatch", "Projection Only", "Projection Footprint Only", "Projection Non-Footprint Immediate Return Only", "Projection Post-Barrier No-Scratch Immediate Return Only", "Projection Post-Barrier Immediate Return Only", "Projection Instance-Data Block Only", "Projection Instance Data Only", "Projection Model Matrix Only", "Projection Splat Payload Only", "Projection Dummy Output Write Only", "Radix Only", "Boundaries Only", "Render Only", "Scratch Dispatch Only") var debug_raster_stage: int = 0
@export_enum("Full Package", "Disabled / No Readback", "Histogram Header Only", "Projection Probe Only", "Sort Keys Sentinel Only", "Sort Values Sentinel Only", "Culled Splats Sentinel Only", "Scratch Projection Mirror Only") var debug_projection_readback_checkpoint: int = 0
@export_enum("Disabled", "Markers Only", "Empty Compute Boundary") var debug_backend_consume_trace_mode: int = 0

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var depth_sampler: RID
var fallback_depth_texture: RID

var _display_mode := DisplayMode.COMPOSITOR
var _direct_texture_resource: Texture2DRD
var _overlay_mutex := Mutex.new()
var _once_logs := {}
var _overlay_sync_queued := false
var _overlay_pending_mode := DisplayMode.COMPOSITOR
var _overlay_pending_texture_rid := RID()

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_depth = true
	RenderingServer.call_on_render_thread(initialize_compute_shader)

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return

	_overlay_mutex.lock()
	_overlay_sync_queued = false
	_overlay_pending_mode = DisplayMode.COMPOSITOR
	_overlay_pending_texture_rid = RID()
	_overlay_mutex.unlock()

	if _direct_texture_resource != null:
		_direct_texture_resource.texture_rd_rid = RID()
		_direct_texture_resource = null

	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		var tree: SceneTree = main_loop
		if tree.root != null:
			var world_overlay := tree.root.get_node_or_null(DIRECT_TEXTURE_WORLD_OVERLAY_NAME) as MeshInstance3D
			if world_overlay != null:
				world_overlay.queue_free()
			var canvas_layer := tree.root.get_node_or_null(DIRECT_TEXTURE_CANVAS_LAYER_NAME) as CanvasLayer
			if canvas_layer != null:
				canvas_layer.queue_free()

	if rd != null:
		if fallback_depth_texture.is_valid():
			rd.free_rid(fallback_depth_texture)
		if pipeline.is_valid():
			rd.free_rid(pipeline)
		if shader.is_valid():
			rd.free_rid(shader)
		if depth_sampler.is_valid():
			rd.free_rid(depth_sampler)
	fallback_depth_texture = RID()
	pipeline = RID()
	shader = RID()
	depth_sampler = RID()

func _render_callback(_effect_callback_type: int, render_data: RenderData) -> void:
	var current_display_mode := int(display_mode)
	var uses_overlay := _display_mode_uses_overlay(current_display_mode)
	var is_no_present_mode := current_display_mode == DisplayMode.NO_PRESENT
	_log_once(
		"mode_summary",
		"[gdgs] compositor mode=%s debug_view=%s ignore_scene_depth_in_composite=%s enabled=%s" % [
			_display_mode_name(current_display_mode),
			_debug_view_name(debug_view),
			str(ignore_scene_depth_in_composite),
			str(enabled)
		]
	)
	_log_once(
		"debug_stage_summary",
		"[gdgs] compositor stage gate=%s raster stage gate=%s projection readback checkpoint=%s" % [
			_compositor_stage_name(debug_compositor_stage),
			_raster_stage_name(debug_raster_stage),
			_projection_readback_checkpoint_name(debug_projection_readback_checkpoint)
		]
	)
	_log_once("render_callback_entered", "[gdgs] compositor render callback entered")
	print("[gdgs] compositor stage=enter_callback mode=%s compositor_stage=%s raster_stage=%s projection_readback_checkpoint=%s" % [
		_display_mode_name(current_display_mode),
		_compositor_stage_name(debug_compositor_stage),
		_raster_stage_name(debug_raster_stage),
		_projection_readback_checkpoint_name(debug_projection_readback_checkpoint)
	])
	if not (uses_overlay or is_no_present_mode) and (not rd or not shader.is_valid() or not pipeline.is_valid()):
		_queue_direct_texture_presentation(DisplayMode.COMPOSITOR, RID())
		return

	var scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var scene_data: RenderSceneDataRD = render_data.get_render_scene_data()
	if scene_buffers == null or scene_data == null:
		_queue_direct_texture_presentation(DisplayMode.COMPOSITOR, RID())
		return

	var manager = MANAGER_SCRIPT.get_instance()
	_log_once("manager_lookup", "[gdgs] compositor manager lookup result=%s" % ("found" if manager != null else "missing"))
	if manager == null:
		_queue_direct_texture_presentation(DisplayMode.COMPOSITOR, RID())
		return

	var global_rd := RenderingServer.get_rendering_device()
	_log_once(
		"rd_seam_correction",
		"[gdgs] seam correction compositor_path_uses_global_rd=%s raster_path_expected_global_rd=%s local_device_submit_sync_exercised=%s" % [
			str(global_rd != null and rd == global_rd),
			"true",
			"false"
		]
	)
	if debug_compositor_stage == CompositorDebugStage.CALLBACK_ONLY:
		print("[gdgs] compositor stage=callback_only_gate skipped render_for_compositor and writeback")
		_queue_direct_texture_presentation(DisplayMode.COMPOSITOR, RID())
		return

	var size: Vector2i = scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		_queue_direct_texture_presentation(DisplayMode.COMPOSITOR, RID())
		return

	var x_groups: int = 0
	var y_groups: int = 0
	if not (uses_overlay or is_no_present_mode):
		x_groups = int(ceili(size.x / float(WORKGROUP_SIZE)))
		y_groups = int(ceili(size.y / float(WORKGROUP_SIZE)))

	var direct_texture_presented := false
	for view in scene_buffers.get_view_count():
		var camera_data := _get_camera_data(scene_data, view)
		if camera_data.is_empty():
			continue

		print("[gdgs] compositor stage=camera_data_ready view=%d size=%s" % [view, str(size)])
		var gsplat_result: Dictionary = manager.render_for_compositor(
			size,
			camera_data["transform"],
			camera_data["projection"],
			camera_data["world_position"],
			_get_depth_capture_alpha(),
			debug_raster_stage,
			debug_projection_readback_checkpoint,
			debug_backend_consume_trace_mode
		)
		print("[gdgs] compositor stage=render_for_compositor_returned view=%d empty=%s" % [view, str(gsplat_result.is_empty())])
		var debug_sync_snapshot: Dictionary = gsplat_result.get("debug_sync_snapshot", {})
		if not debug_sync_snapshot.is_empty():
			print("[gdgs] compositor stage=render_for_compositor_sync_snapshot view=%d snapshot=%s" % [view, JSON.stringify(debug_sync_snapshot)])
		if gsplat_result.is_empty():
			_log_once("render_result_empty", "[gdgs] render_for_compositor() returned an empty result")
			continue

		var gsplat_texture: RID = gsplat_result.get("color_alpha_texture", RID())
		var gsplat_depth_texture: RID = gsplat_result.get("depth_texture", RID())
		_log_once(
			"render_result_validity",
			"[gdgs] render_for_compositor() textures color_valid=%s depth_valid=%s" % [
				str(gsplat_texture.is_valid()),
				str(gsplat_depth_texture.is_valid())
			]
		)
		if not gsplat_texture.is_valid() or not gsplat_depth_texture.is_valid():
			continue

		if uses_overlay:
			_queue_direct_texture_presentation(current_display_mode, gsplat_texture)
			direct_texture_presented = true
			break

		if is_no_present_mode:
			_log_once("no_present", "[gdgs] no-present mode captured valid compositor textures and skipped all writeback/presentation work")
			print("[gdgs] compositor stage=no_present_early_out view=%d" % view)
			break
		if debug_compositor_stage == CompositorDebugStage.RASTER_ONLY_NO_WRITEBACK:
			print("[gdgs] compositor stage=raster_only_no_writeback_gate view=%d" % view)
			break

		var scene_tex: RID = scene_buffers.get_color_layer(view)
		if not scene_tex.is_valid() or not depth_sampler.is_valid():
			continue

		var use_scene_depth := _debug_view_needs_scene_depth(debug_view)
		if ignore_scene_depth_in_composite and debug_view == DebugView.COMPOSITE:
			use_scene_depth = false
		var scene_depth_tex: RID = _get_scene_depth_texture(scene_buffers, view)
		if use_scene_depth and not scene_depth_tex.is_valid():
			continue
		if not scene_depth_tex.is_valid():
			scene_depth_tex = fallback_depth_texture
		if not scene_depth_tex.is_valid():
			continue

		var push_constants := PackedFloat32Array([
			size.x,
			size.y,
			alpha_cutoff,
			depth_bias,
			depth_test_min_alpha,
			float(debug_view),
			1.0 if use_scene_depth else 0.0,
			0.0
		] + _projection_to_column_major_floats(camera_data["projection"].inverse()))

		var scene_uniform := RDUniform.new()
		scene_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		scene_uniform.binding = 0
		scene_uniform.add_id(scene_tex)

		var gsplat_uniform := RDUniform.new()
		gsplat_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		gsplat_uniform.binding = 1
		gsplat_uniform.add_id(gsplat_texture)

		var gsplat_depth_uniform := RDUniform.new()
		gsplat_depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		gsplat_depth_uniform.binding = 2
		gsplat_depth_uniform.add_id(gsplat_depth_texture)

		var scene_depth_uniform := RDUniform.new()
		scene_depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		scene_depth_uniform.binding = 3
		scene_depth_uniform.add_id(depth_sampler)
		scene_depth_uniform.add_id(scene_depth_tex)

		var uniform_set: RID = UniformSetCacheRD.get_cache(shader, 0, [
			scene_uniform,
			gsplat_uniform,
			gsplat_depth_uniform,
			scene_depth_uniform
		])
		print("[gdgs] compositor stage=writeback_uniform_set_created view=%d uniform_set_valid=%s" % [view, str(uniform_set.is_valid())])
		_log_once(
			"dispatch",
			"[gdgs] compositor dispatch pending display_mode=%s debug_view=%s use_scene_depth=%s size=%s" % [
				_display_mode_name(current_display_mode),
				_debug_view_name(debug_view),
				str(use_scene_depth),
				str(size)
			]
		)
		var compute_list: int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		rd.compute_list_set_push_constant(
			compute_list,
			push_constants.to_byte_array(),
			push_constants.size() * 4
		)
		print("[gdgs] compositor stage=writeback_dispatch_submitted view=%d groups=%s push_constant_bytes=%d" % [view, str(Vector3i(x_groups, y_groups, 1)), push_constants.size() * 4])
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()

	if uses_overlay and not direct_texture_presented:
		_queue_direct_texture_presentation(DisplayMode.COMPOSITOR, RID())
	elif not uses_overlay:
		_queue_direct_texture_presentation(DisplayMode.COMPOSITOR, RID())
	print("[gdgs] compositor stage=callback_return uses_overlay=%s no_present=%s" % [str(uses_overlay), str(is_no_present_mode)])

func _get_camera_data(scene_data: RenderSceneDataRD, view: int) -> Dictionary:
	if scene_data == null:
		return {}
	if not scene_data.has_method("get_cam_transform") or not scene_data.has_method("get_view_projection"):
		return {}
	var camera_transform: Transform3D = scene_data.get_cam_transform()
	var camera_projection: Projection = scene_data.get_view_projection(view)
	var world_position: Vector3 = camera_transform.origin

	return {
		"transform": camera_transform,
		"projection": camera_projection,
		"world_position": world_position
	}

func _get_scene_depth_texture(scene_buffers: RenderSceneBuffersRD, view: int) -> RID:
	if scene_buffers == null:
		return RID()

	if scene_buffers.has_method("has_texture") and scene_buffers.has_method("get_texture_slice") and scene_buffers.has_texture("render_buffers", "depth"):
		var depth_slice: RID = scene_buffers.get_texture_slice("render_buffers", "depth", view, 0, 1, 1)
		if depth_slice.is_valid():
			return depth_slice

	if scene_buffers.has_method("get_depth_layer"):
		return scene_buffers.get_depth_layer(view)

	return RID()

func _projection_to_column_major_floats(matrix: Projection) -> Array:
	return [
		matrix.x[0], matrix.x[1], matrix.x[2], matrix.x[3],
		matrix.y[0], matrix.y[1], matrix.y[2], matrix.y[3],
		matrix.z[0], matrix.z[1], matrix.z[2], matrix.z[3],
		matrix.w[0], matrix.w[1], matrix.w[2], matrix.w[3]
	]

func _get_depth_capture_alpha() -> float:
	if depth_capture_alpha == null:
		return 0.5
	return clampf(float(depth_capture_alpha), 0.0, 1.0)

func _debug_view_needs_scene_depth(view: int) -> bool:
	return view == DebugView.COMPOSITE or view == DebugView.SCENE_DEPTH or view == DebugView.DEPTH_REJECT_MASK

func _log_once(key: String, message: String) -> void:
	if _once_logs.get(key, false):
		return
	_once_logs[key] = true
	print(message)

func _display_mode_name(value: int) -> String:
	match value:
		DisplayMode.COMPOSITOR:
			return "Compositor"
		DisplayMode.DIRECT_TEXTURE_WORLD:
			return "Direct Texture (World Overlay)"
		DisplayMode.DIRECT_TEXTURE_CANVAS:
			return "Direct Texture (Canvas Overlay)"
		DisplayMode.NO_PRESENT:
			return "No Present"
		_:
			return "Unknown(%d)" % value

func _display_mode_uses_overlay(value: int) -> bool:
	return value == DisplayMode.DIRECT_TEXTURE_WORLD or value == DisplayMode.DIRECT_TEXTURE_CANVAS

func _debug_view_name(value: int) -> String:
	match value:
		DebugView.COMPOSITE:
			return "Composite"
		DebugView.GS_ALPHA:
			return "GS Alpha"
		DebugView.GS_COLOR:
			return "GS Color"
		DebugView.GS_DEPTH:
			return "GS Depth"
		DebugView.SCENE_DEPTH:
			return "Scene Depth"
		DebugView.DEPTH_REJECT_MASK:
			return "Depth Reject Mask"
		_:
			return "Unknown(%d)" % value

func _compositor_stage_name(value: int) -> String:
	match value:
		CompositorDebugStage.FULL_PIPELINE:
			return "full_pipeline"
		CompositorDebugStage.CALLBACK_ONLY:
			return "callback_only"
		CompositorDebugStage.RASTER_ONLY_NO_WRITEBACK:
			return "raster_only_no_writeback"
		_:
			return "Unknown(%d)" % value

func _raster_stage_name(value: int) -> String:
	match value:
		GaussianRenderer.RasterDebugStage.FULL_PIPELINE:
			return "full_pipeline"
		GaussianRenderer.RasterDebugStage.PREPARED_NO_DISPATCH:
			return "prepared_no_dispatch"
		GaussianRenderer.RasterDebugStage.PROJECTION_ONLY:
			return "projection_only"
		GaussianRenderer.RasterDebugStage.PROJECTION_FOOTPRINT_ONLY:
			return "projection_footprint_only"
		GaussianRenderer.RasterDebugStage.PROJECTION_NON_FOOTPRINT_IMMEDIATE_RETURN_ONLY:
			return "projection_non_footprint_immediate_return_only"
		GaussianRenderer.RasterDebugStage.PROJECTION_POST_BARRIER_NO_SCRATCH_IMMEDIATE_RETURN_ONLY:
			return "projection_post_barrier_no_scratch_immediate_return_only"
		GaussianRenderer.RasterDebugStage.PROJECTION_POST_BARRIER_IMMEDIATE_RETURN_ONLY:
			return "projection_post_barrier_immediate_return_only"
		GaussianRenderer.RasterDebugStage.PROJECTION_INSTANCE_DATA_BLOCK_ONLY:
			return "projection_instance_data_block_only"
		GaussianRenderer.RasterDebugStage.PROJECTION_INSTANCE_DATA_ONLY:
			return "projection_instance_data_only"
		GaussianRenderer.RasterDebugStage.PROJECTION_MODEL_MATRIX_ONLY:
			return "projection_model_matrix_only"
		GaussianRenderer.RasterDebugStage.PROJECTION_SPLAT_PAYLOAD_ONLY:
			return "projection_splat_payload_only"
		GaussianRenderer.RasterDebugStage.PROJECTION_DUMMY_OUTPUT_WRITE_ONLY:
			return "projection_dummy_output_write_only"
		GaussianRenderer.RasterDebugStage.RADIX_ONLY:
			return "radix_only"
		GaussianRenderer.RasterDebugStage.BOUNDARIES_ONLY:
			return "boundaries_only"
		GaussianRenderer.RasterDebugStage.RENDER_ONLY:
			return "render_only"
		GaussianRenderer.RasterDebugStage.SCRATCH_ONLY:
			return "scratch_only"
		_:
			return "Unknown(%d)" % value

func initialize_compute_shader() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		return

	var glsl_file: RDShaderFile = load("res://addons/gdgs/runtime/compositor/shaders/gaussian_composite.glsl")
	if glsl_file == null:
		return

	shader = rd.shader_create_from_spirv(glsl_file.get_spirv())
	pipeline = rd.compute_pipeline_create(shader)
	var sampler_state := RDSamplerState.new()
	depth_sampler = rd.sampler_create(sampler_state)
	fallback_depth_texture = _create_fallback_depth_texture()

func _create_fallback_depth_texture() -> RID:
	if rd == null:
		return RID()

	var texture_format := RDTextureFormat.new()
	texture_format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	texture_format.width = 1
	texture_format.height = 1
	texture_format.usage_bits = DEFAULT_TEXTURE_USAGE_BITS

	return rd.texture_create(
		texture_format,
		RDTextureView.new(),
		[PackedFloat32Array([1.0]).to_byte_array()]
	)

func _queue_direct_texture_presentation(mode: int, texture_rid: RID) -> void:
	var next_mode := mode if _display_mode_uses_overlay(mode) and texture_rid.is_valid() else DisplayMode.COMPOSITOR
	var next_texture_rid := texture_rid if next_mode != DisplayMode.COMPOSITOR else RID()

	_overlay_mutex.lock()
	var state_changed := _overlay_pending_mode != next_mode or _overlay_pending_texture_rid != next_texture_rid
	_overlay_pending_mode = next_mode
	_overlay_pending_texture_rid = next_texture_rid
	var should_queue := state_changed and not _overlay_sync_queued
	if should_queue:
		_overlay_sync_queued = true
	_overlay_mutex.unlock()

	if should_queue:
		call_deferred("_sync_direct_texture_presentation")

func _sync_direct_texture_presentation() -> void:
	var pending_mode := DisplayMode.COMPOSITOR
	var pending_texture_rid := RID()

	_overlay_mutex.lock()
	pending_mode = _overlay_pending_mode
	pending_texture_rid = _overlay_pending_texture_rid
	_overlay_sync_queued = false
	_overlay_mutex.unlock()

	var texture := _ensure_direct_texture_resource()
	if texture == null:
		return
	texture.texture_rd_rid = pending_texture_rid if _display_mode_uses_overlay(pending_mode) else RID()

	var world_overlay := _get_direct_texture_world_overlay()
	if pending_mode == DisplayMode.DIRECT_TEXTURE_WORLD:
		world_overlay = _ensure_direct_texture_world_overlay()
	if world_overlay != null:
		world_overlay.visible = pending_mode == DisplayMode.DIRECT_TEXTURE_WORLD and pending_texture_rid.is_valid()

	var canvas_rect := _get_direct_texture_canvas_rect()
	if pending_mode == DisplayMode.DIRECT_TEXTURE_CANVAS:
		canvas_rect = _ensure_direct_texture_canvas_rect()
	if canvas_rect != null:
		canvas_rect.visible = pending_mode == DisplayMode.DIRECT_TEXTURE_CANVAS and pending_texture_rid.is_valid()

func _ensure_direct_texture_world_overlay() -> MeshInstance3D:
	var overlay := _get_direct_texture_world_overlay()
	if overlay != null:
		_configure_direct_texture_world_overlay(overlay)
		return overlay

	var tree := _get_scene_tree()
	if tree == null or tree.root == null:
		return null

	overlay = MeshInstance3D.new()
	overlay.name = DIRECT_TEXTURE_WORLD_OVERLAY_NAME
	overlay.visible = false
	tree.root.add_child(overlay)
	_configure_direct_texture_world_overlay(overlay)
	return overlay

func _configure_direct_texture_world_overlay(overlay: MeshInstance3D) -> void:
	if overlay == null:
		return

	var mesh := overlay.mesh as QuadMesh
	if mesh == null:
		mesh = QuadMesh.new()
	overlay.mesh = mesh
	mesh.flip_faces = true
	mesh.size = Vector2(2.0, 2.0)

	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	overlay.extra_cull_margin = 16384.0
	overlay.gi_mode = GeometryInstance3D.GI_MODE_DISABLED

	var material := overlay.get_active_material(0) as ShaderMaterial
	if material == null:
		material = ShaderMaterial.new()
	material.shader = DIRECT_TEXTURE_SHADER
	material.render_priority = 127
	material.set_shader_parameter("render_texture", _ensure_direct_texture_resource())
	overlay.set_surface_override_material(0, material)

func _ensure_direct_texture_resource() -> Texture2DRD:
	if _direct_texture_resource == null:
		_direct_texture_resource = Texture2DRD.new()
	return _direct_texture_resource

func _ensure_direct_texture_canvas_layer() -> CanvasLayer:
	var layer := _get_direct_texture_canvas_layer()
	if layer != null:
		return layer

	var tree := _get_scene_tree()
	if tree == null or tree.root == null:
		return null

	layer = CanvasLayer.new()
	layer.name = DIRECT_TEXTURE_CANVAS_LAYER_NAME
	tree.root.add_child(layer)
	return layer

func _ensure_direct_texture_canvas_rect() -> TextureRect:
	var rect := _get_direct_texture_canvas_rect()
	if rect != null:
		_configure_direct_texture_canvas_rect(rect)
		return rect

	var layer := _ensure_direct_texture_canvas_layer()
	if layer == null:
		return null

	rect = TextureRect.new()
	rect.name = DIRECT_TEXTURE_CANVAS_RECT_NAME
	layer.add_child(rect)
	_configure_direct_texture_canvas_rect(rect)
	return rect

func _configure_direct_texture_canvas_rect(rect: TextureRect) -> void:
	if rect == null:
		return
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.offset_left = 0.0
	rect.offset_top = 0.0
	rect.offset_right = 0.0
	rect.offset_bottom = 0.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.texture = _ensure_direct_texture_resource()

func _get_direct_texture_world_overlay() -> MeshInstance3D:
	var tree := _get_scene_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(DIRECT_TEXTURE_WORLD_OVERLAY_NAME) as MeshInstance3D

func _get_direct_texture_canvas_layer() -> CanvasLayer:
	var tree := _get_scene_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(DIRECT_TEXTURE_CANVAS_LAYER_NAME) as CanvasLayer

func _get_direct_texture_canvas_rect() -> TextureRect:
	var layer := _get_direct_texture_canvas_layer()
	if layer == null:
		return null
	return layer.get_node_or_null(DIRECT_TEXTURE_CANVAS_RECT_NAME) as TextureRect

func _free_direct_texture_overlay() -> void:
	if _direct_texture_resource != null:
		_direct_texture_resource.texture_rd_rid = RID()
		_direct_texture_resource = null

	var world_overlay := _get_direct_texture_world_overlay()
	if world_overlay != null:
		world_overlay.queue_free()

	var canvas_layer := _get_direct_texture_canvas_layer()
	if canvas_layer != null:
		canvas_layer.queue_free()

func _get_scene_tree() -> SceneTree:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		return main_loop
	return null


func _projection_readback_checkpoint_name(value: int) -> String:
	match value:
		0:
			return "full_package"
		1:
			return "disabled"
		2:
			return "histogram_header_only"
		3:
			return "projection_probe_only"
		4:
			return "sort_keys_sentinel_only"
		5:
			return "sort_values_sentinel_only"
		6:
			return "culled_splats_sentinel_only"
		7:
			return "scratch_projection_mirror_only"
		_:
			return "unknown(%d)" % value
