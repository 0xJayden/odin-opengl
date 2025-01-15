#version 330 core

in vec3 color;
in vec2 texCoord;
// in vec2 uvs;
// in float time;

out vec4 fragment;

uniform sampler2D diffuse;
// uniform vec2 resolution;

float inverse_lerp(float v, float min_value, float max_value) {
    return (v - min_value) / (max_value - min_value);
}

float remap(float v, float in_min, float out_max) {
    float t = inverse_lerp(v, in_min, out_max);
    return mix(in_min, out_max, t);
}

float saturate(float x) {
    return clamp(x, 0.0, 1.0);
}

float sdf_sphere(vec3 p, float r) {
    return length(p) - r;
}

float sdBox( vec3 p, vec3 b )
{
  vec3 q = abs(p) - b;
  return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0);
}

float sdPlane(vec3 pos) {
    return pos.y;
}

float math_random(vec2 p) {
    p = 50.0 * fract(p * 0.3183099 + vec2(0.71, 0.113));
    return -1.0 + 2.0 * fract(p.x * p.y * (p.x + p.y));
}

float step(float p1, float p2, float x) {
    if (x < (p1 - p2) / 2) {
        return p1;
    }
    return p2;
}

float noise(vec2 coords) {
    vec2 tex_size = vec2(1.0);
    vec2 pc = coords * tex_size;
    vec2 base = floor(pc);

    float s1 = math_random((base + vec2(0.0, 0.0)) / tex_size);
    float s2 = math_random((base + vec2(1.0, 0.0)) / tex_size);
    float s3 = math_random((base + vec2(0.0, 1.0)) / tex_size);
    float s4 = math_random((base + vec2(1.0, 1.0)) / tex_size);

    vec2 f = smoothstep(0.0, 1.0, fract(pc));

    float px1 = mix(s1, s2, f.x);
    float px2 = mix(s3, s4, f.x);
    float result = mix(px1, px2, f.y);

    return result;
}

float noise_fbm(vec2 p, int octaves, float persistence, float lacunarity) {
    float amplitude = 0.5;
    float total = 0.0;

    for (int i = 0; i < octaves; ++i) {
        float noise_value = noise(p);
        total += noise_value * amplitude;
        amplitude *= persistence;
        p = p * lacunarity;
    }

    return total;
}

struct MaterialData {
    vec3 color;
    float dist;
};

vec3 RED = vec3(1.0, 0.0, 0.0);
vec3 BLUE = vec3(0.0, 0.0, 1.0);
vec3 GREEN = vec3(0.0, 1.0, 0.0);
vec3 GRAY = vec3(0.5);
vec3 WHITE = vec3(1.0);

MaterialData op_u(MaterialData a, MaterialData b) {
    if (a.dist < b.dist) {
        return a;
    }
    return b;
}

MaterialData map(vec3 pos) {
    float cur_noise_sample = noise_fbm(pos.xz / 2.0, 1, 0.5, 2.0);
    cur_noise_sample = abs(cur_noise_sample);
    cur_noise_sample *= 1.5;
    cur_noise_sample += 0.1 * noise_fbm(pos.xz * 4.0, 6, 0.5, 2.0);

    float WATER_LEVEL = 0.45;

    vec3 land_color = vec3(0.498, 0.435, 0.396);
    land_color = mix(
        land_color,
        land_color * 0.25,
        smoothstep(WATER_LEVEL - 0.1, WATER_LEVEL, cur_noise_sample)
    );

    MaterialData result = MaterialData(
        land_color, pos.y + cur_noise_sample
    ); 

    vec3 shallow_color = vec3(0.25, 0.25, 0.75);
    vec3 deep_color = vec3(0.025, 0.025, 0.15);
    vec3 water_color = mix(
        shallow_color,
        deep_color,
        smoothstep(WATER_LEVEL, WATER_LEVEL + 0.1, cur_noise_sample)
    );
    water_color = mix(
        water_color,
        WHITE,
        smoothstep(WATER_LEVEL + 0.0125, WATER_LEVEL, cur_noise_sample)
    );

    MaterialData water = MaterialData(
        water_color, pos.y + WATER_LEVEL
    );

    result = op_u(result, water);

    return result;
}

vec3 get_normal(vec3 pos) {
    const float EPS = 0.0001;
    vec3 n = vec3(
            map(pos + vec3(EPS, 0.0, 0.0)).dist - map(pos - vec3(EPS, 0.0, 0.0)).dist,
            map(pos + vec3(0.0, EPS, 0.0)).dist - map(pos - vec3(0.0, EPS, 0.0)).dist,
            map(pos + vec3(0.0, 0.0, EPS)).dist - map(pos - vec3(0.0, 0.0, EPS)).dist
            );
    return normalize(n);
}

vec3 get_lighting(vec3 pos, vec3 normal, vec3 light_color, vec3 light_dir) {
    float dp = saturate(dot(normal, light_dir));

    return light_color * dp;
}

float get_ao(vec3 pos, vec3 normal) {
    float ao = 0.0;
    float step_size = 0.1;

    for (float i = 0.0; i < 5.0; ++i) {
        float dist_factor = 1.0 / pow(2.0, i);

        ao += dist_factor * (i * step_size - map(pos + normal * i * step_size).dist);
    }

    return 1.0 - ao;
}

const int NUM_STEPS = 256;
const float MAX_DIST = 1000.0;
const float MIN_DIST = 0.00001;

MaterialData ray_cast(vec3 cam_origin, vec3 cam_dir, int num_steps, float start_dist, float max_dist) {
    MaterialData material = MaterialData(vec3(0.0), start_dist);
    MaterialData default_material = MaterialData(vec3(0.0), -1.0);

    for (int i = 0; i < NUM_STEPS; ++i) {
        vec3 pos = cam_origin + material.dist * cam_dir;

        MaterialData result = map(pos);

        if (abs(result.dist) < MIN_DIST * material.dist) {
            break;
        }
        material.dist += result.dist;
        material.color = result.color;

        if (material.dist > max_dist) {
            return default_material;
        }

    }

    return material;
}

float get_shadow(vec3 pos, vec3 light_dir) {
    MaterialData result = ray_cast(pos, light_dir, 64, 0.01, 10.0);

    if (result.dist >= 0.0) {
        return 0.0;
    }

    return 1.0;
}

vec3 ray_march(vec3 cam_origin, vec3 cam_dir) {
    MaterialData material = ray_cast(cam_origin, cam_dir, NUM_STEPS, 1.0, MAX_DIST);

    vec3 light_dir = normalize(vec3(-0.5, 0.2, -0.6));
    float sky_t = exp(saturate(cam_dir.y) * -40.0);
    float sun_factor = pow(saturate(dot(light_dir, cam_dir)), 8.0);
    vec3 sky_color = mix(vec3(0.025, 0.065, 0.5), vec3(0.4, 0.5, 1.0), sky_t);
    vec3 fog_color = mix(sky_color, vec3(1.0, 0.9, 0.65), sun_factor);

    if (material.dist < 0.0) {
        return fog_color;
    }

    vec3 pos = cam_origin + material.dist * cam_dir;

    vec3 light_color = WHITE;
    vec3 normal = get_normal(pos);
    float shadowed = get_shadow(pos, light_dir);
    vec3 lighting = get_lighting(pos, normal, light_color, light_dir);
    lighting *= shadowed;
    vec3 color = material.color * lighting;

    float fog_dist = distance(cam_origin, pos); 
    float inscatter = 1.0 - exp(-fog_dist * fog_dist * 0.0005);
    float extinction = exp(-fog_dist * fog_dist * 0.01);

    color = color * extinction + fog_color * inscatter;

    return color;
}

mat3 make_cam_mat(vec3 cam_origin, vec3 cam_look_at, vec3 cam_up) {
    vec3 z = normalize(cam_look_at - cam_origin);
    vec3 x = normalize(cross(z, cam_up));
    vec3 y = cross(x, z);
    return mat3(x, y, z);
}

void main() {
    /* vec2 pixel_coords = (uvs - 0.5) * resolution;

    float t = time * 0.0;
    vec3 ray_dir = normalize(vec3(pixel_coords * 2.0 / resolution.y, 1.0));
    vec3 ray_origin = vec3(3.0, 0.75, -3.0) * vec3(cos(t), 1.0, sin(t));
    vec3 ray_look_at = vec3(0.0);
    mat3 cam = make_cam_mat(ray_origin, ray_look_at, vec3(0.0, 1.0, 0.0));

    vec3 color = ray_march(ray_origin, cam * ray_dir); */

    // fragment = vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
    fragment = texture(diffuse, texCoord) * vec4(color, 1.0);
}
