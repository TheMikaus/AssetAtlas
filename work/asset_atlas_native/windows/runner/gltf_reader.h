// Reading GLB and glTF, printed in the shape the FBX path prints.
#ifndef RUNNER_GLTF_READER_H_
#define RUNNER_GLTF_READER_H_

#include <cstdint>
#include <string>
#include <vector>

/// Whether this label names a file this reader handles.
bool gltf_path_looks_like_gltf(const std::string& label);

/// Reads the model and prints it as JSON, in the same shape the FBX path
/// prints: `--probe` for kind and bones, `--summary` for the counts and
/// names, neither for the full geometry.
///
/// Pass the bytes when they came in over stdin, or a file path when they
/// did not -- a `.gltf` keeps its geometry in a separate `.bin` and can
/// only be completed from a path.
int gltf_print_model(const std::string& label,
                     const std::vector<uint8_t>& bytes,
                     const char* file_path,
                     bool probe_only,
                     bool summary_only);

#endif  // RUNNER_GLTF_READER_H_
