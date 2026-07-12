#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unordered_map>
#include <vector>

#include "third_party/ufbx/ufbx.h"

struct Vec3 {
  double x;
  double y;
  double z;
};

struct Vec4 {
  double x;
  double y;
  double z;
  double w;
};

struct Face {
  int a;
  int b;
  int c;
  int material;
  double u1;
  double v1;
  double u2;
  double v2;
  double u3;
  double v3;
};

struct MaterialInfo {
  std::string name;
  double r;
  double g;
  double b;
  std::vector<std::string> textures;
};

struct SceneTextureInfo {
  std::string name;
  std::string filename;
  std::string relative_filename;
  std::string absolute_filename;
};

static void print_json_string(const char* text) {
  putchar('"');
  for (const char* p = text; *p; ++p) {
    switch (*p) {
      case '\\': printf("\\\\"); break;
      case '"': printf("\\\""); break;
      case '\n': printf("\\n"); break;
      case '\r': printf("\\r"); break;
      case '\t': printf("\\t"); break;
      default: putchar(*p); break;
    }
  }
  putchar('"');
}

static std::string string_from_ufbx(ufbx_string value) {
  if (!value.data || value.length == 0) return std::string();
  return std::string(value.data, value.length);
}

static void add_texture_path(std::vector<std::string>& paths, ufbx_texture* texture) {
  if (!texture) return;
  std::string path = string_from_ufbx(texture->filename);
  if (path.empty()) path = string_from_ufbx(texture->relative_filename);
  if (path.empty()) path = string_from_ufbx(texture->absolute_filename);
  if (!path.empty() && std::find(paths.begin(), paths.end(), path) == paths.end()) {
    paths.push_back(path);
  }
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: asset_atlas_mesh_importer <model.fbx>\n");
    return 2;
  }

  ufbx_load_opts opts = {};
  opts.target_axes.right = UFBX_COORDINATE_AXIS_POSITIVE_X;
  opts.target_axes.up = UFBX_COORDINATE_AXIS_POSITIVE_Y;
  opts.target_axes.front = UFBX_COORDINATE_AXIS_POSITIVE_Z;
  opts.target_unit_meters = 1.0f;

  ufbx_error error;
  ufbx_scene* scene = ufbx_load_file(argv[1], &opts, &error);
  if (!scene) {
    fprintf(stderr, "ufbx failed: %s\n", error.description.data ? error.description.data : "unknown error");
    return 1;
  }

  std::vector<Vec3> vertices;
  std::vector<Vec4> vertex_colors;
  std::vector<Face> faces;
  std::vector<MaterialInfo> materials;
  std::vector<SceneTextureInfo> scene_textures;
  std::unordered_map<const ufbx_material*, int> material_indices;

  for (size_t material_index = 0; material_index < scene->materials.count; ++material_index) {
    ufbx_material* material = scene->materials.data[material_index];
    material_indices[material] = static_cast<int>(material_index);
    MaterialInfo info;
    info.name = string_from_ufbx(material->name);
    ufbx_vec3 color = material->pbr.base_color.value_vec3;
    if (!material->pbr.base_color.has_value && material->fbx.diffuse_color.has_value) {
      color = material->fbx.diffuse_color.value_vec3;
    }
    info.r = color.x;
    info.g = color.y;
    info.b = color.z;
    add_texture_path(info.textures, material->pbr.base_color.texture);
    add_texture_path(info.textures, material->fbx.diffuse_color.texture);
    add_texture_path(info.textures, material->pbr.normal_map.texture);
    add_texture_path(info.textures, material->fbx.normal_map.texture);
    for (size_t texture_index = 0; texture_index < material->textures.count; ++texture_index) {
      add_texture_path(info.textures, material->textures.data[texture_index].texture);
    }
    materials.push_back(info);
  }

  for (size_t texture_index = 0; texture_index < scene->textures.count; ++texture_index) {
    ufbx_texture* texture = scene->textures.data[texture_index];
    if (!texture) continue;
    SceneTextureInfo info;
    info.name = string_from_ufbx(texture->name);
    info.filename = string_from_ufbx(texture->filename);
    info.relative_filename = string_from_ufbx(texture->relative_filename);
    info.absolute_filename = string_from_ufbx(texture->absolute_filename);
    scene_textures.push_back(info);
  }

  for (size_t mesh_index = 0; mesh_index < scene->meshes.count; ++mesh_index) {
    ufbx_mesh* mesh = scene->meshes.data[mesh_index];
    if (!mesh || mesh->num_faces == 0) continue;

    std::vector<unsigned int> tri_indices(mesh->max_face_triangles * 3);
    for (size_t face_index = 0; face_index < mesh->num_faces; ++face_index) {
      ufbx_face face = mesh->faces.data[face_index];
      int material_index = 0;
      if (mesh->face_material.count > face_index) {
        uint32_t mesh_material_index = mesh->face_material.data[face_index];
        if (mesh_material_index < mesh->materials.count && mesh->materials.data[mesh_material_index]) {
          auto it = material_indices.find(mesh->materials.data[mesh_material_index]);
          if (it != material_indices.end()) {
            material_index = it->second;
          }
        }
      }
      size_t num_triangles = ufbx_triangulate_face(tri_indices.data(), tri_indices.size(), mesh, face);
      for (size_t tri = 0; tri < num_triangles; ++tri) {
        int base = static_cast<int>(vertices.size());
        double tri_uvs[6] = {0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
        for (size_t corner = 0; corner < 3; ++corner) {
          unsigned int vertex_index = tri_indices[tri * 3 + corner];
          ufbx_vec3 p = ufbx_get_vertex_vec3(&mesh->vertex_position, vertex_index);
          vertices.push_back({p.x, p.y, p.z});
          Vec4 color = {1.0, 1.0, 1.0, 1.0};
          if (mesh->vertex_color.exists) {
            ufbx_vec4 c = ufbx_get_vertex_vec4(&mesh->vertex_color, vertex_index);
            color = {c.x, c.y, c.z, c.w};
          }
          vertex_colors.push_back(color);
          if (mesh->vertex_uv.exists) {
            ufbx_vec2 uv = ufbx_get_vertex_vec2(&mesh->vertex_uv, vertex_index);
            tri_uvs[corner * 2 + 0] = uv.x;
            tri_uvs[corner * 2 + 1] = 1.0 - uv.y;
          }
        }
        faces.push_back({
          base,
          base + 1,
          base + 2,
          material_index,
          tri_uvs[0],
          tri_uvs[1],
          tri_uvs[2],
          tri_uvs[3],
          tri_uvs[4],
          tri_uvs[5],
        });
      }
    }
  }

  if (vertices.empty() || faces.empty()) {
    fprintf(stderr, "No renderable mesh geometry found.\n");
    ufbx_free_scene(scene);
    return 1;
  }

  Vec3 minv = vertices[0];
  Vec3 maxv = vertices[0];
  for (const Vec3& v : vertices) {
    minv.x = std::min(minv.x, v.x);
    minv.y = std::min(minv.y, v.y);
    minv.z = std::min(minv.z, v.z);
    maxv.x = std::max(maxv.x, v.x);
    maxv.y = std::max(maxv.y, v.y);
    maxv.z = std::max(maxv.z, v.z);
  }
  Vec3 center = {(minv.x + maxv.x) * 0.5, (minv.y + maxv.y) * 0.5, (minv.z + maxv.z) * 0.5};
  double max_dim = std::max({maxv.x - minv.x, maxv.y - minv.y, maxv.z - minv.z, 0.0001});
  double scale = 2.0 / max_dim;
  for (Vec3& v : vertices) {
    v.x = (v.x - center.x) * scale;
    v.y = (v.y - center.y) * scale;
    v.z = (v.z - center.z) * scale;
  }

  printf("{\"name\":");
  print_json_string(argv[1]);
  printf(",\"vertices\":[");
  for (size_t i = 0; i < vertices.size(); ++i) {
    const Vec3& v = vertices[i];
    if (i) putchar(',');
    printf("[%.9g,%.9g,%.9g]", v.x, v.y, v.z);
  }
  printf("],\"vertexColors\":[");
  for (size_t i = 0; i < vertex_colors.size(); ++i) {
    const Vec4& c = vertex_colors[i];
    if (i) putchar(',');
    printf("[%.9g,%.9g,%.9g,%.9g]", c.x, c.y, c.z, c.w);
  }
  printf("],\"faces\":[");
  for (size_t i = 0; i < faces.size(); ++i) {
    const Face& f = faces[i];
    if (i) putchar(',');
    printf("[%d,%d,%d,%d,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g]", f.a, f.b, f.c, f.material, f.u1, f.v1, f.u2, f.v2, f.u3, f.v3);
  }
  printf("],\"materials\":[");
  for (size_t i = 0; i < materials.size(); ++i) {
    const MaterialInfo& material = materials[i];
    if (i) putchar(',');
    printf("{\"name\":");
    print_json_string(material.name.c_str());
    printf(",\"color\":[%.6g,%.6g,%.6g],\"textures\":[", material.r, material.g, material.b);
    for (size_t texture_index = 0; texture_index < material.textures.size(); ++texture_index) {
      if (texture_index) putchar(',');
      print_json_string(material.textures[texture_index].c_str());
    }
    printf("]}");
  }
  printf("],\"textureFiles\":[");
  for (size_t i = 0; i < scene->texture_files.count; ++i) {
    ufbx_texture_file file = scene->texture_files.data[i];
    std::string path = string_from_ufbx(file.filename);
    if (path.empty()) path = string_from_ufbx(file.relative_filename);
    if (path.empty()) path = string_from_ufbx(file.absolute_filename);
    if (i) putchar(',');
    print_json_string(path.c_str());
  }
  printf("],\"sceneTextures\":[");
  for (size_t i = 0; i < scene_textures.size(); ++i) {
    const SceneTextureInfo& texture = scene_textures[i];
    if (i) putchar(',');
    printf("{\"name\":");
    print_json_string(texture.name.c_str());
    printf(",\"filename\":");
    print_json_string(texture.filename.c_str());
    printf(",\"relativeFilename\":");
    print_json_string(texture.relative_filename.c_str());
    printf(",\"absoluteFilename\":");
    print_json_string(texture.absolute_filename.c_str());
    printf("}");
  }
  printf("]}");

  ufbx_free_scene(scene);
  return 0;
}
