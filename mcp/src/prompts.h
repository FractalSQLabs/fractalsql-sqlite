// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include "mcp_json.h"
#include <string>

namespace fsqlmcp { class Prompts { public: static Json list(); static Json get( const std::string& name, const Json& args ); }; }