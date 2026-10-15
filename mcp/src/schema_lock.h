// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <vector>
#include "mcp_json.h"
#include "tool_registry.h"

namespace fsqlmcp
{
    // Canonical projection + SHA-256 over it (10.5). Recursively key-sorts
    // every nesting level so source-code field order never changes the hash.
    std::string computeSchemaHash( const std::vector<ToolSpec>& tools );

    enum class LockCheckResult { Ok, Warn, Absent };

    LockCheckResult checkSchemaLock( const std::string& lockFilePath, const std::string& computedHash,
                                     std::string* expectedOut );

    void writeSchemaLock( const std::string& lockFilePath, const std::string& computedHash );
}