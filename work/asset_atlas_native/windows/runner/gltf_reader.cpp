// Reading GLB and glTF, printed in the same shape the FBX path prints.
//
// Why a second reader at all: 3,035 GLB files are in this library and 192 of
// them -- the KayKit Dungeon pack -- have no FBX or OBJ twin, so nothing in
// Atlas can draw them. Every DAE and every glTF does have a twin, which is
// why only these two formats are read and DAE is not.
//
// cgltf is one MIT header with no dependencies. It is vendored beside ufbx
// rather than fetched at build time.
//
// What this reads: node transforms, positions, indices, the first UV set,
// and each material's base colour factor and base colour texture. What it
// does not: skins, animations, morph targets, cameras, lights, and the
// Draco and meshopt compressions, which are refused with a message rather
// than drawn wrong.

// cgltf is C99 and uses fopen, strcpy and strncpy, which MSVC deprecates and
// this build treats as errors. Suppressed around the vendored header only,
// rather than defining _CRT_SECURE_NO_WARNINGS for the whole importer: the
// code written here still gets the warnings.
#if defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4996)
#endif
#define CGLTF_IMPLEMENTATION
#include "third_party/cgltf/cgltf.h"
#if defined(_MSC_VER)
#pragma warning(pop)
#endif

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "gltf_reader.h"
#include "json_number.h"

namespace {

struct Matrix4 {
  float m[16];
};

Matrix4 identity_matrix() {
  Matrix4 out = {};
  out.m[0] = out.m[5] = out.m[10] = out.m[15] = 1.0f;
  return out;
}

Matrix4 multiply(const Matrix4& a, const Matrix4& b) {
  Matrix4 out = {};
  for (int column = 0; column < 4; ++column) {
    for (int row = 0; row < 4; ++row) {
      float sum = 0.0f;
      for (int k = 0; k < 4; ++k) {
        sum += a.m[k * 4 + row] * b.m[column * 4 + k];
      }
      out.m[column * 4 + row] = sum;
    }
  }
  return out;
}

void transform_point(const Matrix4& m, const float in[3], float out[3]) {
  out[0] = m.m[0] * in[0] + m.m[4] * in[1] + m.m[8] * in[2] + m.m[12];
  out[1] = m.m[1] * in[0] + m.m[5] * in[1] + m.m[9] * in[2] + m.m[13];
  out[2] = m.m[2] * in[0] + m.m[6] * in[1] + m.m[10] * in[2] + m.m[14];
}

struct GltfFace {
  int a = 0;
  int b = 0;
  int c = 0;
  int material = 0;
  int object = 0;
  float uv[6] = {0, 0, 0, 0, 0, 0};
};

struct GltfMaterial {
  std::string name;
  float r = 0.72f;
  float g = 0.76f;
  float b = 0.80f;
  float opacity = 1.0f;
  float roughness = 0.7f;
  float metalness = 0.0f;
  std::string texture;
};

void print_json_string_local(const char* value) {
  putchar('"');
  for (const char* p = value ? value : ""; *p; ++p) {
    const unsigned char c = static_cast<unsigned char>(*p);
    switch (c) {
      case '"': printf("\\\""); break;
      case '\\': printf("\\\\"); break;
      case '\n': printf("\\n"); break;
      case '\r': printf("\\r"); break;
      case '\t': printf("\\t"); break;
      default:
        if (c < 0x20) {
          printf("\\u%04x", c);
        } else {
          putchar(c);
        }
    }
  }
  putchar('"');
}

}  // namespace

bool gltf_path_looks_like_gltf(const std::string& label) {
  const size_t dot = label.find_last_of('.');
  if (dot == std::string::npos) return false;
  std::string ext = label.substr(dot + 1);
  for (char& c : ext) c = static_cast<char>(tolower(c));
  return ext == "glb" || ext == "gltf";
}

int gltf_print_model(const std::string& label,
                     const std::vector<uint8_t>& bytes,
                     const char* file_path,
                     bool probe_only,
                     bool summary_only) {
  cgltf_options options = {};
  cgltf_data* data = nullptr;
  cgltf_result result = cgltf_result_success;
  if (!bytes.empty()) {
    result = cgltf_parse(&options, bytes.data(), bytes.size(), &data);
  } else if (file_path) {
    result = cgltf_parse_file(&options, file_path, &data);
  } else {
    fprintf(stderr, "No glTF input.\n");
    return 1;
  }
  if (result != cgltf_result_success || data == nullptr) {
    fprintf(stderr, "Could not read %s as glTF.\n", label.c_str());
    if (data) cgltf_free(data);
    return 1;
  }

  // A .gltf keeps its geometry in a separate .bin beside it. From a file
  // path that can be loaded; from bytes on stdin -- which is how an entry
  // inside a zip arrives -- there is no folder to look in, and saying so is
  // better than drawing an empty mesh.
  if (bytes.empty() && file_path) {
    cgltf_load_buffers(&options, data, file_path);
  } else if (data->buffers_count > 0) {
    cgltf_load_buffers(&options, data, nullptr);
  }

  for (cgltf_size i = 0; i < data->extensions_required_count; ++i) {
    const char* name = data->extensions_required[i];
    if (name == nullptr) continue;
    if (strstr(name, "draco") != nullptr || strstr(name, "meshopt") != nullptr) {
      fprintf(stderr,
              "%s uses %s, which this reader does not decompress.\n",
              label.c_str(), name);
      cgltf_free(data);
      return 1;
    }
  }

  std::vector<float> positions;   // x,y,z per vertex
  std::vector<GltfFace> faces;
  std::vector<GltfMaterial> materials;
  std::vector<std::string> object_names;
  std::vector<std::string> texture_files;

  for (cgltf_size i = 0; i < data->materials_count; ++i) {
    const cgltf_material& source = data->materials[i];
    GltfMaterial material;
    material.name = source.name ? source.name : "";
    if (source.has_pbr_metallic_roughness) {
      const cgltf_pbr_metallic_roughness& pbr = source.pbr_metallic_roughness;
      material.r = pbr.base_color_factor[0];
      material.g = pbr.base_color_factor[1];
      material.b = pbr.base_color_factor[2];
      material.opacity = pbr.base_color_factor[3];
      material.roughness = pbr.roughness_factor;
      material.metalness = pbr.metallic_factor;
      const cgltf_texture* texture = pbr.base_color_texture.texture;
      if (texture && texture->image && texture->image->uri) {
        material.texture = texture->image->uri;
        texture_files.push_back(material.texture);
      }
    }
    materials.push_back(material);
  }
  if (materials.empty()) {
    GltfMaterial fallback;
    fallback.name = "";
    materials.push_back(fallback);
  }

  // Nodes carry the transforms; a mesh can be instanced under several.
  std::vector<std::pair<const cgltf_node*, Matrix4>> queue;
  for (cgltf_size i = 0; i < data->scenes_count; ++i) {
    const cgltf_scene& scene = data->scenes[i];
    for (cgltf_size n = 0; n < scene.nodes_count; ++n) {
      queue.push_back({scene.nodes[n], identity_matrix()});
    }
  }
  if (queue.empty()) {
    for (cgltf_size i = 0; i < data->nodes_count; ++i) {
      if (data->nodes[i].parent == nullptr) {
        queue.push_back({&data->nodes[i], identity_matrix()});
      }
    }
  }

  size_t total_triangles = 0;
  while (!queue.empty()) {
    const cgltf_node* node = queue.back().first;
    const Matrix4 parent = queue.back().second;
    queue.pop_back();
    if (node == nullptr) continue;

    Matrix4 local = identity_matrix();
    cgltf_node_transform_local(node, local.m);
    const Matrix4 world = multiply(parent, local);

    for (cgltf_size i = 0; i < node->children_count; ++i) {
      queue.push_back({node->children[i], world});
    }
    if (node->mesh == nullptr) continue;

    const int object_index = static_cast<int>(object_names.size());
    object_names.push_back(node->name ? node->name
                                      : (node->mesh->name ? node->mesh->name : ""));

    for (cgltf_size p = 0; p < node->mesh->primitives_count; ++p) {
      const cgltf_primitive& primitive = node->mesh->primitives[p];
      if (primitive.type != cgltf_primitive_type_triangles) continue;

      const cgltf_accessor* position_accessor = nullptr;
      const cgltf_accessor* uv_accessor = nullptr;
      for (cgltf_size a = 0; a < primitive.attributes_count; ++a) {
        const cgltf_attribute& attribute = primitive.attributes[a];
        if (attribute.type == cgltf_attribute_type_position) {
          position_accessor = attribute.data;
        } else if (attribute.type == cgltf_attribute_type_texcoord &&
                   attribute.index == 0) {
          uv_accessor = attribute.data;
        }
      }
      if (position_accessor == nullptr) continue;

      const int base = static_cast<int>(positions.size() / 3);
      const cgltf_size vertex_count = position_accessor->count;
      for (cgltf_size v = 0; v < vertex_count; ++v) {
        float local_position[3] = {0, 0, 0};
        cgltf_accessor_read_float(position_accessor, v, local_position, 3);
        float world_position[3] = {0, 0, 0};
        transform_point(world, local_position, world_position);
        positions.push_back(world_position[0]);
        positions.push_back(world_position[1]);
        positions.push_back(world_position[2]);
      }

      std::vector<float> uvs(vertex_count * 2, 0.0f);
      if (uv_accessor != nullptr && uv_accessor->count >= vertex_count) {
        for (cgltf_size v = 0; v < vertex_count; ++v) {
          float uv[2] = {0, 0};
          cgltf_accessor_read_float(uv_accessor, v, uv, 2);
          uvs[v * 2] = uv[0];
          // glTF puts the origin at the top left and the renderer here
          // expects the bottom left, as the FBX path produces.
          uvs[v * 2 + 1] = 1.0f - uv[1];
        }
      }

      int material_index = 0;
      if (primitive.material != nullptr && data->materials_count > 0) {
        const cgltf_size offset =
            static_cast<cgltf_size>(primitive.material - data->materials);
        if (offset < data->materials_count) {
          material_index = static_cast<int>(offset);
        }
      }

      const cgltf_size index_count =
          primitive.indices ? primitive.indices->count : vertex_count;
      for (cgltf_size i = 0; i + 2 < index_count; i += 3) {
        cgltf_size triangle[3];
        for (int k = 0; k < 3; ++k) {
          triangle[k] = primitive.indices
                            ? cgltf_accessor_read_index(primitive.indices, i + k)
                            : (i + k);
          if (triangle[k] >= vertex_count) triangle[k] = 0;
        }
        GltfFace face;
        face.a = base + static_cast<int>(triangle[0]);
        face.b = base + static_cast<int>(triangle[1]);
        face.c = base + static_cast<int>(triangle[2]);
        face.material = material_index;
        face.object = object_index;
        for (int k = 0; k < 3; ++k) {
          face.uv[k * 2] = uvs[triangle[k] * 2];
          face.uv[k * 2 + 1] = uvs[triangle[k] * 2 + 1];
        }
        faces.push_back(face);
        total_triangles += 1;
      }
    }
  }

  if (probe_only) {
    if (faces.empty()) {
      fprintf(stderr, "No renderable mesh geometry found.\n");
      cgltf_free(data);
      return 1;
    }
    printf("{\"kind\":\"mesh\",\"faces\":%zu", total_triangles);
    // glTF skins are not read, so no rig is claimed. A file that holds one
    // reports no bones rather than a wrong count.
    printf(",\"bones\":0,\"rigMarkers\":[],\"boneNames\":[]}");
    cgltf_free(data);
    return 0;
  }

  if (summary_only) {
    printf("{\"name\":");
    print_json_string_local(label.c_str());
    printf(",\"kind\":\"mesh\",\"faces\":%zu", total_triangles);
    printf(",\"vertices\":%zu", positions.size() / 3);
    printf(",\"objects\":%zu", object_names.size());
    printf(",\"materials\":%zu", materials.size());
    printf(",\"bones\":0,\"rigMarkers\":[],\"boneNames\":[]");
    printf(",\"materialNames\":[");
    for (size_t i = 0; i < materials.size(); ++i) {
      if (i) putchar(',');
      print_json_string_local(materials[i].name.c_str());
    }
    printf("],\"textureFiles\":[");
    for (size_t i = 0; i < texture_files.size(); ++i) {
      if (i) putchar(',');
      print_json_string_local(texture_files[i].c_str());
    }
    printf("],\"objectNames\":[");
    for (size_t i = 0; i < object_names.size(); ++i) {
      if (i) putchar(',');
      print_json_string_local(object_names[i].c_str());
    }
    printf("]}");
    cgltf_free(data);
    return 0;
  }

  if (faces.empty()) {
    fprintf(stderr, "No renderable mesh geometry found in %s.\n", label.c_str());
    cgltf_free(data);
    return 1;
  }

  printf("{\"name\":");
  print_json_string_local(label.c_str());
  printf(",\"kind\":\"mesh\"");
  printf(",\"unitMeters\":1");
  printf(",\"objects\":[");
  for (size_t i = 0; i < object_names.size(); ++i) {
    if (i) putchar(',');
    print_json_string_local(object_names[i].c_str());
  }
  printf("],\"vertices\":[");
  for (size_t i = 0; i < positions.size(); i += 3) {
    if (i) putchar(',');
    printf("[%.9g,%.9g,%.9g]", json_double(positions[i]),
           json_double(positions[i + 1]), json_double(positions[i + 2]));
  }
  printf("],\"faceObjects\":[");
  for (size_t i = 0; i < faces.size(); ++i) {
    if (i) putchar(',');
    printf("%d", faces[i].object);
  }
  printf("],\"faces\":[");
  for (size_t i = 0; i < faces.size(); ++i) {
    const GltfFace& f = faces[i];
    if (i) putchar(',');
    printf("[%d,%d,%d,%d,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g]", f.a, f.b, f.c,
           f.material,
           json_double(f.uv[0]), json_double(f.uv[1]),
           json_double(f.uv[2]), json_double(f.uv[3]),
           json_double(f.uv[4]), json_double(f.uv[5]));
  }
  printf("],\"materials\":[");
  for (size_t i = 0; i < materials.size(); ++i) {
    const GltfMaterial& material = materials[i];
    if (i) putchar(',');
    printf("{\"name\":");
    print_json_string_local(material.name.c_str());
    printf(",\"color\":[%.6g,%.6g,%.6g]", json_double(material.r),
           json_double(material.g), json_double(material.b));
    printf(",\"opacity\":%.6g", json_double(material.opacity));
    printf(",\"roughness\":%.6g", json_double(material.roughness));
    printf(",\"metalness\":%.6g", json_double(material.metalness));
    printf(",\"specularFactor\":0.2");
    printf(",\"emissiveFactor\":0");
    printf(",\"emissiveColor\":[0,0,0]");
    printf(",\"shaderType\":0");
    printf(",\"shadingModel\":\"gltf\"");
    printf(",\"emissiveTexture\":\"\"");
    printf(",\"normalTexture\":\"\"");
    printf(",\"uvSet\":\"\"");
    printf(",\"embeddedTextureBase64\":\"\"");
    printf(",\"textures\":[");
    if (!material.texture.empty()) {
      print_json_string_local(material.texture.c_str());
    }
    printf("]}");
  }
  printf("],\"uvSets\":[],\"textureFiles\":[");
  for (size_t i = 0; i < texture_files.size(); ++i) {
    if (i) putchar(',');
    print_json_string_local(texture_files[i].c_str());
  }
  printf("],\"sceneTextures\":[]}");

  cgltf_free(data);
  return 0;
}
