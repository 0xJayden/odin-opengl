#version 330 core

uniform mat4 model;
uniform mat4 view;
uniform mat4 projection;

in vec3 vCol;
in vec3 vPos;
in vec2 vUvs;
in vec2 vTexCoord;
in float vTime;

out vec3 color;
out vec2 texCoord;
out vec2 uvs;
out float time;

void main()
{
    gl_Position = projection * view * model * vec4(vPos, 1.0);
    color = vCol;
    texCoord = vTexCoord;
    uvs = vUvs; 
    time = vTime;
}
