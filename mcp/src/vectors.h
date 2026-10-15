// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <string_view>
#include <vector>
#include <cstdint>
#include "mcp_json.h"
#include "errors.h"

namespace fsqlmcp::vectors
{
    // 1.4 lenient coercion: ONLY applied to vector-array elements. A string
    // that parses cleanly as a finite number is coerced; anything else (incl.
    // bool, which JSON-wise looks numeric but must NOT be silently coerced)
    // is returned unchanged so it still fails validation as a real error.
    Json coerceNumber( const Json& element );

    // The core conversion: JSON array of numbers -> engine CSV text,
    // e.g. "0.1,0.2,0.3". Rejects null/non-array/empty/non-numeric elements
    // (after lenient coercion) with a Schema error naming up to 3 offenders.
    std::string vectorParamToText( const Json& value, std::string_view paramName );

    // doc_ids / cohort_doc_ids convention: integers only, NO coercion leniency,
    // bracketed JSON text ("[1,2,3]"), deliberately distinct from the CSV
    // vector convention above.
    std::string intArrayToJsonText( const Json& value, std::string_view paramName );

    std::string stringArrayToJsonText( const Json& value, std::string_view paramName );

    // Canonical fractal_vector BLOB: u16 dim (LE) + u16 reserved + float32[dim].
    // Each element rounded to 14 decimal places before emission (suppresses
    // float->JSON round-trip noise; the "14" is deliberate, keep it exact).
    Json blobToNumbers( const std::uint8_t* data, std::size_t len );

    std::string blobToHex( const std::uint8_t* data, std::size_t len );

    // {"value": ...} envelope for primitives with no natural JSON shape
    // (fractal_search, fractal_dimension_dfa, L_p distance, Hamming distance).
    Json wrapScalar( const Json& value );

    // Hex -> raw bytes; rejects odd length and non-hex digits with a Schema
    // error (fractal_vector_hamming_distance / fractal_audit_unpack inputs).
    std::vector<std::uint8_t> hexToBytes( const std::string& hex, std::string_view paramName );
}