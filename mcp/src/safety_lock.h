// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <vector>
#include "tool_registry.h"

namespace fsqlmcp
{
    // 15.3: narrower than schema_lock's full-schema hash: ONLY the three
    // safety-relevant hints, one line per tool, sorted by tool name.
    // Deliberately human-diffable in a PR review, unlike a hash.
    std::string renderSafetyAnnotations( const std::vector<ToolSpec>& tools );

    // Hard mismatch (exit 3), never just a warning, regardless of
    // FSQL_MCP_STRICT_SCHEMA_HASH: a safety-hint regression is not the kind
    // of change this spec wants a quiet default to allow through. An absent
    // lock file is dev-mode friendly (same stance as schema_lock, 10.5).
    bool checkSafetyAnnotations( const std::string& lockPath, const std::string& rendered,
                                 std::string* diffOut );

    void writeSafetyAnnotations( const std::string& lockPath, const std::string& rendered );
}