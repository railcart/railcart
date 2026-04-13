#ifndef CPOSEIDON_H
#define CPOSEIDON_H

#include <stdint.h>

/// Hash 1-4 BN254 field elements using the Poseidon hash function.
///
/// Each element is represented as 4 little-endian uint64 limbs (256 bits).
/// The result is written to `output` in the same format.
///
/// Implemented by rs-poseidon (https://github.com/logos-storage/rs-poseidon),
/// the same Poseidon implementation used by RAILGUN's poseidon-hash-wasm.
///
/// @param inputs  Array of field elements, each is uint64_t[4] (little-endian limbs)
/// @param count   Number of inputs (1-4)
/// @param output  Result field element, uint64_t[4] (little-endian limbs)
void poseidon_hash(const uint64_t (*inputs)[4], int count, uint64_t *output);

#endif
