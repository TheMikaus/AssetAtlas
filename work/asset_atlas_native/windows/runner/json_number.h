#ifndef RUNNER_JSON_NUMBER_H_
#define RUNNER_JSON_NUMBER_H_

#include <cmath>

// JSON has no NaN and no infinity, and a parser is right to refuse them.
//
// A model can carry a non-finite number: glass.fbx in Kenney's Food Kit has
// a NaN in a UV, and printing it raw emitted
//   "faces":[[0,1,2,0,0,1,0,1,nan,1],...
// so the whole file was unreadable ("Unexpected character at 5742") rather
// than one coordinate being wrong. Zero is in range for every field either
// reader prints: a position, a UV, a colour, a weight, a matrix cell.
//
// Shared by both readers because both print the same JSON shape, and the
// invariant is about the output rather than about either reader: nothing
// this program prints can be invalid JSON, whatever a file holds.
inline double json_double(double value) {
  return std::isfinite(value) ? value : 0.0;
}

#endif  // RUNNER_JSON_NUMBER_H_
