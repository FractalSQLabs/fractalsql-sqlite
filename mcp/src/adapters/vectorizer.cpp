// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Vectorizer tier (SQLite column): 5 tools. SQLite has no
// fractal_vectorizer_enqueue (MariaDB-only); status is exposed as the
// fractalsql://vectorizer/status resource, not a tool.
#include "vectorizer.h"
#include "../db.h"
#include "../tool_param_helpers.h"

namespace fsqlmcp
{
    std::vector<ToolSpec> buildVectorizerTools( Db& db )
    {
        std::vector<ToolSpec> t;

        t.push_back( ToolSpec{ "fractal_vectorizer_create", "Vectorizer", ToolClass::Cheap,
            { Str("source_table", true, "Table to sync (needs a single-column primary key)."),
              Str("text_col", true, "Source text column."), Str("embedding_col", true, "Destination embedding column."),
              Obj("options", false, "{max_embeds_per_window:int, rate_window_secs:int=3600}") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object()
                    ? a.at( "options" ).dump() : "{}";
                return parseJsonLenient( db.callScalar( "SELECT fractal_vectorizer_create(?, ?, ?, ?)",
                    { a.at( "source_table" ).get<std::string>(), a.at( "text_col" ).get<std::string>(),
                      a.at( "embedding_col" ).get<std::string>(), opts } ) );
            } } );
        t.back().description = "Installs the AFTER INSERT/UPDATE sync trigger(s) and immediately backfills the "
            "queue with rows missing an embedding. The (source_table,text_col,embedding_col) triple is unique: "
            "drop the old vectorizer first to re-create. NOTE: the registry/queue are TEMP objects scoped to "
            "THIS session's connection.";

        t.push_back( ToolSpec{ "fractal_vectorizer_pause", "Vectorizer", ToolClass::Cheap,
            { Int("id", true, "Vectorizer id.") }, std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_vectorizer_pause(?)",
                    { a.at( "id" ).get<std::int64_t>() } ) );
            } } );
        t.back().description = "Disables a vectorizer (idempotent). New writes aren't queued; the processor "
            "skips existing pending rows. Clean error on a nonexistent id.";

        t.push_back( ToolSpec{ "fractal_vectorizer_resume", "Vectorizer", ToolClass::Cheap,
            { Int("id", true, "Vectorizer id.") }, std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_vectorizer_resume(?)",
                    { a.at( "id" ).get<std::int64_t>() } ) );
            } } );
        t.back().description = "Re-enables a paused vectorizer. Clean error on a nonexistent id.";

        t.push_back( ToolSpec{ "fractal_vectorizer_drop", "Vectorizer", ToolClass::Cheap,
            { Int("id", true, "Vectorizer id.") }, std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_vectorizer_drop(?)",
                    { a.at( "id" ).get<std::int64_t>() } ) );
            } } );
        t.back().description = "PERMANENT AND IRREVERSIBLE: deregisters the vectorizer, drops its trigger and "
            "deletes its config/queue history. For a temporary stop use pause instead.";

        t.push_back( ToolSpec{ "fractal_vectorizer_process_queue", "Vectorizer", ToolClass::Cheap,
            { Int("batch_size", false, "Rows per batch.", 100),
              Int("stale_after", false, "Stale-claim reclaim window, seconds.", 600) },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_vectorizer_process_queue(?, ?)",
                    { a.value( "batch_size", 100 ), a.value( "stale_after", 600 ) } ) );
            } } );
        t.back().description = "Drives the actual embedding sync: call on your own schedule; there is NO "
            "background worker in any engine, by design. Runs in a single transaction; failed rows are NOT "
            "retried automatically.";

        return t;
    }
}