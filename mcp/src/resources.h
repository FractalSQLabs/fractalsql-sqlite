// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include "mcp_json.h"

namespace fsqlmcp
{
    class Db;
    class Resources
    {
    public:
        static void init( Db* db );
        static Json list();
        static Json read( const std::string& uri );
    };
}