// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Vectorizer tier (SQLite column): 6 tools. There is no
// fractal_vectorizer_enqueue; status is a tool and also the
// fractalsql://vectorizer/status resource.
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
              Obj("options", false, "{max_embeds_per_window:int, rate_window_secs:int=3600, chunk_size:int (characters, 1..100000), chunk_overlap:int=0, chunk_mode:fixed|paragraph|sentence=paragraph, chunk_table:string=<source_table>_chunks}") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object()
                    ? a.at( "options" ).dump() : "{}";
                return parseJsonLenient( db.callScalar( "SELECT fractal_vectorizer_create(?, ?, ?, ?)",
                    { a.at( "source_table" ).get<std::string>(), a.at( "text_col" ).get<std::string>(),
                      a.at( "embedding_col" ).get<std::string>(), opts } ) );
            } } );
        t.back().description = "Installs the AFTER INSERT/UPDATE sync trigger(s) and immediately backfills the "
            "queue with rows missing an embedding. With chunk_size in the options the text is first split (see fractal_chunk_text) into the chunk table "
            "(parent_id, chunk_no, chunk_text, <embedding_col>), the chunks follow the source row (insert, update, delete) and the CHUNKS are what is embedded. The (source_table,text_col,embedding_col) triple is unique: "
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

        t.push_back( ToolSpec{ "fractal_vectorizer_status", "Vectorizer", ToolClass::Cheap,
            {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                // fractal_vectorizer_status is a VIEW over TEMP objects scoped to the connection that created a vectorizer; on a fresh
                // session the engine's own error is reported with that explanation.
                Json arr = Json::array();
                std::exception_ptr pending;
                try
                {
                    const std::vector<std::string> names = db.columnNames( "SELECT * FROM fractal_vectorizer_status" );
                    const std::vector<std::vector<SqlValue>> rows = db.queryAll( "SELECT * FROM fractal_vectorizer_status", {} );
                    for( const auto& row : rows )
                    {
                        Json obj = Json::object();
                        for( std::size_t c = 0; c < row.size() && c < names.size(); ++c )
                            obj[ names[ c ] ] = asScalarJson( row[ c ] );
                        arr.push_back( std::move( obj ) );
                    }
                }
                catch( const ToolError& e )
                {
                    if( e.errorClass == ErrorClass::Engine )
                        pending = std::make_exception_ptr( ToolError( ErrorClass::Schema,
                            "fractal_vectorizer_status is empty on this connection; the vectorizer registry and queue are scoped to the "
                            "connection that created one (create a vectorizer on this session first). Underlying engine note: " + e.message ) );
                    else
                        pending = std::current_exception();
                }
                if( pending ) std::rethrow_exception( pending );
                return Json{ { "vectorizers", arr } };
            } } );
        t.back().idempotentHint = true;
        t.back().description = "One row per vectorizer on this connection: its id, source table, text and embedding columns, state (enabled or paused), "
            "the queue counts (pending, done, failed) and the last error. The same data as the fractalsql://vectorizer/status resource.";

        return t;
    }
}