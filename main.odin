package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:math"
import "core:math/linalg"
import glm "core:math/linalg/glsl"
import "core:math/noise"
import "base:intrinsics"
import "core:image"
import "core:image/png"
import "vendor:glfw"
import gl "vendor:OpenGL"

positions: [dynamic][3]f32

camera_pos := glm.vec3([3]f32 { 0.0, 52.0, 2.0 })
camera_front := glm.vec3([3]f32 { 0.0, 0.0, -1.0 })
camera_up := glm.vec3([3]f32 { 0.0, 1.0, 0.0 })

yaw := -90.0
pitch := 0.0

first_mouse := true
last_x := 800.0 / 2.0
last_y := 600.0 / 2.0

jumping := false
jump_speed: f32
jump_rate: f32

delta_time: f64 = 0.0
last_frame: f64 = 0.0

mouse_click_time: f64 = 0.0
mouse_click_delay := false

error_callback :: proc "c" (code: i32, desc: cstring) {
    context = runtime.default_context()
    fmt.println(desc, code)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
    if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
        glfw.SetWindowShouldClose(window, glfw.TRUE)
    }
}

get_texture :: proc(program: u32) -> u32 {
    imageData, err := image.load_from_file("/Users/jaydendavila/odin-opengl/brick.png")
    fmt.println(err)
    width := cast(i32)imageData.width
    height := cast(i32)imageData.height
    data := raw_data(imageData.pixels.buf)
    
    texture: u32
    gl.GenTextures(1, &texture)

    gl.BindTexture(gl.TEXTURE_2D, texture)

    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)

    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGB, width, height, 0, gl.RGB, gl.UNSIGNED_BYTE, data)
    gl.GenerateMipmap(gl.TEXTURE_2D)

    vtexCoord_location := gl.GetAttribLocation(program, "vTexCoord")

    gl.VertexAttribPointer(cast(u32)vtexCoord_location, 2, gl.FLOAT, gl.FALSE, 8 * size_of(f32), 6 * size_of(f32))
    gl.EnableVertexAttribArray(cast(u32)vtexCoord_location)

    return texture
}

mouse_callback :: proc "c" (window: glfw.WindowHandle, xpos: f64, ypos: f64) {
    if first_mouse {
        last_x = xpos
        last_y = ypos
        first_mouse = false
    }

    xoffset := xpos - last_x
    yoffset := last_y - ypos
    last_x = xpos
    last_y = ypos

    sensitivity := 0.1
    xoffset *= sensitivity
    yoffset *= sensitivity

    yaw += xoffset
    pitch += yoffset

    if pitch > 89.0 {
        pitch = 89.0
    } else if pitch < -89.0 {
        pitch = -89.0
    }

    direction := glm.vec3([3]f32 {0.0, 0.0, 0.0})
    direction[0] = cast(f32)(glm.cos(glm.radians(yaw)) * glm.cos(glm.radians(pitch)))
    direction[1] = cast(f32)glm.sin(glm.radians(pitch))
    direction[2] = cast(f32)(glm.sin(glm.radians(yaw)) * glm.cos(glm.radians(pitch)))
    camera_front = glm.normalize(direction)
}

process_input :: proc(window: glfw.WindowHandle) {
        camera_speed: f32 = 2.5 * cast(f32)delta_time
        if glfw.GetKey(window, glfw.KEY_W) == glfw.PRESS {
            if is_collision_forward() {
                return
            }
            nofly := glm.vec3([3]f32 { camera_front[0], 0.0, camera_front[2]})
            camera_pos += camera_speed * nofly
        }
        if glfw.GetKey(window, glfw.KEY_S) == glfw.PRESS {
            if is_collision_backward() {
                return
            }
            nofly := glm.vec3([3]f32 { camera_front[0], 0.0, camera_front[2]})
            camera_pos -= camera_speed * nofly
        }
        if glfw.GetKey(window, glfw.KEY_A) == glfw.PRESS {
            if is_collision_left() {
                return
            }
            camera_pos -= glm.normalize(glm.cross(camera_front, camera_up)) * camera_speed
        }
        if glfw.GetKey(window, glfw.KEY_D) == glfw.PRESS {
            if is_collision_right() {
                return
            }
            camera_pos += glm.normalize(glm.cross(camera_front, camera_up)) * camera_speed
        }
        if glfw.GetKey(window, glfw.KEY_SPACE) == glfw.PRESS && !jumping {
            jump_speed = camera_speed * 2
            jump_rate = 0.005
            jumping = true
        }

        if glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS {
            mouse_click_time = glfw.GetTime()
            if mouse_click_delay {
                return
            }
            destroy_block()
            mouse_click_delay = true
        }

        if jumping {
            camera_pos += jump_speed * glm.vec3([3]f32 { 0.0, 1.0, 0.0 })
            if is_collision_down() {
                jumping = false
                camera_pos[1] = glm.ceil(camera_pos[1] * 10) / 10
                return
            }
            jump_speed -= jump_rate
        }

        if !is_collision_down() && !jumping {
            jump_speed = camera_speed * 2
            camera_pos += jump_speed * glm.vec3([3]f32 { 0.0, -1.0, 0.0 })
            jump_speed -= jump_rate
            if is_collision_down() {
                camera_pos[1] = glm.ceil(camera_pos[1] * 10) / 10
                return
            }
        }
}

 Y_CHUNK_MAX_DIST: f32 = 100.0;
 X_CHUNK_MAX_DIST: f32 = 8.0
 Z_CHUNK_MAX_DIST: f32 = 8.0
 MAX_DIST := 1000.0;
 MIN_DIST := 0.00001;

gen_positions :: proc() {
    x: f32 = 0.0
    y: f32 = 0.0
    z: f32 = 0.0

     for y < Y_CHUNK_MAX_DIST {
        for x < X_CHUNK_MAX_DIST {
            if y < 50 {
                append(&positions, [3]f32 { x, y, z })
            }

            for z < Z_CHUNK_MAX_DIST {
                if y < 50 {
                    append(&positions, [3]f32 { x, y, z })
                }
                z += 0.4
            }
            x += 0.4
            z = 0.0
        }

        if y < 50 {
            append(&positions, [3]f32 { x, y, z })
        }
        y += 0.4
        x = 0.0
        z = 0.0
    }
}

bottom_vec_direction :: proc() -> glm.vec3 {
   return glm.cross(glm.normalize(right_vec()), camera_front)
}

on_same_level :: proc(o: [3]f32) -> bool {
    return camera_pos[1] > o[1] - 0.4 && camera_pos[1] < o[1] + 0.4
}

right_vec :: proc() -> glm.vec3 {
    return glm.cross(camera_front, glm.vec3([3]f32 {0, 1, 0}))
}

distance_from :: proc(obj: glm.vec3) -> glm.vec3 {
    return obj - camera_pos
}

get_collisions :: proc() -> [dynamic][3]f32 {
    collisions: [dynamic][3]f32
    for &o in positions {
        collision := 
                camera_pos[0] >= o[0] - 0.4 &&
                camera_pos[0] <= o[0] + 0.4 &&
                camera_pos[1] >= o[1] - 0.4 &&
                camera_pos[1] <= o[1] + 1.0 &&
                camera_pos[2] >= o[2] - 0.4 &&
                camera_pos[2] <= o[2] + 0.4
        if collision {
            append(&collisions, o)
        }
    }

    return collisions
}

is_in_front :: proc(o: [3]f32) -> bool {
    return glm.dot(camera_front, glm.normalize(distance_from(cast(glm.vec3)o))) > 0 
}

is_in_back :: proc(o: [3]f32) -> bool {
    return glm.dot(camera_front, glm.normalize(distance_from(cast(glm.vec3)o))) < 0 
}

is_collision_forward :: proc() -> bool {
    collisions := get_collisions()
    defer delete(collisions)
    if len(collisions) > 0 {
        for &o in collisions {
            collision := on_same_level(o) && is_in_front(o)
            fmt.println(camera_pos[1])
            if collision {
                return true
            }
        }
    } 
    return false
}

is_collision_backward :: proc() -> bool {
    collisions := get_collisions()
    defer delete(collisions)
        if len(collisions) > 0 {
            for &o in collisions {
                collision := on_same_level(o) && is_in_back(o)
                if collision {
                   return true
               }
            }
        }
    return false
}

is_collision_right :: proc() -> bool {
    collisions := get_collisions()
    defer delete(collisions)
        if len(collisions) > 0 {
            for &o in collisions {
                collision := 
                glm.dot(glm.normalize(right_vec()), glm.normalize((cast(glm.vec3)o - camera_pos))) > 0 &&
                on_same_level(o)
                if collision {
                   return true
               }
            }
        }
    return false
}

is_collision_left :: proc() -> bool {
    collisions := get_collisions()
    defer delete(collisions)
        if len(collisions) > 0 {
            for &o in collisions {
                collision := 
                glm.dot(glm.normalize(right_vec()), glm.normalize((cast(glm.vec3)o - camera_pos))) < 0 &&
                on_same_level(o)
                if collision {
                   return true
               }
            }
        }
    return false
}

is_collision_down :: proc() -> bool {
    collisions := get_collisions()
    defer delete(collisions)
        if len(collisions) > 0 {
            for &o in collisions {
                collision := 
                glm.dot(bottom_vec_direction(), glm.normalize(distance_from(cast(glm.vec3)o))) < 1
                if collision {
                   return true
               }
            }
        }
    return false
}

place_block :: proc() {
    j := 0
    pos := camera_pos
    max_steps := 10

    for j < max_steps {
        i := 0

        for &o in positions {
            if
                pos[0] >= o[0] - 0.25 &&
                pos[0] <= o[0] + 0.25 &&
                pos[1] >= o[1] - 0.25 &&
                pos[1] <= o[1] + 0.25 &&
                pos[2] >= o[2] - 0.25 &&
                pos[2] <= o[2] + 0.25 {
                    append(&positions, [3]f32 { o[0], o[1] + 0.4, o[2] })
                    return
                }

                i += 1
        }

        pos += 0.4 * camera_front
        j += 1
    }
}

destroy_block :: proc() {
    j := 0
    pos := camera_pos 
    max_steps := 10

    for j < max_steps {
        i := 0

        for &o in positions {
            if
                pos[0] >= o[0] - 0.25 &&
                pos[0] <= o[0] + 0.25 &&
                pos[1] >= o[1] - 0.25 &&
                pos[1] <= o[1] + 0.25 &&
                pos[2] >= o[2] - 0.25 &&
                pos[2] <= o[2] + 0.25 {
                    unordered_remove(&positions, i)
                    j = max_steps
                    return
                }

                i += 1
        }

        pos += 0.4 * camera_front
        j += 1
    }
}


main :: proc() {
    if !glfw.Init() {
        panic("EXIT_FAILURE")
    }
    defer glfw.Terminate()

    glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, glfw.TRUE)
    glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
    glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 1)

    window := glfw.CreateWindow(640, 480, "Sweeet", nil, nil)
    if window == nil {
        panic("EXIT_FAILURE")
    }
    defer glfw.DestroyWindow(window)

    glfw.MakeContextCurrent(window)
    glfw.SwapInterval(1)

    gl.load_up_to(4, 1, glfw.gl_set_proc_address)

    w, h := glfw.GetFramebufferSize(window)
    gl.Viewport(0, 0, w, h)

    glfw.SetInputMode(window, glfw.CURSOR, glfw.CURSOR_DISABLED)
    glfw.SetKeyCallback(window, key_callback)
    glfw.SetErrorCallback(error_callback)
    glfw.SetCursorPosCallback(window, mouse_callback)
    
    /* vs := [30]f32 {
        -1.0, -1.0, 0.0, 0.0, 0.0,
        1.0, -1.0, 0.0, 1.0, 0.0,
        -1.0, 1.0, 0.0, 0.0, 1.0,
        -1.0, 1.0, 0.0, 0.0, 1.0,
        1.0, 1.0, 0.0, 1.0, 1.0,
        1.0, -1.0, 0.0, 1.0, 0.0,
    } */

    vertices := [8*36]f32 {
        //back
         -0.2, -0.2, -0.2,   1, 0, 1,   0, 0,
         0.2, -0.2, -0.2,  1, 0, 0,   1, 0,
        0.2, 0.2, -0.2,  1, 0, 0,   1, 1,
        0.2, 0.2, -0.2,  1, 0, 0,   1, 1,
        -0.2, 0.2, -0.2,   1, 0, 0,   0, 1,
        -0.2, -0.2, -0.2,   1, 0, 0,   0, 0,

        // front
         -0.2, -0.2, 0.2,   1, 0, 1,   0, 0,
         0.2, -0.2, 0.2,  1, 0, 0,   1.6, 0,
        0.2, 0.2, 0.2,  1, 0, 0,   1, 1,
        0.2, 0.2, 0.2,  1, 0, 0,   1.6, 1,
        -0.2, 0.2, 0.2,   1, 0, 0,   -0.4, 1,
        -0.2, -0.2, 0.2,   1, 0, 0,   0, 0,

         -0.2, 0.2, 0.2,   1, 0, 1,   1, 0,
        -0.2, 0.2, -0.2,  1, 0, 0,   1, 1,
        -0.2, -0.2, -0.2,  1, 0, 0,   0, 1,
        -0.2, -0.2, -0.2,   1, 0, 0,   0, 1,
        -0.2, -0.2, 0.2,   1, 0, 0,   0, 0,
        -0.2, 0.2, 0.2,   1, 0, 0,   1, 0,

        // right
         0.2, 0.2, 0.2,   1, 0, 1,   1, 0,
         0.2, 0.2, -0.2,  1, 0, 0,   1, 1,
        0.2, -0.2, -0.2,   1, 0, 0,   0, 1,
        0.2, -0.2, -0.2,   1, 0, 0,   0, 1,
        0.2, -0.2, 0.2,   1, 0, 0,   0, 0,
        0.2, 0.2, 0.2,   1, 0, 0,   1, 0,
        
         -0.2, -0.2, -0.2,   1, 0, 1,   0, 1,
         0.2, -0.2, -0.2,  1, 0, 0,   1, 1,
        0.2, -0.2, 0.2,  1, 0, 0,   1, 0,
        0.2, -0.2, 0.2,   1, 0, 0,   1, 0,
        -0.2, -0.2, 0.2,   1, 0, 0,   0, 0,
        -0.2, -0.2, -0.2,   1, 0, 0,   0, 1,

         -0.2, 0.2, -0.2,   1, 0, 1,   0, 1,
         0.2, 0.2, -0.2,  1, 0, 0,   1, 1,
        0.2, 0.2, 0.2,  1, 0, 0,   1, 0,
        0.2, 0.2, 0.2,   1, 0, 0,   1, 0,
        -0.2, 0.2, 0.2,   1, 0, 0,   0, 0,
        -0.2, 0.2, -0.2,   1, 0, 0,   0, 1,
    }

    vertex_array: u32
    gl.GenVertexArrays(1, &vertex_array)
    gl.BindVertexArray(vertex_array)

    vertex_buffer: u32;
    gl.GenBuffers(1, &vertex_buffer);
    gl.BindBuffer(gl.ARRAY_BUFFER, vertex_buffer);
    gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices, gl.STATIC_DRAW);
    // gl.BufferData(gl.ARRAY_BUFFER, size_of(vs), &vs, gl.STATIC_DRAW);

    vertex_shader_text, verr := os.read_entire_file_from_filename("/Users/jaydendavila/odin-opengl/vertex_shader.glsl")
    fragment_shader_text, ferr := os.read_entire_file_from_filename("/Users/jaydendavila/odin-opengl/fragment_shader.glsl")

    program, program_ok := gl.load_shaders_source(string(vertex_shader_text), string(fragment_shader_text))
    
    if !program_ok {
        fmt.println("ERROR: Failed to load and compile shaders")
    }

    // resolution_location := gl.GetUniformLocation(program, "resolution")

    model_location := gl.GetUniformLocation(program, "model")
    view_location := gl.GetUniformLocation(program, "view")
    projection_location := gl.GetUniformLocation(program, "projection")
    vpos_location := gl.GetAttribLocation(program, "vPos")
    // vuvs_location := gl.GetAttribLocation(program, "vUvs")
    vcol_location := gl.GetAttribLocation(program, "vCol")
    // time_location := gl.GetAttribLocation(program, "vTime")
    
    gl.VertexAttribPointer(cast(u32)vpos_location, 3, gl.FLOAT, gl.FALSE, 8 * size_of(f32), 0)
    gl.VertexAttribPointer(cast(u32)vcol_location, 3, gl.FLOAT, gl.FALSE, 8 * size_of(f32), 3 * size_of(f32))
    // gl.VertexAttribPointer(cast(u32)vpos_location, 3, gl.FLOAT, gl.FALSE, 5 * size_of(f32), 0)
    // gl.VertexAttribPointer(cast(u32)vuvs_location, 2, gl.FLOAT, gl.FALSE, 5 * size_of(f32), 3 * size_of(f32))
    
    gl.EnableVertexAttribArray(cast(u32)vpos_location)
    // gl.EnableVertexAttribArray(cast(u32)vuvs_location)
    gl.EnableVertexAttribArray(cast(u32)vcol_location)

    texture := get_texture(program)

    gl.UseProgram(program);

   /* res_loc := [2]f32 {
        cast(f32)w, cast(f32)h
    }
    gl.Uniform2fv(resolution_location, 1, raw_data(&res_loc)) */

    fmt.println(gl.GetError())

    im := matrix[4, 4]f32 {
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0
    }

    gl.Enable(gl.DEPTH_TEST)

    gen_positions()

    for !glfw.WindowShouldClose(window) {
        pm := glm.mat4Perspective(45, cast(f32)(1 / 1), 0.1, 100)

        current_frame := glfw.GetTime()
        delta_time = current_frame - last_frame
        last_frame = current_frame

        if mouse_click_delay {
            if current_frame - mouse_click_time > 0.2 {
                mouse_click_delay = false    
            }
        }

        // gl.VertexAttrib1d(cast(u32)time_location, current_frame)

        process_input(window)

        view := glm.mat4LookAt(camera_pos, camera_pos + camera_front, camera_up)
        
        gl.UniformMatrix4fv(projection_location, 1, gl.FALSE, raw_data(&pm))
        gl.UniformMatrix4fv(view_location, 1, gl.FALSE, raw_data(&view))
        
        gl.BindVertexArray(vertex_array)

        gl.BindTexture(gl.TEXTURE_2D, texture)

        gl.ClearColor(0.1, 0.5, 0.8, 1.0)
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

        // tm := glm.mat4Translate(cast(glm.vec3)positions[0])
        // angle: f32 = 20.0
        // rm := glm.mat4Rotate(cast(glm.vec3)[3]f32 {1.0, 0.3, 0.5}, cast(f32)(glfw.GetTime() * cast(f64)math.to_radians(angle)))
        // model := tm * rm
        // model := tm
        // gl.UniformMatrix4fv(model_location, 1, gl.FALSE, raw_data(&model))
        // gl.DrawArrays(gl.TRIANGLES, 0, 36) 

        for i := 0; i < len(positions); i += 1 {
            tm := glm.mat4Translate(cast(glm.vec3)positions[i])
            // angle: f32 = 20.0 * cast(f32)i
            // rm := glm.mat4Rotate(cast(glm.vec3)[3]f32 {1.0, 0.3, 0.5}, cast(f32)(glfw.GetTime() * cast(f64)math.to_radians(angle)))
            model := tm
            gl.UniformMatrix4fv(model_location, 1, gl.FALSE, raw_data(&model))
            gl.DrawArrays(gl.TRIANGLES, 0, 36) 
        }

        glfw.SwapBuffers(window)
        glfw.PollEvents()
    }

    gl.DeleteVertexArrays(1, &vertex_array)
    gl.DeleteBuffers(1, &vertex_buffer)
}
