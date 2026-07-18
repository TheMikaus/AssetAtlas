#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <io.h>
#include <string>
#include <unordered_map>
#include <utility>
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
  std::vector<std::array<double, 6>> uv_sets;
};

struct MaterialInfo {
  std::string name;
  double r;
  double g;
  double b;
  double opacity;
  double roughness;
  double metalness;
  double specular_factor;
  double emissive_factor;
  double emissive_r;
  double emissive_g;
  double emissive_b;
  int shader_type;
  std::string shading_model;
  std::vector<std::string> textures;
  std::string uv_set;
  std::vector<uint8_t> embedded_texture;
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

static std::string texture_path(ufbx_texture* texture) {
  if (!texture) return std::string();
  std::string path = string_from_ufbx(texture->filename);
  if (path.empty()) path = string_from_ufbx(texture->relative_filename);
  if (path.empty()) path = string_from_ufbx(texture->absolute_filename);
  if (path.empty()) path = string_from_ufbx(texture->name);
  return path;
}

static ufbx_blob texture_content(ufbx_scene* scene, ufbx_texture* texture) {
  if (!texture) return {};
  if (texture->content.data && texture->content.size > 0) return texture->content;
  if (texture->has_file && texture->file_index < scene->texture_files.count) {
    return scene->texture_files.data[texture->file_index].content;
  }
  return {};
}

static void print_base64(const uint8_t* data, size_t size) {
  static const char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  putchar('"');
  for (size_t i = 0; i < size; i += 3) {
    const uint32_t a = data[i];
    const uint32_t b = i + 1 < size ? data[i + 1] : 0;
    const uint32_t c = i + 2 < size ? data[i + 2] : 0;
    const uint32_t value = (a << 16) | (b << 8) | c;
    putchar(alphabet[(value >> 18) & 63]);
    putchar(alphabet[(value >> 12) & 63]);
    putchar(i + 1 < size ? alphabet[(value >> 6) & 63] : '=');
    putchar(i + 2 < size ? alphabet[value & 63] : '=');
  }
  putchar('"');
}

static void add_texture_path(std::vector<std::string>& paths, ufbx_texture* texture) {
  if (!texture) return;
  std::string path = texture_path(texture);
  if (!path.empty() && std::find(paths.begin(), paths.end(), path) == paths.end()) {
    paths.push_back(path);
  }
}

static double clamp01(double value) {
  return std::clamp(value, 0.0, 1.0);
}

static double normalize_unit_value(double value) {
  // Some exporters write percentage-like values (0..100) into scalar slots.
  if (value > 1.0 && value <= 100.0) {
    return value / 100.0;
  }
  return value;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: asset_atlas_mesh_importer <model.fbx> | --stdin <label>\n");
    return 2;
  }

  bool read_from_stdin = false;
  std::string input_label;
  if (std::string(argv[1]) == "--stdin") {
    read_from_stdin = true;
    input_label = argc >= 3 ? argv[2] : "<stdin>";
  } else {
    input_label = argv[1];
  }

  ufbx_load_opts opts = {};
  opts.target_axes.right = UFBX_COORDINATE_AXIS_POSITIVE_X;
  opts.target_axes.up = UFBX_COORDINATE_AXIS_POSITIVE_Y;
  opts.target_axes.front = UFBX_COORDINATE_AXIS_POSITIVE_Z;
  opts.target_unit_meters = 1.0f;

  ufbx_error error;
  ufbx_scene* scene = nullptr;
  std::vector<uint8_t> input_bytes;
  if (read_from_stdin) {
    _setmode(_fileno(stdin), _O_BINARY);
    constexpr size_t kChunkSize = 64 * 1024;
    std::vector<char> chunk(kChunkSize);
    for (;;) {
      const size_t n = fread(chunk.data(), 1, chunk.size(), stdin);
      if (n > 0) {
        input_bytes.insert(input_bytes.end(), chunk.begin(), chunk.begin() + n);
      }
      if (n < chunk.size()) {
        if (feof(stdin)) break;
        if (ferror(stdin)) {
          fprintf(stderr, "Failed reading FBX bytes from stdin.\n");
          return 1;
        }
      }
    }
    if (input_bytes.empty()) {
      fprintf(stderr, "No FBX bytes received on stdin.\n");
      return 1;
    }
    scene = ufbx_load_memory(input_bytes.data(), input_bytes.size(), &opts, &error);
  } else {
    scene = ufbx_load_file(argv[1], &opts, &error);
  }
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
    info.opacity = 1.0;
    info.roughness = 0.7;
    info.metalness = 0.0;
    info.specular_factor = 0.2;
    info.emissive_factor = 0.0;
    info.emissive_r = 0.0;
    info.emissive_g = 0.0;
    info.emissive_b = 0.0;
    info.shader_type = static_cast<int>(material->shader_type);
    info.shading_model = string_from_ufbx(material->shading_model_name);

    ufbx_texture* primary_texture = material->pbr.base_color.texture;
    if (!primary_texture) primary_texture = material->fbx.diffuse_color.texture;
    if (primary_texture) {
      info.uv_set = string_from_ufbx(primary_texture->uv_set);
      const ufbx_blob embedded = texture_content(scene, primary_texture);
      if (embedded.data && embedded.size > 0) {
        const uint8_t* begin = static_cast<const uint8_t*>(embedded.data);
        info.embedded_texture.assign(begin, begin + embedded.size);
      }
    }

    ufbx_vec3 color = material->pbr.base_color.value_vec3;
    if (!material->pbr.base_color.has_value && material->fbx.diffuse_color.has_value) {
      color = material->fbx.diffuse_color.value_vec3;
    }
    info.r = color.x;
    info.g = color.y;
    info.b = color.z;

    if (material->pbr.opacity.has_value) {
      info.opacity = clamp01(normalize_unit_value(material->pbr.opacity.value_real));
    } else if (material->fbx.transparency_factor.has_value) {
      const double transparency = clamp01(
        normalize_unit_value(material->fbx.transparency_factor.value_real)
      );
      info.opacity = clamp01(1.0 - transparency);
    }

    if (material->pbr.roughness.has_value) {
      info.roughness = clamp01(normalize_unit_value(material->pbr.roughness.value_real));
    } else if (material->fbx.specular_exponent.has_value) {
      const double exponent = std::max(1.0, material->fbx.specular_exponent.value_real);
      const double normalized = std::clamp(exponent / 100.0, 0.0, 1.0);
      info.roughness = clamp01(1.0 - normalized);
    }

    if (material->pbr.metalness.has_value) {
      info.metalness = clamp01(normalize_unit_value(material->pbr.metalness.value_real));
    }

    if (material->pbr.specular_factor.has_value) {
      info.specular_factor = clamp01(normalize_unit_value(material->pbr.specular_factor.value_real));
    } else if (material->fbx.specular_factor.has_value) {
      info.specular_factor = clamp01(normalize_unit_value(material->fbx.specular_factor.value_real));
    }

    if (material->pbr.emission_factor.has_value) {
      info.emissive_factor = std::max(0.0, material->pbr.emission_factor.value_real);
    } else if (material->fbx.emission_factor.has_value) {
      info.emissive_factor = std::max(0.0, material->fbx.emission_factor.value_real);
    }

    ufbx_vec3 emissive = {0.0, 0.0, 0.0};
    if (material->pbr.emission_color.has_value) {
      emissive = material->pbr.emission_color.value_vec3;
    } else if (material->fbx.emission_color.has_value) {
      emissive = material->fbx.emission_color.value_vec3;
    }
    info.emissive_r = clamp01(emissive.x);
    info.emissive_g = clamp01(emissive.y);
    info.emissive_b = clamp01(emissive.z);

    add_texture_path(info.textures, material->pbr.base_color.texture);
    add_texture_path(info.textures, material->fbx.diffuse_color.texture);
    add_texture_path(info.textures, material->pbr.normal_map.texture);
    add_texture_path(info.textures, material->fbx.normal_map.texture);
    add_texture_path(info.textures, material->pbr.emission_color.texture);
    add_texture_path(info.textures, material->fbx.emission_color.texture);
    add_texture_path(info.textures, material->pbr.opacity.texture);
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

  std::vector<std::string> uv_set_names;
  for (size_t mesh_index = 0; mesh_index < scene->meshes.count; ++mesh_index) {
    ufbx_mesh* mesh = scene->meshes.data[mesh_index];
    if (!mesh) continue;
    for (size_t uv_index = 0; uv_index < mesh->uv_sets.count; ++uv_index) {
      std::string name = string_from_ufbx(mesh->uv_sets.data[uv_index].name);
      if (name.empty()) name = "UVSet" + std::to_string(uv_index);
      if (std::find(uv_set_names.begin(), uv_set_names.end(), name) == uv_set_names.end()) {
        uv_set_names.push_back(name);
      }
    }
  }

  auto append_mesh = [&](ufbx_mesh* mesh, const ufbx_matrix* geometry_to_world) {
    if (!mesh || mesh->num_faces == 0) return;

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
        std::vector<std::array<double, 6>> tri_uv_sets(uv_set_names.size());
        for (size_t corner = 0; corner < 3; ++corner) {
          unsigned int vertex_index = tri_indices[tri * 3 + corner];
          ufbx_vec3 p = ufbx_get_vertex_vec3(&mesh->vertex_position, vertex_index);
          if (geometry_to_world) {
            p = ufbx_transform_position(geometry_to_world, p);
          }
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
          for (size_t uv_index = 0; uv_index < mesh->uv_sets.count; ++uv_index) {
            const ufbx_uv_set& uv_set = mesh->uv_sets.data[uv_index];
            if (!uv_set.vertex_uv.exists) continue;
            std::string uv_name = string_from_ufbx(uv_set.name);
            if (uv_name.empty()) uv_name = "UVSet" + std::to_string(uv_index);
            auto name_it = std::find(uv_set_names.begin(), uv_set_names.end(), uv_name);
            if (name_it == uv_set_names.end()) continue;
            const size_t output_index = static_cast<size_t>(name_it - uv_set_names.begin());
            ufbx_vec2 uv = ufbx_get_vertex_vec2(&uv_set.vertex_uv, vertex_index);
            tri_uv_sets[output_index][corner * 2 + 0] = uv.x;
            tri_uv_sets[output_index][corner * 2 + 1] = 1.0 - uv.y;
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
          std::move(tri_uv_sets),
        });
      }
    }
  };

  // Iterate mesh instances through scene nodes so every mesh receives its full
  // inherited node + geometric transform. Iterating scene->meshes directly
  // loses instance transforms and also collapses repeated instances to one.
  for (size_t node_index = 0; node_index < scene->nodes.count; ++node_index) {
    ufbx_node* node = scene->nodes.data[node_index];
    if (!node || !node->mesh) continue;
    append_mesh(node->mesh, &node->geometry_to_world);
  }

  // Defensive fallback for unusual scenes that contain an unattached mesh.
  for (size_t mesh_index = 0; mesh_index < scene->meshes.count; ++mesh_index) {
    ufbx_mesh* mesh = scene->meshes.data[mesh_index];
    if (!mesh || mesh->instances.count != 0) continue;
    append_mesh(mesh, nullptr);
  }

  if (vertices.empty() || faces.empty()) {
    if (scene->anim_stacks.count > 0 || scene->bones.count > 0) {
      fprintf(
        stderr,
        "FBX contains animation or skeleton data but no renderable mesh geometry. "
        "Animation-only preview is not implemented yet.\n"
      );
    } else {
      fprintf(stderr, "No renderable mesh geometry found.\n");
    }
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
  print_json_string(input_label.c_str());
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
    printf(",\"color\":[%.6g,%.6g,%.6g]", material.r, material.g, material.b);
    printf(",\"opacity\":%.6g", material.opacity);
    printf(",\"roughness\":%.6g", material.roughness);
    printf(",\"metalness\":%.6g", material.metalness);
    printf(",\"specularFactor\":%.6g", material.specular_factor);
    printf(",\"emissiveFactor\":%.6g", material.emissive_factor);
    printf(",\"emissiveColor\":[%.6g,%.6g,%.6g]", material.emissive_r, material.emissive_g, material.emissive_b);
    printf(",\"shaderType\":%d", material.shader_type);
    printf(",\"shadingModel\":");
    print_json_string(material.shading_model.c_str());
    printf(",\"uvSet\":");
    print_json_string(material.uv_set.c_str());
    printf(",\"embeddedTextureBase64\":");
    print_base64(material.embedded_texture.data(), material.embedded_texture.size());
    printf(",\"textures\":[");
    for (size_t texture_index = 0; texture_index < material.textures.size(); ++texture_index) {
      if (texture_index) putchar(',');
      print_json_string(material.textures[texture_index].c_str());
    }
    printf("]}");
  }
  printf("],\"uvSets\":[");
  for (size_t uv_set_index = 0; uv_set_index < uv_set_names.size(); ++uv_set_index) {
    if (uv_set_index) putchar(',');
    printf("{\"name\":");
    print_json_string(uv_set_names[uv_set_index].c_str());
    printf(",\"faces\":[");
    for (size_t face_index = 0; face_index < faces.size(); ++face_index) {
      if (face_index) putchar(',');
      const auto& uv = faces[face_index].uv_sets[uv_set_index];
      printf("[%.9g,%.9g,%.9g,%.9g,%.9g,%.9g]", uv[0], uv[1], uv[2], uv[3], uv[4], uv[5]);
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
