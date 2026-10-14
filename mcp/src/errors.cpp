// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "errors.h"
#include <regex>

namespace fsqlmcp
{
    std::string sanitizeSecrets( std::string_view text )
    {
        std::string s( text );

        // scheme://user:PASSWORD@host -> scheme://user:***@host (username kept)
        static const std::regex kUriCred( R"((\w+://[^:/\s@]+:)([^@\s]+)(@))" );
        s = std::regex_replace( s, kUriCred, "$1***$3" );

        // KEY=value / KEY = value for PASSWORD / AUTH_TOKEN / *_KEY-style keys
        static const std::regex kKvCred(
            R"(((?:[A-Z_]*PASSWORD|AUTH_TOKEN|[A-Z_]*_KEY)\s*=\s*)(\S+))",
            std::regex::icase );
        s = std::regex_replace( s, kKvCred, "$1***" );

        return s;
    }
}