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
  std::string normal_texture;
  std::string emissive_texture;
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
      default:
        // Control bytes are illegal raw in JSON. Bytes >= 0x80 must pass
        // through untouched: they are UTF-8 continuation bytes and escaping
        // them individually would corrupt the text.
        if (static_cast<unsigned char>(*p) < 0x20) {
          printf("\\u%04x", static_cast<unsigned char>(*p));
        } else {
          putchar(*p);
        }
        break;
    }
  }
  putchar('"');
}

static std::string string_from_ufbx(ufbx_string value) {
  if (!value.data || value.length == 0) return std::string();
  return std::string(value.data, value.length);
}

// A bone's path from the root, as "Hips/Spine_01/Clavicle_L/...".
//
// Bone *names* are not unique in these rigs: the left and right hands both
// carry `Finger_03`, and ufbx disambiguates the second one it meets as
// `Finger_03_1`. Which hand gets the suffix depends on node order, and that
// order differs between a character file and a clip file -- so joining two
// rigs on the bare name silently swapped left and right fingers. The chain
// down from the root does not have that problem.
static std::string bone_path(const ufbx_node* node) {
  std::string path;
  for (const ufbx_node* n = node; n && !n->is_root; n = n->parent) {
    std::string name = string_from_ufbx(n->name);
    path = path.empty() ? name : name + "/" + path;
  }
  return path;
}

// How many poses to sample out of a clip.
//
// A preview only has to read as motion, and every frame costs a full scene
// evaluation plus 3 floats per bone in the JSON. 30 per second up to 120 keeps
// a two-second locomotion clip whole and bounds a long one.
static const double kSkeletonSampleRate = 30.0;
static const size_t kMaxSkeletonFrames = 120;

// Emits the skeleton and its motion: the bone hierarchy once, then the world
// position of every bone at each sampled time.
//
// Positions rather than transforms because that is all a stick-figure preview
// draws -- a line from each bone to its parent. ufbx evaluates the whole
// hierarchy, so no curve interpolation or parent composition happens here.
static void print_skeleton(ufbx_scene* scene, double duration) {
  std::vector<ufbx_node*> bones;
  for (size_t i = 0; i < scene->nodes.count; ++i) {
    ufbx_node* node = scene->nodes.data[i];
    if (!node || node->is_root) continue;
    if (node->bone || node->attrib_type == UFBX_ELEMENT_BONE) {
      bones.push_back(node);
    }
  }
  // A rig exported without bone attributes still has the hierarchy; fall back
  // to every non-root node so such a file is not silently empty.
  if (bones.empty()) {
    for (size_t i = 0; i < scene->nodes.count; ++i) {
      ufbx_node* node = scene->nodes.data[i];
      if (node && !node->is_root) bones.push_back(node);
    }
  }

  printf(",\"skeleton\":{\"bones\":[");
  for (size_t i = 0; i < bones.size(); ++i) {
    if (i) putchar(0x2C);
    printf("{\"name\":");
    print_json_string(string_from_ufbx(bones[i]->name).c_str());
    printf(",\"path\":");
    print_json_string(bone_path(bones[i]).c_str());
    // Index into this same list, or -1 for a root. Resolved here because the
    // consumer would otherwise have to match names a second time.
    int parent_index = -1;
    const ufbx_node* parent = bones[i]->parent;
    if (parent) {
      for (size_t j = 0; j < bones.size(); ++j) {
        if (bones[j] == parent) {
          parent_index = (int)j;
          break;
        }
      }
    }
    printf(",\"parent\":%d}", parent_index);
  }
  printf("]");

  size_t frame_count = 1;
  if (duration > 0.0) {
    frame_count = (size_t)(duration * kSkeletonSampleRate) + 1;
    if (frame_count > kMaxSkeletonFrames) frame_count = kMaxSkeletonFrames;
    if (frame_count < 2) frame_count = 2;
  }

  const ufbx_anim* anim = scene->anim;
  double time_begin = 0.0;
  if (scene->anim_stacks.count > 0 && scene->anim_stacks.data[0]) {
    time_begin = scene->anim_stacks.data[0]->time_begin;
  }

  printf(",\"frameRate\":%.6g", frame_count > 1 && duration > 0.0
    ? (double)(frame_count - 1) / duration
    : kSkeletonSampleRate);
  printf(",\"stride\":12");

  // The rig's own rest pose, unevaluated.
  //
  // A clip and a character are different files whose rigs need not be posed
  // the same way at rest, so a clip's absolute bone transforms cannot be
  // applied to a character directly -- doing that threw the arms over the
  // head. What transfers is the motion *relative* to each rig's own rest, and
  // this is the half of that the clip has to supply.
  printf(",\"rest\":[");
  for (size_t i = 0; i < bones.size(); ++i) {
    const ufbx_matrix m = bones[i]->node_to_world;
    if (i) putchar(0x2C);
    printf("%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g",
      m.cols[0].x, m.cols[0].y, m.cols[0].z,
      m.cols[1].x, m.cols[1].y, m.cols[1].z,
      m.cols[2].x, m.cols[2].y, m.cols[2].z,
      m.cols[3].x, m.cols[3].y, m.cols[3].z);
  }
  printf("]");

  printf(",\"frames\":[");
  for (size_t frame = 0; frame < frame_count; ++frame) {
    const double t = frame_count > 1
      ? time_begin + duration * ((double)frame / (double)(frame_count - 1))
      : time_begin;
    if (frame) putchar(0x2C);
    putchar(0x5B);
    ufbx_error eval_error;
    ufbx_scene* posed = ufbx_evaluate_scene(scene, anim, t, NULL, &eval_error);
    for (size_t i = 0; i < bones.size(); ++i) {
      ufbx_node* node = bones[i];
      if (posed && node->element_id < posed->elements.count) {
        ufbx_element* element = posed->elements.data[node->element_id];
        if (element && element->type == UFBX_ELEMENT_NODE) {
          node = (ufbx_node*)element;
        }
      }
      // Column-major 3x4: the three basis columns then the translation.
      // The translation is the bone's world position, which is all the
      // stick-figure view reads.
      const ufbx_matrix m = node->node_to_world;
      if (i) putchar(0x2C);
      printf("%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g",
        m.cols[0].x, m.cols[0].y, m.cols[0].z,
        m.cols[1].x, m.cols[1].y, m.cols[1].z,
        m.cols[2].x, m.cols[2].y, m.cols[2].z,
        m.cols[3].x, m.cols[3].y, m.cols[3].z);
    }
    if (posed) ufbx_free_scene(posed);
    putchar(0x5D);
  }
  printf("]}");
}

// The bones that separate one rig family from another, printed by --probe.
//
// Which family a file belongs to cannot be read off its name: `SK_` is an
// Unreal skeletal-mesh prefix that Synty uses on Polygon-rigged characters,
// and the Sidekick rig is the Unreal mannequin with extra bones. The bones
// themselves are unambiguous, so the probe reports which of these it saw and
// the caller decides what that means.
static const char* const kRigMarkerBones[] = {
  // Polygon: Synty's own rig, capitalised.
  "Hips", "UpperLeg_R", "Clavicle_L", "Spine_01",
  // Unreal mannequin: lowercase.
  "pelvis", "thigh_l", "clavicle_l", "spine_01",
  // Sidekick: the mannequin plus attachment and IK bones.
  "hipAttachFront", "hipAttach_l", "ik_hand_gun", "ik_hand_root",
};

static void print_rig_markers(ufbx_scene* scene) {
  printf(",\"rigMarkers\":[");
  bool first = true;
  for (size_t m = 0; m < sizeof(kRigMarkerBones) / sizeof(kRigMarkerBones[0]); ++m) {
    const char* marker = kRigMarkerBones[m];
    bool present = false;
    for (size_t i = 0; i < scene->nodes.count && !present; ++i) {
      const ufbx_node* node = scene->nodes.data[i];
      if (!node || node->is_root) continue;
      // Exact, case-sensitive: `Hips` and `hips` belong to different rigs.
      if (string_from_ufbx(node->name) == marker) present = true;
    }
    if (!present) continue;
    if (!first) putchar(0x2C);
    first = false;
    print_json_string(marker);
  }
  printf("]");
}

static bool debug_spaces_enabled() {
  size_t len = 0;
  char* value = nullptr;
  if (_dupenv_s(&value, &len, "ASSET_ATLAS_DEBUG_SPACES") != 0) return false;
  const bool on = value != nullptr;
  free(value);
  return on;
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
  bool probe_only = false;
  std::string input_label;
  const char* file_argument = nullptr;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--stdin") {
      read_from_stdin = true;
    } else if (arg == "--probe") {
      // Classification only: skip geometry extraction and the JSON
      // payload, which dominate cost when sweeping a whole catalog.
      probe_only = true;
    } else if (!file_argument) {
      file_argument = argv[i];
    }
  }
  input_label = file_argument ? file_argument : "<stdin>";
  if (!read_from_stdin && !file_argument) {
    fprintf(stderr, "Usage: asset_atlas_mesh_importer [--probe] <model.fbx> | --stdin [--probe] <label>\n");
    return 2;
  }

  ufbx_load_opts opts = {};
  opts.target_axes.right = UFBX_COORDINATE_AXIS_POSITIVE_X;
  opts.target_axes.up = UFBX_COORDINATE_AXIS_POSITIVE_Y;
  opts.target_axes.front = UFBX_COORDINATE_AXIS_POSITIVE_Z;
  opts.target_unit_meters = 1.0f;
  // Bake the unit conversion into the geometry rather than into a root
  // transform. The default leaves mesh vertices in the file's own units while
  // the skin cluster bind matrices come back converted, so a character's
  // vertices sat at 0.88 while its bone origins sat at 166 -- the same rig,
  // a hundred times apart.
  opts.space_conversion = UFBX_SPACE_CONVERSION_MODIFY_GEOMETRY;

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
    scene = ufbx_load_file(file_argument, &opts, &error);
  }
  if (!scene) {
    fprintf(stderr, "ufbx failed: %s\n", error.description.data ? error.description.data : "unknown error");
    return 1;
  }

  if (probe_only) {
    size_t total_faces = 0;
    for (size_t i = 0; i < scene->meshes.count; ++i) {
      const ufbx_mesh* mesh = scene->meshes.data[i];
      if (mesh) total_faces += mesh->num_faces;
    }
    if (total_faces == 0 &&
        (scene->anim_stacks.count > 0 || scene->bones.count > 0)) {
      double duration = 0.0;
      for (size_t i = 0; i < scene->anim_stacks.count; ++i) {
        const ufbx_anim_stack* stack = scene->anim_stacks.data[i];
        if (!stack) continue;
        const double length = stack->time_end - stack->time_begin;
        if (length > duration) duration = length;
      }
      printf("{\"kind\":\"animation\",\"animationStacks\":%zu", scene->anim_stacks.count);
      printf(",\"bones\":%zu", scene->bones.count);
      printf(",\"durationSeconds\":%.6g", duration);
      print_rig_markers(scene);
      printf("}");
      ufbx_free_scene(scene);
      return 0;
    }
    if (total_faces == 0) {
      fprintf(stderr, "No renderable mesh geometry found.\n");
      ufbx_free_scene(scene);
      return 1;
    }
    printf("{\"kind\":\"mesh\",\"faces\":%zu", total_faces);
    printf(",\"bones\":%zu", scene->bones.count);
    print_rig_markers(scene);
    printf("}");
    ufbx_free_scene(scene);
    return 0;
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
    // Named separately as well: the renderer has to know which of a
    // material's textures is the normal map, not just that one exists.
    {
      ufbx_texture* normal_texture = material->pbr.normal_map.texture;
      if (!normal_texture) normal_texture = material->fbx.normal_map.texture;
      if (!normal_texture) normal_texture = material->fbx.bump.texture;
      if (normal_texture) info.normal_texture = texture_path(normal_texture);
    }
    {
      ufbx_texture* emissive_texture = material->pbr.emission_color.texture;
      if (!emissive_texture) emissive_texture = material->fbx.emission_color.texture;
      if (emissive_texture) info.emissive_texture = texture_path(emissive_texture);
    }
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

  // Skin data, gathered across every mesh in the file.
  //
  // `skin_bone_names` is the join key: a clip and a character are separate
  // files, and the Synty rigs use identical bone names, so a name is what
  // connects an animated bone to the vertices it moves.
  std::vector<std::string> skin_bone_names;
  std::vector<std::string> skin_bone_paths;
  // `geometry_to_bone` composed with the inverse of the mesh's own
  // geometry-to-world, because the vertices emitted below are already in world
  // space. Without that second term a posed character lands in the wrong place.
  std::vector<ufbx_matrix> skin_bind_inverse;
  // Four influences per vertex as (bone, weight); zero-weight padded. Four is
  // what game rigs use and what Synty's export carries.
  std::vector<std::array<double, 8>> skin_vertices;
  // Per emitted vertex, an index into `skin_vertices`, or -1.
  std::vector<int> vertex_skin;

  auto skin_bone_index = [&](ufbx_skin_cluster* cluster,
                             const ufbx_matrix* geometry_to_world) -> int {
    if (!cluster || !cluster->bone_node) return -1;
    const std::string name = string_from_ufbx(cluster->bone_node->name);
    const std::string path = bone_path(cluster->bone_node);
    for (size_t i = 0; i < skin_bone_paths.size(); ++i) {
      if (skin_bone_paths[i] == path) return (int)i;
    }
    // `geometry_to_bone` maps the mesh's own geometry space to the bone. The
    // vertices below are emitted in world space, so the inverse of the mesh's
    // geometry-to-world has to come first -- a Synty character's geometry is
    // centred on the origin while its skeleton stands on the ground, and
    // without this term the two are 0.88m apart.
    ufbx_matrix bind = cluster->geometry_to_bone;
    if (geometry_to_world) {
      const ufbx_matrix world_to_geometry = ufbx_matrix_invert(geometry_to_world);
      bind = ufbx_matrix_mul(&bind, &world_to_geometry);
    }
    skin_bone_names.push_back(name);
    skin_bone_paths.push_back(path);
    skin_bind_inverse.push_back(bind);
    return (int)skin_bone_names.size() - 1;
  };

  auto append_mesh = [&](ufbx_mesh* mesh, const ufbx_matrix* geometry_to_world) {
    if (!mesh || mesh->num_faces == 0) return;
    if (debug_spaces_enabled()) {
      if (geometry_to_world) {
        const ufbx_matrix& g = *geometry_to_world;
        fprintf(stderr, "geometry_to_world translation (%.4f,%.4f,%.4f) scale x %.4f\n",
          g.cols[3].x, g.cols[3].y, g.cols[3].z, g.cols[0].x);
      } else {
        fprintf(stderr, "geometry_to_world: none\n");
      }
      double lo = 1e30, hi = -1e30;
      for (size_t v = 0; v < mesh->num_vertices; ++v) {
        const ufbx_vec3 p = mesh->vertices.data[v];
        if (p.y < lo) lo = p.y;
        if (p.y > hi) hi = p.y;
      }
      fprintf(stderr, "raw mesh y %.4f..%.4f, skin deformers %zu\n",
        lo, hi, mesh->skin_deformers.count);
    }

    // Build this mesh's vertex influence table before walking its faces, so a
    // corner only has to look up its vertex.
    ufbx_skin_deformer* skin = mesh->skin_deformers.count > 0
      ? mesh->skin_deformers.data[0]
      : NULL;
    const size_t skin_base = skin_vertices.size();
    if (skin) {
      for (size_t v = 0; v < mesh->num_vertices; ++v) {
        std::array<double, 8> influences = {0, 0, 0, 0, 0, 0, 0, 0};
        if (v < skin->vertices.count) {
          const ufbx_skin_vertex sv = skin->vertices.data[v];
          const size_t take = sv.num_weights < 4 ? sv.num_weights : 4;
          for (size_t w = 0; w < take; ++w) {
            const ufbx_skin_weight weight = skin->weights.data[sv.weight_begin + w];
            ufbx_skin_cluster* cluster = weight.cluster_index < skin->clusters.count
              ? skin->clusters.data[weight.cluster_index]
              : NULL;
            const int bone = skin_bone_index(cluster, geometry_to_world);
            if (bone < 0) continue;
            influences[w * 2 + 0] = (double)bone;
            influences[w * 2 + 1] = weight.weight;
          }
        }
        skin_vertices.push_back(influences);
      }
    }

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
          if (skin && vertex_index < mesh->vertex_indices.count) {
            vertex_skin.push_back(
              (int)(skin_base + mesh->vertex_indices.data[vertex_index]));
          } else {
            vertex_skin.push_back(-1);
          }
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
      // Animation-only content is a legitimate result, not a failure.
      // Report it as such so the catalog can classify the asset instead
      // of showing an import error.
      double duration = 0.0;
      for (size_t i = 0; i < scene->anim_stacks.count; ++i) {
        const ufbx_anim_stack* stack = scene->anim_stacks.data[i];
        if (!stack) continue;
        const double length = stack->time_end - stack->time_begin;
        if (length > duration) duration = length;
      }
      printf("{\"kind\":\"animation\",\"name\":");
      print_json_string(input_label.c_str());
      printf(",\"animationStacks\":%zu", scene->anim_stacks.count);
      printf(",\"bones\":%zu", scene->bones.count);
      printf(",\"durationSeconds\":%.6g", duration);
      printf(",\"animationNames\":[");
      for (size_t i = 0; i < scene->anim_stacks.count; ++i) {
        const ufbx_anim_stack* stack = scene->anim_stacks.data[i];
        if (i) putchar(0x2C);
        print_json_string(stack ? string_from_ufbx(stack->name).c_str() : "");
      }
      printf("]");
      print_skeleton(scene, duration);
      printf("}");
      ufbx_free_scene(scene);
      return 0;
    }
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

  // The vertices above have just been recentred and rescaled to fit the
  // viewer's unit box, but the bind matrices were built against the file's
  // own coordinates. Left alone the two disagree -- a character whose mesh
  // ends up centred on the origin while its skeleton still stands on the
  // ground, which tears the model apart when a clip poses it.
  //
  // Fold the inverse of that normalisation into each bind matrix, so it maps
  // the *emitted* vertices into bone space. The consumer applies the forward
  // normalisation again after skinning; `normalizeCenter` and
  // `normalizeScale` below are what it needs to do that.
  if (!skin_bind_inverse.empty()) {
    ufbx_matrix denormalize = ufbx_identity_matrix;
    denormalize.cols[0].x = 1.0 / scale;
    denormalize.cols[1].y = 1.0 / scale;
    denormalize.cols[2].z = 1.0 / scale;
    denormalize.cols[3].x = center.x;
    denormalize.cols[3].y = center.y;
    denormalize.cols[3].z = center.z;
    for (ufbx_matrix& bind : skin_bind_inverse) {
      bind = ufbx_matrix_mul(&bind, &denormalize);
    }
  }

  printf("{\"kind\":\"mesh\",\"name\":");
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
    printf(",\"emissiveTexture\":");
    print_json_string(material.emissive_texture.c_str());
    printf(",\"normalTexture\":");
    print_json_string(material.normal_texture.c_str());
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
  if (!skin_bone_names.empty()) {
    printf("],\"skin\":{\"bones\":[");
    for (size_t i = 0; i < skin_bone_names.size(); ++i) {
      if (i) putchar(0x2C);
      printf("{\"name\":");
      print_json_string(skin_bone_names[i].c_str());
      printf(",\"path\":");
      print_json_string(skin_bone_paths[i].c_str());
      const ufbx_matrix m = skin_bind_inverse[i];
      printf(",\"bindInverse\":[%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g]}",
        m.cols[0].x, m.cols[0].y, m.cols[0].z,
        m.cols[1].x, m.cols[1].y, m.cols[1].z,
        m.cols[2].x, m.cols[2].y, m.cols[2].z,
        m.cols[3].x, m.cols[3].y, m.cols[3].z);
    }
    printf("],\"vertices\":[");
    for (size_t i = 0; i < skin_vertices.size(); ++i) {
      if (i) putchar(0x2C);
      const std::array<double, 8>& w = skin_vertices[i];
      printf("%d,%.5g,%d,%.5g,%d,%.5g,%d,%.5g",
        (int)w[0], w[1], (int)w[2], w[3],
        (int)w[4], w[5], (int)w[6], w[7]);
    }
    printf("],\"normalizeCenter\":[%.9g,%.9g,%.9g],\"normalizeScale\":%.9g",
      center.x, center.y, center.z, scale);
    printf(",\"vertexSkin\":[");
    for (size_t i = 0; i < vertex_skin.size(); ++i) {
      if (i) putchar(0x2C);
      printf("%d", vertex_skin[i]);
    }
    printf("]}");
    // A skinned mesh needs its own rest pose too: it is the reference a clip's
    // motion is applied against, and without it there is nothing to check the
    // skinning maths against.
    print_skeleton(scene, 0.0);
    printf(",\"uvSets\":[");
  } else {
    printf("],\"uvSets\":[");
  }
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
