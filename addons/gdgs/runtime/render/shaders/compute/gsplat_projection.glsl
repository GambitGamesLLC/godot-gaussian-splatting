#[compute]
#version 460

#extension GL_KHR_shader_subgroup_arithmetic: enable

#define SH_C0 0.28209479177387814
#define SH_C1 0.4886025119029199

#define SH_C2_0 1.0925484305920792
#define SH_C2_1 1.0925484305920792
#define SH_C2_2 0.31539156525252005
#define SH_C2_3 1.0925484305920792
#define SH_C2_4 0.5462742152960396

#define SH_C3_0 0.5900435899266435
#define SH_C3_1 2.890611442640554
#define SH_C3_2 0.4570457994644658
#define SH_C3_3 0.3731763325901154
#define SH_C3_4 0.4570457994644658
#define SH_C3_5 1.445305721320277
#define SH_C3_6 0.5900435899266435

#define TILE_SIZE                (16)
#define NUM_BLOCKS_PER_WORKGROUP (32)
#define SORT_WORKGROUP_SIZE      (512)
#define SORT_PARTITION_DIVISION  (8)
#define SORT_PARTITION_SIZE      (SORT_PARTITION_DIVISION * SORT_WORKGROUP_SIZE)

#define DECODE_COVARIANCE(c) (mat3(c[0], c[1], c[2], c[1], c[3], c[4], c[2], c[4], c[5]))

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

struct Splat {
	vec3 position;
	float time;
	float covariance[6]; // Contains top triangle of symmetric matrix
	float opacity;
	float _pad;
	float sh_coefficients[16*3]; // Spherical harmonic coefficients in increasing order
};

struct RasterizeData {
	vec2 image_pos;
    vec2 pos_xy;
	vec3 conic;
	float pos_z;
	vec4 color;
	vec4 depth_data;
};

layout(std430, set = 0, binding = 0) restrict readonly buffer SplatsBuffer {
	Splat splat_buffer[];
};

layout(std430, set = 0, binding = 1) restrict writeonly buffer CulledBuffer {
	RasterizeData culled_buffer[];
};

layout (std430, set = 0, binding = 2) restrict buffer Histograms {
	uint sort_buffer_size;
    uint histogram[];
};

layout (std430, set = 0, binding = 3) restrict writeonly buffer SortKeysBuffer {
    uint sort_keys[];
};

layout (std430, set = 0, binding = 4) restrict writeonly buffer SortValuesBuffer {
    uint sort_values[];
};

layout (std430, set = 0, binding = 5) restrict writeonly buffer GridDimensionsBuffer {
	uint grid_dims[];
};

layout (std430, set = 0, binding = 6) restrict readonly buffer SplatInstanceIdsBuffer {
	uvec2 splat_instance_data[]; // x = unique instance id, y = which splat data to use
};

layout (std430, set = 0, binding = 7) restrict readonly buffer InstanceTransformsBuffer {
	mat4 instance_model_matrices[];
};

layout (std140, set = 0, binding = 8) restrict uniform Uniforms {
	vec3 camera_pos;
	float time;
	ivec2 dims; // Texture size
	int point_count;
	int debug_projection_mode;
};

layout(std430, set = 0, binding = 9) restrict buffer ProjectionProbe {
	uint projection_probe[];
};

layout(std430, set = 0, binding = 10) restrict buffer ScratchProbeBuffer {
	uint scratch_probe[];
};

layout(push_constant) restrict readonly uniform PushConstants {
	mat4 view_matrix;
	mat4 projection_matrix;
};

const uint PROJECTION_PROBE_INVOCATIONS = 0u;
const uint PROJECTION_PROBE_VISIBLE_SPLATS = 1u;
const uint PROJECTION_PROBE_DUPLICATED_SPLATS = 2u;
const uint PROJECTION_PROBE_EMITTED_SORT_ELEMENTS = 3u;
const uint PROJECTION_PROBE_MAX_SORT_END = 4u;
const uint PROJECTION_PROBE_MAX_TILE_ID = 5u;
const uint PROJECTION_PROBE_MAX_TILES_TOUCHED = 6u;
const uint PROJECTION_PROBE_ZERO_TILE_SPLATS = 7u;
const uint PROJECTION_PROBE_SORT_CAPACITY = 8u;
const uint PROJECTION_PROBE_TILE_CAPACITY = 9u;
const uint PROJECTION_PROBE_POINT_COUNT = 10u;
const uint PROJECTION_PROBE_GRID_WIDTH = 11u;
const uint PROJECTION_PROBE_GRID_HEIGHT = 12u;
const uint PROJECTION_PROBE_ERROR_FLAGS = 13u;
const uint PROJECTION_PROBE_GUARD_ABORT_COUNT = 14u;
const uint PROJECTION_PROBE_FIRST_FAILURE_STAGE = 15u;
const uint PROJECTION_PROBE_FIRST_FAILURE_ID = 16u;
const uint PROJECTION_PROBE_FIRST_FAILURE_VALUE0 = 17u;
const uint PROJECTION_PROBE_FIRST_FAILURE_VALUE1 = 18u;
const uint PROJECTION_PROBE_MAX_REQUESTED_SORT_END = 19u;
const uint PROJECTION_PROBE_MAX_REQUESTED_TILE_ID = 20u;
const uint PROJECTION_PROBE_NON_FINITE_FAILURE_COUNT = 21u;
const uint PROJECTION_PROBE_SORT_OVERFLOW_GUARD_COUNT = 22u;
const uint PROJECTION_PROBE_TILE_GUARD_COUNT = 23u;

const uint SCRATCH_PROBE_PROJECTION_INVOCATIONS = 4u;
const uint SCRATCH_PROBE_PROJECTION_VISIBLE_SPLATS = 5u;
const uint SCRATCH_PROBE_PROJECTION_STAGE_BITS = 6u;
const uint SCRATCH_PROBE_PROJECTION_MAX_REQUESTED_SORT_END = 7u;

const uint SCRATCH_PROJECTION_STAGE_ENTRY = 1u << 0;
const uint SCRATCH_PROJECTION_STAGE_VISIBLE = 1u << 1;
const uint SCRATCH_PROJECTION_STAGE_CULLED_WRITE = 1u << 2;
const uint SCRATCH_PROJECTION_STAGE_SORT_RESERVED = 1u << 3;
const uint SCRATCH_PROJECTION_STAGE_SORT_WRITTEN = 1u << 4;
const uint SCRATCH_PROJECTION_STAGE_FOOTPRINT_RETURN = 1u << 5;
const uint SCRATCH_PROJECTION_STAGE_INSTANCE_DATA_READ = 1u << 6;
const uint SCRATCH_PROJECTION_STAGE_MODEL_MATRIX_READ = 1u << 7;
const uint SCRATCH_PROJECTION_STAGE_SPLAT_PAYLOAD_READ = 1u << 8;
const uint SCRATCH_PROJECTION_STAGE_DUMMY_OUTPUT_WRITE = 1u << 9;
const uint SCRATCH_PROJECTION_STAGE_INSTANCE_DATA_BLOCK_ENTERED = 1u << 10;
const uint SCRATCH_PROJECTION_STAGE_NON_FOOTPRINT_IMMEDIATE_RETURN = 1u << 11;
const uint SCRATCH_PROJECTION_STAGE_POST_BARRIER_IMMEDIATE_RETURN = 1u << 12;

const int PROJECTION_MODE_NORMAL = 0;
const int PROJECTION_MODE_FOOTPRINT_ONLY = 1;
const int PROJECTION_MODE_NON_FOOTPRINT_IMMEDIATE_RETURN_ONLY = 2;
const int PROJECTION_MODE_POST_BARRIER_IMMEDIATE_RETURN_ONLY = 3;
const int PROJECTION_MODE_INSTANCE_DATA_BLOCK_ONLY = 4;
const int PROJECTION_MODE_INSTANCE_DATA_ONLY = 5;
const int PROJECTION_MODE_MODEL_MATRIX_ONLY = 6;
const int PROJECTION_MODE_SPLAT_PAYLOAD_ONLY = 7;
const int PROJECTION_MODE_DUMMY_OUTPUT_WRITE_ONLY = 8;

const uint PROJECTION_ERROR_FLAG_NON_FINITE = 1u << 0;
const uint PROJECTION_ERROR_FLAG_SORT_OVERFLOW = 1u << 1;
const uint PROJECTION_ERROR_FLAG_TILE_OOB = 1u << 2;
const uint PROJECTION_ERROR_FLAG_RECT_INVALID = 1u << 3;

const uint PROJECTION_FAILURE_NONE = 0u;
const uint PROJECTION_FAILURE_VIEW_POS_NON_FINITE = 1u;
const uint PROJECTION_FAILURE_CLIP_POS_NON_FINITE = 2u;
const uint PROJECTION_FAILURE_COVARIANCE_NON_FINITE = 3u;
const uint PROJECTION_FAILURE_DETERMINANT_NON_FINITE = 4u;
const uint PROJECTION_FAILURE_EIGENVALUES_NON_FINITE = 5u;
const uint PROJECTION_FAILURE_IMAGE_POS_NON_FINITE = 6u;
const uint PROJECTION_FAILURE_RADIUS_NON_FINITE = 7u;
const uint PROJECTION_FAILURE_RECT_INVALID = 8u;
const uint PROJECTION_FAILURE_SORT_OVERFLOW = 9u;
const uint PROJECTION_FAILURE_TILE_ID_OOB = 10u;
const uint PROJECTION_FAILURE_VIEW_DEPTH_NON_FINITE = 11u;
const uint PROJECTION_FAILURE_CONIC_NON_FINITE = 12u;
const uint PROJECTION_FAILURE_COLOR_NON_FINITE = 13u;

float ease_out_cubic(in float x) {
	float a = 1.0 - x;
	return 1.0 - a*a*a;
}

/** Calculates the color from given spherical harmonic coefficients and view direction. */
#define SH_COEFFICIENTS(x) (vec3(sh_coefficients[x*3], sh_coefficients[x*3+1], sh_coefficients[x*3+2]))
vec3 get_color(in vec3 view_dir, in float sh_coefficients[16*3]) {
	const float x = view_dir.x,
			    y = view_dir.y,
				z = view_dir.z;
	const float xx = x*x, yy = y*y, zz = z*z,
			    xy = x*y, yz = y*z, xz = x*z;
	return max(vec3(0), 0.5
		// Degree 0
		+  SH_COEFFICIENTS(0) *   SH_C0
		// Degree 1
		-  SH_COEFFICIENTS(1) *   SH_C1 * y
		+  SH_COEFFICIENTS(2) *   SH_C1 * z
		-  SH_COEFFICIENTS(3) *   SH_C1 * x
		// Degree 2
		+  SH_COEFFICIENTS(4) * SH_C2_0 * xy
		-  SH_COEFFICIENTS(5) * SH_C2_1 * yz
		+  SH_COEFFICIENTS(6) * SH_C2_2 * (2.0*zz - xx - yy)
		-  SH_COEFFICIENTS(7) * SH_C2_3 * xz
		+  SH_COEFFICIENTS(8) * SH_C2_4 * (xx - yy)
		// Degree 3
		-  SH_COEFFICIENTS(9) * SH_C3_0 * y * (3.0*xx - yy)
		+ SH_COEFFICIENTS(10) * SH_C3_1 * x * yz
		- SH_COEFFICIENTS(11) * SH_C3_2 * y * (4.0*zz - xx - yy)
		+ SH_COEFFICIENTS(12) * SH_C3_3 * z * (2.0*zz - 3.0*xx - 3.0*yy)
		- SH_COEFFICIENTS(13) * SH_C3_4 * x * (4.0*zz - xx - yy)
		+ SH_COEFFICIENTS(14) * SH_C3_5 * z * (xx - yy)
		- SH_COEFFICIENTS(15) * SH_C3_6 * x * (xx - 3.0*yy));
}

/** Computes a 2D projected covariance matrix from the given Gaussian parameters. */
vec3 project_covariance(in mat3 covariance_3d, in float scale_modifier, in vec3 mean, in ivec2 dims) {
	const mat3 cov_3d = covariance_3d * scale_modifier*scale_modifier;
	// Godot camera space looks down -Z, so use positive forward depth here.
	vec2 tan_fov_inv = vec2(projection_matrix[0][0], projection_matrix[1][1]);
	vec2 focal = vec2(dims - 1) * 0.5 * tan_fov_inv;
	// RenderData projections can encode a Y flip in projection_matrix[1][1].
	// Keep that sign in the focal scale, but use absolute FOV extents for clamping.
	vec2 tan_fov = 1.0 / abs(tan_fov_inv);
	float depth_inv = -1.0 / mean.z;
	focal *= depth_inv;

	mean.xy = clamp(mean.xy * depth_inv, -tan_fov * 1.3, tan_fov * 1.3);
	mat3 view_linear = mat3(view_matrix);
	mat3 jacobian = mat3(
		focal.x, 0, 0,
		0, focal.y, 0,
		focal.x * mean.x, focal.y * mean.y, 0);
	mat3 screen_transform = jacobian * view_linear;
	mat3 cov_2d = screen_transform * cov_3d * transpose(screen_transform);
	return vec3(cov_2d[0][0] + 0.3, cov_2d[0][1], cov_2d[1][1] + 0.3);
}

uvec4 get_rect(in vec2 image_pos, in float radius, in uvec2 grid_size) {
	return ivec4(
		clamp(     (image_pos - radius) / TILE_SIZE,  vec2(0), grid_size),
		clamp(ceil((image_pos + radius) / TILE_SIZE), vec2(0), grid_size));
}


bool any_non_finite(in vec2 value) {
	return any(isnan(value)) || any(isinf(value));
}

bool any_non_finite(in vec3 value) {
	return any(isnan(value)) || any(isinf(value));
}

bool any_non_finite(in vec4 value) {
	return any(isnan(value)) || any(isinf(value));
}

void record_projection_failure(in uint id, in uint stage, in uint flag, in uint value0, in uint value1) {
	atomicOr(projection_probe[PROJECTION_PROBE_ERROR_FLAGS], flag);
	atomicAdd(projection_probe[PROJECTION_PROBE_GUARD_ABORT_COUNT], 1u);
	if (flag == PROJECTION_ERROR_FLAG_NON_FINITE) {
		atomicAdd(projection_probe[PROJECTION_PROBE_NON_FINITE_FAILURE_COUNT], 1u);
	}
	if (flag == PROJECTION_ERROR_FLAG_SORT_OVERFLOW) {
		atomicAdd(projection_probe[PROJECTION_PROBE_SORT_OVERFLOW_GUARD_COUNT], 1u);
	}
	if (flag == PROJECTION_ERROR_FLAG_TILE_OOB || flag == PROJECTION_ERROR_FLAG_RECT_INVALID) {
		atomicAdd(projection_probe[PROJECTION_PROBE_TILE_GUARD_COUNT], 1u);
	}
	if (atomicCompSwap(projection_probe[PROJECTION_PROBE_FIRST_FAILURE_STAGE], PROJECTION_FAILURE_NONE, stage) == PROJECTION_FAILURE_NONE) {
		projection_probe[PROJECTION_PROBE_FIRST_FAILURE_ID] = id;
		projection_probe[PROJECTION_PROBE_FIRST_FAILURE_VALUE0] = value0;
		projection_probe[PROJECTION_PROBE_FIRST_FAILURE_VALUE1] = value1;
	}
}

bool reserve_sort_range(in uint num_tiles_touched, out uint sort_buffer_offset, out uint requested_sort_end) {
	uint sort_capacity = projection_probe[PROJECTION_PROBE_SORT_CAPACITY];
	for (;;) {
		uint current_size = sort_buffer_size;
		requested_sort_end = current_size + num_tiles_touched;
		atomicMax(projection_probe[PROJECTION_PROBE_MAX_REQUESTED_SORT_END], requested_sort_end);
		if (requested_sort_end < current_size || requested_sort_end > sort_capacity) {
			sort_buffer_offset = current_size;
			return false;
		}
		uint previous_size = atomicCompSwap(sort_buffer_size, current_size, requested_sort_end);
		if (previous_size == current_size) {
			sort_buffer_offset = current_size;
			return true;
		}
	}
}

void main() {
	const uint id = gl_GlobalInvocationID.x;
	const uvec2 grid_size = (dims + TILE_SIZE - 1) / TILE_SIZE;

	if (id >= uint(point_count)) return;
	atomicAdd(projection_probe[PROJECTION_PROBE_INVOCATIONS], 1u);
	atomicAdd(scratch_probe[SCRATCH_PROBE_PROJECTION_INVOCATIONS], 1u);
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_ENTRY);
	if (debug_projection_mode == PROJECTION_MODE_FOOTPRINT_ONLY) {
		atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_FOOTPRINT_RETURN);
		return;
	}
	if (debug_projection_mode == PROJECTION_MODE_NON_FOOTPRINT_IMMEDIATE_RETURN_ONLY) {
		atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_NON_FOOTPRINT_IMMEDIATE_RETURN);
		return;
	}

	barrier();
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_POST_BARRIER_IMMEDIATE_RETURN);
	if (debug_projection_mode == PROJECTION_MODE_POST_BARRIER_IMMEDIATE_RETURN_ONLY) {
		return;
	}
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_INSTANCE_DATA_BLOCK_ENTERED);
	if (debug_projection_mode == PROJECTION_MODE_INSTANCE_DATA_BLOCK_ONLY) {
		return;
	}
	uvec2 instance_data = splat_instance_data[id];
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_INSTANCE_DATA_READ);
	if (debug_projection_mode == PROJECTION_MODE_INSTANCE_DATA_ONLY) {
		return;
	}
	uint instance_id = instance_data.x;
	uint unique_splat_index = instance_data.y;

	mat4 model_matrix = instance_model_matrices[instance_id];
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_MODEL_MATRIX_READ);
	if (debug_projection_mode == PROJECTION_MODE_MODEL_MATRIX_ONLY) {
		return;
	}

	const Splat splat = splat_buffer[unique_splat_index];
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_SPLAT_PAYLOAD_READ);
	if (debug_projection_mode == PROJECTION_MODE_SPLAT_PAYLOAD_ONLY) {
		return;
	}

	if (debug_projection_mode == PROJECTION_MODE_DUMMY_OUTPUT_WRITE_ONLY) {
		RasterizeData dummy_data;
		dummy_data.image_pos = vec2(0.0);
		dummy_data.pos_xy = vec2(0.0);
		dummy_data.conic = vec3(0.0);
		dummy_data.pos_z = 0.0;
		dummy_data.color = vec4(0.0);
		dummy_data.depth_data = vec4(0.0);
		culled_buffer[id] = dummy_data;
		atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_DUMMY_OUTPUT_WRITE | SCRATCH_PROJECTION_STAGE_CULLED_WRITE);
		return;
	}

	// --- VISIBILITY ---
	float is_visible = model_matrix[0][3];
	if (is_visible < 0.5) return;
	model_matrix[0][3] = 0.0;

	// --- FRUSTUM CULLING ---
	mat3 object_linear = mat3(model_matrix);
	mat3 world_covariance = object_linear * DECODE_COVARIANCE(splat.covariance) * transpose(object_linear);
	vec4 world_pos = model_matrix * vec4(splat.position, 1.0);
	vec4 view_pos = view_matrix * world_pos;
	if (any_non_finite(view_pos.xyz)) {
		record_projection_failure(id, PROJECTION_FAILURE_VIEW_POS_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(view_pos.z), 0u);
		return;
	}
	vec4 clip_pos = projection_matrix * view_pos;
	if (any_non_finite(clip_pos)) {
		record_projection_failure(id, PROJECTION_FAILURE_CLIP_POS_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(clip_pos.z), floatBitsToUint(clip_pos.w));
		return;
	}
	vec2 view_bounds = clip_pos.ww*1.2;
	if (any(lessThan(clip_pos.xyz, vec3(-view_bounds, 0.0))) || any(greaterThan(clip_pos.xyz, vec3(view_bounds, clip_pos.w)))) {
		return;
	}

	// --- GAUSSIAN PROJECTION ---
	float splat_time = time - splat.time;
	float time_factor = ease_out_cubic(clamp(splat_time, 0, 1));
	float time_factor_late = ease_out_cubic(clamp(splat_time - 0.35, 0, 1));

	float splat_opacity = splat.opacity * time_factor_late*time_factor_late;
	float splat_scale = mix(2.0, 1.0, time_factor_late);

	const vec3 covariance = project_covariance(world_covariance, splat_scale, view_pos.xyz, dims);
	if (any_non_finite(covariance)) {
		record_projection_failure(id, PROJECTION_FAILURE_COVARIANCE_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(covariance.x), floatBitsToUint(covariance.z));
		return;
	}
	float det = covariance.x*covariance.z - covariance.y*covariance.y;
	if (isnan(det) || isinf(det)) {
		record_projection_failure(id, PROJECTION_FAILURE_DETERMINANT_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(det), 0u);
		return;
	}
	if (det == 0.0) return;

	float mid = 0.5 * (covariance.x + covariance.z);
	vec2 eigenvalues = mid + vec2(1, -1)*sqrt(max(0.1, mid*mid - det));
	if (any_non_finite(eigenvalues)) {
		record_projection_failure(id, PROJECTION_FAILURE_EIGENVALUES_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(eigenvalues.x), floatBitsToUint(eigenvalues.y));
		return;
	}
	if (any(lessThan(eigenvalues, vec2(0)))) return;

	vec3 ndc_pos = clip_pos.xyz / clip_pos.w;
	vec2 image_pos = ((ndc_pos.xy + 1.0)*0.5 - vec2(1,0.75)*(1.0 - time_factor)) * (dims - 1);
	if (any_non_finite(image_pos)) {
		record_projection_failure(id, PROJECTION_FAILURE_IMAGE_POS_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(image_pos.x), floatBitsToUint(image_pos.y));
		return;
	}

	// We bias the radius (w/ base=2.5x standard deviation) such that low opacity splats cover
	// fewer screen tiles. This has the effect of making the image *slightly* brighter while
	// minimizing perceptible tile artifacts.
	float radius = pow(splat_opacity, 0.2) * 2.5*sqrt(max(eigenvalues.x, eigenvalues.y));
	if (isnan(radius) || isinf(radius)) {
		record_projection_failure(id, PROJECTION_FAILURE_RADIUS_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(radius), 0u);
		return;
	}
	uvec4 rect_bounds = get_rect(image_pos, radius, grid_size);
	if (rect_bounds.x > rect_bounds.z || rect_bounds.y > rect_bounds.w) {
		record_projection_failure(id, PROJECTION_FAILURE_RECT_INVALID, PROJECTION_ERROR_FLAG_RECT_INVALID, rect_bounds.x, rect_bounds.z);
		return;
	}
	uint num_tiles_touched = (rect_bounds.z - rect_bounds.x)*(rect_bounds.w - rect_bounds.y);
	atomicAdd(projection_probe[PROJECTION_PROBE_VISIBLE_SPLATS], 1u);
	atomicAdd(scratch_probe[SCRATCH_PROBE_PROJECTION_VISIBLE_SPLATS], 1u);
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_VISIBLE);
	atomicMax(projection_probe[PROJECTION_PROBE_MAX_TILES_TOUCHED], num_tiles_touched);

	if (num_tiles_touched == 0 /*|| num_tiles_touched > grid_size.x*grid_size.y/3*/) {
		atomicAdd(projection_probe[PROJECTION_PROBE_ZERO_TILE_SPLATS], 1u);
		return;
	}

	uint tile_capacity = projection_probe[PROJECTION_PROBE_TILE_CAPACITY];
	uint rect_max_tile_id = (rect_bounds.w - 1u) * grid_size.x + (rect_bounds.z - 1u);
	atomicMax(projection_probe[PROJECTION_PROBE_MAX_REQUESTED_TILE_ID], rect_max_tile_id);
	if (rect_max_tile_id >= tile_capacity) {
		record_projection_failure(id, PROJECTION_FAILURE_TILE_ID_OOB, PROJECTION_ERROR_FLAG_TILE_OOB, rect_max_tile_id, tile_capacity);
		return;
	}

	uint sort_buffer_offset = 0u;
	uint requested_sort_end = 0u;
	if (!reserve_sort_range(num_tiles_touched, sort_buffer_offset, requested_sort_end)) {
		record_projection_failure(id, PROJECTION_FAILURE_SORT_OVERFLOW, PROJECTION_ERROR_FLAG_SORT_OVERFLOW, sort_buffer_offset, requested_sort_end);
		return;
	}
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_SORT_RESERVED);
	atomicMax(scratch_probe[SCRATCH_PROBE_PROJECTION_MAX_REQUESTED_SORT_END], requested_sort_end);
	atomicAdd(projection_probe[PROJECTION_PROBE_DUPLICATED_SPLATS], 1u);
	atomicAdd(projection_probe[PROJECTION_PROBE_EMITTED_SORT_ELEMENTS], num_tiles_touched);
	atomicMax(projection_probe[PROJECTION_PROBE_MAX_SORT_END], requested_sort_end);
	vec3 view_dir = normalize(world_pos.xyz - camera_pos);
	vec3 conic = vec3(covariance.z, -covariance.y, covariance.x) / det;
	if (any_non_finite(conic)) {
		record_projection_failure(id, PROJECTION_FAILURE_CONIC_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(conic.x), floatBitsToUint(conic.z));
		return;
	}
	vec4 color = vec4(get_color(view_dir, splat.sh_coefficients), splat_opacity);
	if (any_non_finite(color)) {
		record_projection_failure(id, PROJECTION_FAILURE_COLOR_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(color.x), floatBitsToUint(color.w));
		return;
	}

	RasterizeData data;
	data.image_pos = image_pos;
	data.conic = conic; // Inverse 2D covariance
	data.color = color;
	data.pos_xy = world_pos.xy;
	data.pos_z = world_pos.z;
	data.depth_data = vec4(-view_pos.z, 0.0, 0.0, 0.0);
	culled_buffer[id] = data;
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_CULLED_WRITE);
	barrier();

	// --- GAUSSIAN DUPLICATION ---
	// Use clip-space w as a monotonic distance proxy so ordering stays front-to-back
	// even when the renderer uses reverse-z projection.
	float view_depth = max(0.0, clip_pos.w);
	if (isnan(view_depth) || isinf(view_depth)) {
		record_projection_failure(id, PROJECTION_FAILURE_VIEW_DEPTH_NON_FINITE, PROJECTION_ERROR_FLAG_NON_FINITE, floatBitsToUint(view_depth), 0u);
		return;
	}
	float depth01 = view_depth / (1.0 + view_depth);
	uint depth = uint(depth01 * 65535.0) & 0xFFFF;
	for (uint y = rect_bounds.y; y < rect_bounds.w; ++y)
	for (uint x = rect_bounds.x; x < rect_bounds.z; ++x) {
		uint tile_id = y*grid_size.x + x;
		if (tile_id >= tile_capacity) {
			record_projection_failure(id, PROJECTION_FAILURE_TILE_ID_OOB, PROJECTION_ERROR_FLAG_TILE_OOB, tile_id, tile_capacity);
			return;
		}
		atomicMax(projection_probe[PROJECTION_PROBE_MAX_TILE_ID], tile_id);
		uint key = (tile_id << 16) | depth;
		sort_keys[sort_buffer_offset] = key;
		sort_values[sort_buffer_offset] = id;
		sort_buffer_offset++;
	}
	atomicOr(scratch_probe[SCRATCH_PROBE_PROJECTION_STAGE_BITS], SCRATCH_PROJECTION_STAGE_SORT_WRITTEN);
}
