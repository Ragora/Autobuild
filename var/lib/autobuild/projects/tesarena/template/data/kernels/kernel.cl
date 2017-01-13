// kernel.cl for OpenTESArena.

// Here is an overview of the ray tracer design. It may change once in a while, but 
// the overall objective should stay the same.
// 1) Primary ray intersections kernel
// 2) Ray tracing kernel (material colors, shadows, reflections)
// 3) (Optional) Post-processing kernel
// 4) Float to int conversion kernel

// OpenCL programming hints:
// - Spread the work out over multiple smaller kernels.
// - Consider using "vload" and "vstore" with vector types (float4).
// - Minimize nesting of if-else statements.
// - Try "fma(...)" and "mad(...)" functions for faster arithmetic.
// - Individual operations could be faster than vector operations.

// Assume OpenCL aligns structs to 8 byte boundaries.

/* ------------------------- */
/* Host settings */
/* -> These settings are added to this file at compile time from the host. */
/* ------------------------- */

#ifndef RENDER_WIDTH
#error "Missing RENDER_WIDTH definition."
#endif

#ifndef RENDER_HEIGHT
#error "Missing RENDER_HEIGHT definition."
#endif

// These world values determine the dimensions of the three reference grids
// (Voxel, Sprite, and Light). A more advanced renderer would use chunks 
// instead, like Minecraft does.
#ifndef WORLD_WIDTH
#error "Missing WORLD_WIDTH definition."
#endif

#ifndef WORLD_HEIGHT
#error "Missing WORLD_HEIGHT definition."
#endif

#ifndef WORLD_DEPTH
#error "Missing WORLD_DEPTH definition."
#endif

/* ------------------------- */
/* Constant settings */
/* ------------------------- */

#define FALSE 0
#define TRUE (!FALSE)

#define EPSILON 1.0e-6f

#define FOG_DIST 35.0f // This should be dynamic eventually.
#define BETTER_FOG TRUE

#define RENDER_WIDTH_REAL ((float)RENDER_WIDTH)
#define RENDER_HEIGHT_REAL ((float)RENDER_HEIGHT)
#define RENDER_WIDTH_RECIP (1.0f / RENDER_WIDTH_REAL)
#define RENDER_HEIGHT_RECIP (1.0f / RENDER_HEIGHT_REAL)
#define ASPECT_RATIO (RENDER_WIDTH_REAL * RENDER_HEIGHT_RECIP)

#define GLOBAL_UP ((float3)(0.0f, 1.0f, 0.0f))

#define INTERSECTION_T_MAX MAXFLOAT

#define RAY_INITIAL_DEPTH 0

/* ------------------------- */
/* Camera struct */
/* ------------------------- */

// Zoom allows for a variable FOV without recompiling the kernel. 
// Aspect ratio is compile-time constant, though.
// Assume all camera axes are normalized.

typedef struct
{
	float3 eye, forward, right, up;
	float zoom;
} Camera;

/* ------------------------- */
/* Intersection struct */
/* ------------------------- */

// Point is the hit point on the shape. Normal is the normal at the hit point.
// T is for the depth buffer. U and V are texture coordinates.
// RectIndex is the number of rectangles to skip in the rectangles array.

typedef struct
{
	float3 point, normal;
	float t, u, v;
	int rectIndex;
} Intersection;

/* ------------------------- */
/* Light struct */
/* ------------------------- */

// All lights will use the same drop-off function for now.

// Time complexity of ray tracing is linear in the number of nearby lights, 
// so don't go overboard!

typedef struct 
{
	float3 color, point;
} Light;

/* ------------------------- */
/* LightReference struct */
/* ------------------------- */

// It is unlikely that more than five or six lights will touch a voxel at a time.

typedef struct
{
	int offset;
	int count;
} LightReference;

/* ------------------------- */
/* Ray struct */
/* ------------------------- */

typedef struct
{
	float3 point, direction;
	int depth;
} Ray;

/* ------------------------- */
/* SpriteReference struct */
/* ------------------------- */

// No need for a "Sprite" struct; it's just a rectangle.

// The offset and count are in units of rectangles.

// It is unlikely that more than a dozen sprites will occupy a voxel at a time.

typedef struct
{
	int offset;
	int count;
} SpriteReference;

/* ------------------------- */
/* TextureReference struct */
/* ------------------------- */

// No need for a "Texture" struct; it's just float4's.

// The offset is in units of float4's to skip.

// Textures may have several thousands of pixels, including ones from the various 
// layers (normal, specular, ...) eventually.

typedef struct
{
	int offset;
	short width, height;
} TextureReference;

/* ------------------------- */
/* Rectangle struct */
/* ------------------------- */

// It's likely that there will eventually be layers of textures, like normal maps
// and things. However, they could still all use the same ID and just have the
// texture's float4's get packed together. The texture function would jump to get
// to the beginnings of the other pixels.

typedef struct
{
	float3 p1, p2, p3, p1p2, p2p3, normal;
	TextureReference textureRef;
} Rectangle;

/* ------------------------- */
/* VoxelReference struct */
/* ------------------------- */

// No need for a "Voxel" struct; it's just rectangles.

// The offset is in units of rectangles to skip.

// It is unlikely that a voxel will have more than six rectangles.

typedef struct
{
	int offset;
	int count;
} VoxelReference;

/* ------------------------- */
/* Vector functions */
/* ------------------------- */

int float3ToRGB(float3 color)
{
	return (int) 
		(((uchar)(color.x * 255.0f) << 16) |
		 ((uchar)(color.y * 255.0f) << 8) |
		 ((uchar)(color.z * 255.0f)));
}

/* ------------------------- */
/* Camera functions */
/* ------------------------- */

// Generate a direction through the view frustum given x and y screen percents.
float3 cameraImageDirection(const __global Camera *camera, float xx, float yy)
{
	float3 forwardComponent = camera->forward * camera->zoom;
	float3 rightComponent = camera->right * (ASPECT_RATIO * ((2.0f * xx) - 1.0f));
	float3 upComponent = camera->up * ((2.0f * yy) - 1.0f);
	return fast_normalize(forwardComponent + rightComponent - upComponent);
}

/* ------------------------- */
/* Rectangle functions */
/* ------------------------- */

Intersection rectangleHit(const Rectangle *rect, const Ray *ray)
{
	// Ray-rectangle intersection algorithm.
	Intersection intersection;
	intersection.t = INTERSECTION_T_MAX;

	const float normalDirDot = dot(rect->normal, ray->direction);

	if (fabs(normalDirDot) < EPSILON)
	{
		return intersection;
	}

	const float t = -dot(rect->normal, ray->point - rect->p1) / normalDirDot;
	const float3 p = ray->point + (ray->direction * t);

	const float3 diff = p - rect->p1;

	const float u = dot(diff, rect->p2p3);
	const float v = dot(diff, rect->p1p2);

	// If the texture coordinates are valid and the distance is positive, 
	// then the intersection is valid.
	const float uDot = dot(rect->p2p3, rect->p2p3);
	const float vDot = dot(rect->p1p2, rect->p1p2);
	if ((u >= 0.0f) && (u <= uDot) && (v >= 0.0f) && (v <= vDot) && (t > 0.0f))
	{
		// There was a hit. Shape index is set by the calling function.
		intersection.t = t;
		intersection.u = u;
		intersection.v = v;
		intersection.point = p;
		intersection.normal = (normalDirDot < 0.0f) ? rect->normal : -rect->normal;
	}

	return intersection;
}

/* ------------------------- */
/* Shading functions */
/* ------------------------- */

// For dynamically changing fog distance, this function would also take "maxDistance".
float getFogPercent(float distance)
{
#if BETTER_FOG
	float fogDensity = native_sqrt(-native_log(EPSILON) / (FOG_DIST * FOG_DIST));
	return 1.0f - (1.0f / native_exp((distance * distance) * (fogDensity * fogDensity)));
#else
	return clamp(distance / FOG_DIST, 0.0f, 1.0f);
#endif
}

float4 getTextureColor(const Rectangle *rect, float u, float v, 
	const __global float4 *textures)
{
	/* Texture mapping function for rectangles. */	
	const TextureReference *textureRef = &rect->textureRef;
	const int width = textureRef->width;
	const int height = textureRef->height;
	const int offset = textureRef->offset;

	const int x = (int)(u * (float)width);
	const int y = (int)(v * (float)height);

	return textures[offset + x + (y * width)];
}

/* ------------------------- */
/* 3D grid functions */
/* ------------------------- */

// Returns true if a cell coordinate is contained within the world grid.
bool gridContains(int x, int y, int z)
{
	return (x >= 0) && (y >= 0) && (z >= 0) && 
		(x < WORLD_WIDTH) && (y < WORLD_HEIGHT) && (z < WORLD_DEPTH);
}

// 3D digital differential analysis algorithm.
// - This function takes a ray and walks through a voxel grid. It stops once the max
//   distance has been reached or if an opaque object is hit.
void voxelDDA(const Ray *ray,
	Intersection *intersection,
	const __global VoxelReference *voxelRefs,
	const __global SpriteReference *spriteRefs,
	const __global Rectangle *rects,
	const __global float4 *textures)
{
	// Just voxelRefs and rectangles for now.

	// Set up the 3D-DDA cell and step direction variables.
	const float3 position = ray->point;
	const float3 direction = ray->direction;
	const int3 startCell = (int3)(
		(int)floor(position.x),
		(int)floor(position.y),
		(int)floor(position.z));
	const char3 nonNegativeDir = (char3)(
		direction.x >= 0.0f,
		direction.y >= 0.0f,
		direction.z >= 0.0f);
	const int3 step = (int3)(
		nonNegativeDir.x ? 1 : -1,
		nonNegativeDir.y ? 1 : -1,
		nonNegativeDir.z ? 1 : -1);

	// Epsilon needs to be just right for there to be no artifacts. 
	// Hopefully all graphics cards running this have 32-bit floats.
	// Maybe don't use "fast" functions for extra precision?
	const float3 invDirection = (float3)(
		1.0f / ((fabs(direction.x) < EPSILON) ? (EPSILON * (float)step.x) : direction.x),
		1.0f / ((fabs(direction.y) < EPSILON) ? (EPSILON * (float)step.y) : direction.y),
		1.0f / ((fabs(direction.z) < EPSILON) ? (EPSILON * (float)step.z) : direction.z));
	const float3 deltaDist = fast_normalize((float3)(
		(float)step.x * invDirection.x,
		(float)step.y * invDirection.y,
		(float)step.z * invDirection.z));
	
	int3 cell = startCell;
	const float3 sideDist = deltaDist * (float3)(
		nonNegativeDir.x ? ((float)cell.x + 1.0f - position.x) : 
			(position.x - (float)cell.x),
		nonNegativeDir.y ? ((float)cell.y + 1.0f - position.y) : 
			(position.y - (float)cell.y),
		nonNegativeDir.z ? ((float)cell.z + 1.0f - position.z) : 
			(position.z - (float)cell.z));

	// Walk through the voxel grid while the current cell is contained in the world.
	while (gridContains(cell.x, cell.y, cell.z))
	{
		const int gridIndex = cell.x + (cell.y * WORLD_WIDTH) + 
			(cell.z * WORLD_WIDTH * WORLD_HEIGHT);

		// Get the current voxel data.
		const VoxelReference voxelRef = voxelRefs[gridIndex];
		
		// Try intersecting each shape pointed to by the voxel reference.
		for (int i = 0; i < voxelRef.count; ++i)
		{
			const int rectIndex = voxelRef.offset + i;
			const Rectangle rect = rects[rectIndex];
			Intersection currentTry = rectangleHit(&rect, ray);
			
			const float u = currentTry.u;
			const float v = currentTry.v;
			const float4 materialColor = getTextureColor(&rect, u, v, textures);

			const bool hitPointIsTransparent = materialColor.w == 0.0f;

			// Overwrite the nearest rectangle if the current try was closer.
			if ((currentTry.t < intersection->t) && !hitPointIsTransparent)
			{
				currentTry.rectIndex = rectIndex;
				*intersection = currentTry;
			}
		}

		// Check how far the stepping has gone from the start.
		const float3 diff = (float3)((float)cell.x, (float)cell.y, (float)cell.z) - position;
		const float dist = fast_length(diff);

		// If a shape has been hit, or if the stepping has gone too far, then stop.
		if ((intersection->t < INTERSECTION_T_MAX) || (dist > FOG_DIST))
		{
			break;
		}

		// Decide which voxel to step towards next.
		if ((sideDist.x < sideDist.y) && (sideDist.x < sideDist.z))
		{
			sideDist.x += deltaDist.x;
			cell.x += step.x;
		}
		else if (sideDist.y < sideDist.z)
		{
			sideDist.y += deltaDist.y;
			cell.y += step.y;
		}
		else
		{
			sideDist.z += deltaDist.z;
			cell.z += step.z;
		}
	}
}

/* ------------------------- */
/* Kernel functions */
/* ------------------------- */

// The intersect kernel populates the primary rays' depth, normal, view, 
// hit point, UV, and rectangle index buffers.
__kernel void intersect(
	const __global Camera *camera,
	const __global VoxelReference *voxelRefs,
	const __global SpriteReference *spriteRefs,
	const __global Rectangle *rects,
	const __global float4 *textures,
	__global float *depthBuffer, 
	__global float3 *normalBuffer,
	__global float3 *viewBuffer, 
	__global float3 *pointBuffer, 
	__global float2 *uvBuffer,
	__global int *rectangleIndexBuffer)
{
	// Coordinates of "this" pixel relative to the top left.
	const int x = get_global_id(0);
	const int y = get_global_id(1);

	// Get 0->1 percentages across the screen.
	const float xx = (float)x * RENDER_WIDTH_RECIP;
	const float yy = (float)y * RENDER_HEIGHT_RECIP;

	Ray ray;
	ray.point = camera->eye;
	ray.direction = cameraImageDirection(camera, xx, yy);
	ray.depth = RAY_INITIAL_DEPTH;

	Intersection intersection;
	intersection.t = INTERSECTION_T_MAX;

	// Get the nearest geometry hit by the ray.
	voxelDDA(&ray, &intersection, voxelRefs, spriteRefs, rects, textures);
	
	// Put the intersection data in the global buffers.
	const int index = x + (y * RENDER_WIDTH);
	depthBuffer[index] = intersection.t;
	normalBuffer[index] = intersection.normal;
	viewBuffer[index] = -ray.direction;
	pointBuffer[index] = intersection.point;
	uvBuffer[index] = (float2)(intersection.u, intersection.v);
	rectangleIndexBuffer[index] = intersection.rectIndex;
}

// Fill the color buffer with the results of rays traced in the world.
__kernel void rayTrace(
	const __global VoxelReference *voxelRefs,
	const __global SpriteReference *spriteRefs,
	const __global LightReference *lightRefs,
	const __global Rectangle *rects,
	const __global Light *lights,
	const __global float4 *textures,
	const __global float *gameTime,
	const __global float *depthBuffer, 
	const __global float3 *normalBuffer, 
	const __global float3 *viewBuffer,
	const __global float3 *pointBuffer, 
	const __global float2 *uvBuffer,
	const __global int *rectangleIndexBuffer,
	__global float3 *colorBuffer)
{
	const int x = get_global_id(0);
	const int y = get_global_id(1);
	const int index = x + (y * RENDER_WIDTH);

	// The world time is based on game time. This value could certainly use some 
	// refinement so the sun position actually matches the game time. It would
	// need to know how many seconds a game day is (30 minutes?).
	const float worldTime = (*gameTime) * 0.020f;

	// Sky colors to interpolate between.
	const float3 horizonColor = (float3)(0.90f, 0.90f, 0.95f);
	const float3 zenithColor = horizonColor * 0.75f;

	// Values regarding how the sun is calculated.
	const float sunSize = 0.99925f;
	const float sunGlowSize = sunSize - 0.0065f;
	const float3 sunColor = (float3)(1.0f, 0.925f, 0.80f);
	const float3 sunDirection = fast_normalize((float3)(
		sin(worldTime) * 0.20f, sin(worldTime), cos(worldTime)));

	// Least amount of ambient light allowed (i.e., at night).
	const float minAmbient = 0.20f;
		
	// Ambient light value, based on the sun's height.
	const float ambient = clamp(sunDirection.y * 1.20f, minAmbient, 1.0f);
	
	// Get view elevation and background color.
	const float3 viewVector = viewBuffer[index];
	const float elevationPercent = clamp(-viewVector.y, 0.0f, 1.0f);
	const float3 backgroundColor = ((horizonColor * (1.0f - elevationPercent)) + 
		(zenithColor * elevationPercent)) * ambient;
	
	// Get the depth for this pixel.
	const float t = depthBuffer[index];

	// The color of the pixel. Its value is calculated soon.
	float3 color = (float3)0.0f;

	// See if a shape was hit.
	if (t < INTERSECTION_T_MAX)
	{
		// A shape was hit. Calculate the shaded color.
		const Rectangle rect = rects[rectangleIndexBuffer[index]];

		// Get the texture color.
		const float2 uv = uvBuffer[index];
		const float3 textureColor = getTextureColor(&rect, uv.x, uv.y, textures).xyz;

		// Reduce the texture color by the percent of ambient light.
		color = textureColor * ambient;

		// Get the intersection point and normal.
		const float3 point = pointBuffer[index];
		const float3 normal = normalBuffer[index];
		
		Ray sunRay;
		sunRay.point = point + (normal * EPSILON);
		sunRay.direction = sunDirection;
		sunRay.depth = RAY_INITIAL_DEPTH;

		// See if the intersection point is lit by the sun.
		Intersection sunTry;
		sunTry.t = INTERSECTION_T_MAX;
		voxelDDA(&sunRay, &sunTry, voxelRefs, spriteRefs, rects, textures);

		if (sunTry.t == INTERSECTION_T_MAX)
		{
			// The point is lit. Add some sunlight depending on the angle.
			const float lnDot = dot(sunDirection, normal);
			color += (textureColor * sunColor) * lnDot;
		}

		// Interpolate with fog based on depth.
		const float fogPercent = getFogPercent(t);
		color += (backgroundColor - color) * fogPercent;
	}
	else
	{
		// No shape was hit. See if the ray is close to the sun.
		float raySunDot = dot(-viewVector, sunDirection);
		if (raySunDot < sunGlowSize)
		{
			// The ray is not near the sun.
			color = backgroundColor;
		}
		else if (raySunDot < sunSize)
		{
			// The ray is near the sun. Soften the sun glow with a pow function.
			const float sunPercent = pow((raySunDot - sunGlowSize) / 
				(sunSize - sunGlowSize), 6.0f);
			color = (backgroundColor * (1.0f - sunPercent)) + (sunColor * sunPercent);
		}
		else
		{
			// The ray is in the sun.
			color = sunColor;
		}
	}

	colorBuffer[index] = color;
}

// Optional kernel. Does it also need a temp float3 buffer?
__kernel void postProcess(
	const __global float3 *input, 
	__global float3 *output)
{
	const int x = get_global_id(0);
	const int y = get_global_id(1);
	
	const int index = x + (y * RENDER_WIDTH);
	float3 color = input[index];

	// --- Write to color here ---

	// Brightness... gamma correction...

	output[index] = float3ToRGB(color);
}

// Prepare float3 colors for display.
__kernel void convertToRGB(
	const __global float3 *input, 
	__global int *output)
{
	const int x = get_global_id(0);
	const int y = get_global_id(1);
	
	const int index = x + (y * RENDER_WIDTH);

	// The color doesn't *have* to be clamped here. It just has to be within 
	// the range of [0, 255]. Clamping is just a simple solution for now.
	float3 color = clamp(input[index], 0.0f, 1.0f);

	output[index] = float3ToRGB(color);
}
