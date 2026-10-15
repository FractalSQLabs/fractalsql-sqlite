// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <vector>
#include "../tool_registry.h"
#include "../rows.h"

namespace fsqlmcp
{
    class Db;
    std::vector<ToolSpec> buildDiscoveryTools( Db& db, const RowLimitConfig& rowCfg );
}