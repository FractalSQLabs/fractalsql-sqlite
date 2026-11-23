// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Discovery tier: 19 tools.
#include "discovery.h"
#include "../db.h"
#include "../vectors.h"
#include "../tool_param_helpers.h"
#include <string>

namespace fsqlmcp
{
    static Json annotatedRowsResult( Db& db, const std::string& sql, const std::vector<SqlValue>& binds,
                                     const BoundedCount& bc )
    {
        Json rows = parseJsonStrict( db.callScalar( sql, binds ) );
        return annotateRows( std::move( rows ), bc );
    }

    std::vector<ToolSpec> buildDiscoveryTools( Db& db, const RowLimitConfig& rowCfg )
    {
        std::vector<ToolSpec> t;

        t.push_back( ToolSpec{ "fractal_sfs_converge", "Discovery", ToolClass::Cheap,
            { Vec("vector", true, "The stored vector to compare against."),
              Vec("query", true, "Query vector.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                return vectors::wrapScalar( asScalarJson( db.callScalar( "SELECT fractal_sfs_converge(?, ?)",
                    { vectors::vectorParamToText( a.at("vector"), "vector" ),
                      vectors::vectorParamToText( a.at("query"), "query" ) } ) ) );
            } } );
        t.back().description = "Sniper-mode SFS convergence: returns the cosine distance of the single best point "
            "minimizing cosine distance to the query over the unit box, over one stored vector. Per-row scalar on "
            "SQLite: iterations/population/diffusion are fixed at their SFS defaults; use fractal_sfs_converge_debug for "
            "the tunable form, or fractal_search_explore for diverse multi-result discovery.";

        t.push_back( ToolSpec{ "fractal_sfs_converge_debug", "Discovery", ToolClass::Cheap,
            { Vec("query", true, "Query vector."),
              Int("iterations", false, "SFS iterations.", 30),
              Int("population_size", false, "SFS population size.", 50),
              Int("diffusion_factor", false, "SFS diffusion factor.", 2) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonStrict( db.callScalar( "SELECT fractal_sfs_converge_debug(?, ?, ?, ?)",
                    { vectors::vectorParamToText( a.at("query"), "query" ),
                      a.value("iterations", 30), a.value("population_size", 50), a.value("diffusion_factor", 2) } ) );
            } } );
        t.back().description = "Same Sniper convergence as fractal_sfs_converge with a full trajectory trace: {dim, "
            "generations, population_size, best_point, best_fit, best_fit_per_gen, paths}: the tunable form "
            "(SQLite's fractal_sfs_converge has its knobs fixed). best_point is a plain JSON array of numbers.";

        t.push_back( ToolSpec{ "fractal_search_explore", "Discovery", ToolClass::Cheap,
            { Vec("emb", true, "Corpus embeddings: the vectors to search over."),
              Vec("query", true, "Query vector."),
              Int("population_size", false, "Population size (also injected into params.population_size).", 50),
              Obj("params", false, "{mmr_lambda:number=0.5, iterations:int=15, diffusion_factor:int=2}", Json::object()),
              RowLimit() },
            std::nullopt, false, true,
            [&db, &rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "population_size", 50, rowCfg );
                Json params = a.value("params", Json::object());
                params["population_size"] = bc.passed;
                return annotateRows( parseJsonStrict( db.callScalar( "SELECT fractal_search_explore(?, ?, ?)",
                    { vectors::vectorParamToText( a.at("emb"), "emb" ),
                      vectors::vectorParamToText( a.at("query"), "query" ),
                      params.dump() } ) ), bc );
            } } );
        t.back().description = "Scout-mode diverse population search: brute-force relevance scan over your embedding "
            "column followed by MMR re-ranking to prevent mode collapse; the anti-collapsed-top-K primitive.";

        t.push_back( ToolSpec{ "fractal_search_telemetry", "Discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to scan."), Str("vector_col", true, "Embedding column."),
              Vec("query", true, "Query vector."), Int("k", false, "Neighbors to return.", 5), RowLimit() },
            std::nullopt, false, true,
            [&db, &rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                return annotatedRowsResult( db, "SELECT fractal_search_telemetry(?, ?, ?, ?)",
                    { a.at("table_name").get<std::string>(), a.at("vector_col").get<std::string>(),
                      vectors::vectorParamToText( a.at("query"), "query" ),
                      static_cast<std::int64_t>( bc.passed ) }, bc );
            } } );
        t.back().description = "Ground-truth K-nearest real table rows to a query vector, by exact cosine distance: "
            "[{doc_id, distance, scan_pos}]. doc_id is the row's SQLite rowid (a real locator; resolve back with "
            "WHERE rowid = doc_id); scan_pos is the 0-indexed position within THIS call's scan, the handle "
            "fractal_feedback_report/fractal_isolate_background want, distinct from doc_id.";

        t.push_back( ToolSpec{ "fractal_search", "Discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to search."), Str("vector_col", true, "Embedding column."),
              Vec("query", true, "Query vector."), Int("k", false, "Neighbors to return.", 5),
              Obj("options", false, "{index:string, nprobe:int, rerank:int, use_index:bool=true, verify:bool=true, model:string, ids:int[] (restrict the search to these rowids)}", Json::object()),
              RowLimit() },
            std::nullopt, false, true,
            [&db, &rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object()
                    ? a.at( "options" ).dump() : "{}";
                return annotatedRowsResult( db, "SELECT fractal_search(?, ?, ?, ?, ?)",
                    { a.at("table_name").get<std::string>(), a.at("vector_col").get<std::string>(),
                      vectors::vectorParamToText( a.at("query"), "query" ),
                      static_cast<std::int64_t>( bc.passed ), opts }, bc );
            } } );
        t.back().idempotentHint = true;
        t.back().description = "Indexed approximate K-nearest real table rows to a query vector: [{doc_id, distance, scan_pos}]. "
            "Probes the IVF index built by fractal_index_create (default nprobe calibrated at build time) and VERIFIES every "
            "candidate against the stored vectors, so distances are exact cosine distances, not approximations; rows added "
            "after the build are scanned exactly and deleted rows are dropped. Falls back to the exact scan when the table has "
            "no index. The ids option restricts the search to a set of rowids (for example from json_group_array(rowid) over an ordinary "
            "WHERE): a short set is scanned exactly, a long one goes through the index and is filtered. Does not apply Diversify "
            "repulsion: use fractal_search_telemetry for stateful diversity. doc_id is the row's SQLite rowid.";

        t.push_back( ToolSpec{ "fractal_index_create", "Discovery", ToolClass::Expensive,
            { Str("table_name", true, "Table to index."), Str("vector_col", true, "Embedding column."),
              Obj("options", false, "{name:string, vector_format:INT8|INT4|FP16|FP32=INT8, nlist:int, pca_dim:int, target_recall:number=0.95, calibration_samples:int=200, model:string, seed:int}", Json::object()) },
            std::nullopt, true, false,   /* persists the index: refused in read-only mode */
            [&db]( const Json& a, CallCtx& ) {
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object()
                    ? a.at( "options" ).dump() : "{}";
                return parseJsonStrict( db.callScalar( "SELECT fractal_index_create(?, ?, ?)",
                    { a.at("table_name").get<std::string>(), a.at("vector_col").get<std::string>(), opts } ) );
            } } );
        t.back().description = "Builds an IVF index (k-means cells, INT8/INT4 residual codes on a PCA basis, or FP16/FP32) over an "
            "embedding column and stores it in the database (fractal_index_meta / fractal_index_cells). Samples rows to "
            "calibrate the default nprobe to target_recall. Returns {name, format, rows, nlist, pca_dim, generation, bytes, "
            "calibrated_nprobe}. Refuses an existing name: use fractal_index_rebuild.";

        t.push_back( ToolSpec{ "fractal_index_rebuild", "Discovery", ToolClass::Expensive,
            { Str("name", true, "Index name.") }, std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonStrict( db.callScalar( "SELECT fractal_index_rebuild(?)", { a.at("name").get<std::string>() } ) );
            } } );
        t.back().description = "Full re-cluster from the table's current rows with the options the index was created with, as a new "
            "generation switched in atomically (readers never see a partial index). Replaces the previous generation.";

        t.push_back( ToolSpec{ "fractal_index_drop", "Discovery", ToolClass::Cheap,
            { Str("name", true, "Index name.") }, std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                return Json{ { "dropped", asScalarJson( db.callScalar( "SELECT fractal_index_drop(?)", { a.at("name").get<std::string>() } ) ) } };
            } } );
        t.back().description = "PERMANENT: deletes the index's stored cells and metadata (the table and its vectors are untouched; "
            "fractal_search falls back to the exact scan).";

        t.push_back( ToolSpec{ "fractal_index_info", "Discovery", ToolClass::Cheap,
            { Str("name", true, "Index name.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonStrict( db.callScalar( "SELECT fractal_index_info(?)", { a.at("name").get<std::string>() } ) );
            } } );
        t.back().idempotentHint = true;
        t.back().description = "Index format, dimension, cells, rows indexed vs now, delta/stale flags, calibrated default nprobe with "
            "its recall estimates, and the last search's statistics (used_index, rows_scanned, cells_probed): the 'index "
            "actually used' check. Also a status (ready, stale, degraded, empty or orphaned) and an advice list: for example 'refresh: 60 rows "
            "were added since the build', 'rebuild: 30% of the rows were deleted', or 'the build's calibration reached recall 0.63 "
            "against a target of 0.95'.";

        t.push_back( ToolSpec{ "fractal_index_list", "Discovery", ToolClass::Cheap,
            {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                return Json{ { "indexes", parseJsonStrict( db.callScalar( "SELECT fractal_index_list()", {} ) ) } };
            } } );
        t.back().idempotentHint = true;
        t.back().description = "The catalog: one entry per index with name, table, column, format, dim, rows indexed, rows now, stale, "
            "status (ready, stale, degraded, empty or orphaned) and generation. An empty list means no index has been built in this database.";

        t.push_back( ToolSpec{ "fractal_index_refresh", "Discovery", ToolClass::Expensive,
            { Str("name", true, "Index name.") }, std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonStrict( db.callScalar( "SELECT fractal_index_refresh(?)", { a.at("name").get<std::string>() } ) );
            } } );
        t.back().description = "Folds the rows added since the build into the index's cells, as a new generation switched in atomically, "
            "without retraining (the model is kept). Returns {name, added, rows, generation, refreshed}. Deleted rows and changed "
            "vectors are not touched: use fractal_index_rebuild when fractal_index_info advises a rebuild.";

        t.push_back( ToolSpec{ "fractal_index_ensure", "Discovery", ToolClass::Expensive,
            { Str("table_name", true, "Table the index covers."), Str("vector_col", true, "Embedding column."),
              Obj("options", false, "{name:string, vector_format:INT8|INT4|FP16|FP32=INT8, nlist:int, pca_dim:int, target_recall:number}: used only when an index is built or rebuilt") },
            std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object() ? a.at( "options" ).dump() : "{}";
                return parseJsonStrict( db.callScalar( "SELECT fractal_index_ensure(?, ?, ?)",
                    { a.at( "table_name" ).get<std::string>(), a.at( "vector_col" ).get<std::string>(), opts } ) );
            } } );
        t.back().description = "One call that leaves the index on table_name.vector_col fit to use, and changes nothing when it already is: builds it when none "
            "exists (action created), folds in the rows added since the build when that is all it needs (refreshed), rebuilds it when more than a quarter "
            "of the rows were added or more than a fifth deleted (rebuilt), and otherwise leaves it (unchanged: ready, empty, orphaned, or degraded with no new "
            "options). Returns {name, action, status, generation, rows}. Meant for a setup script or a scheduled job, never for a search.";

        t.push_back( ToolSpec{ "fractal_index_candidates", "Discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table the index covers."), Str("vector_col", true, "Embedding column."),
              Vec("query", true, "Query vector."),
              Obj("options", false, "{near:int=6, per_cell:int=1, index:string}") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                const std::string opts = a.contains( "options" ) && a.at( "options" ).is_object() ? a.at( "options" ).dump() : "{}";
                return Json{ { "candidates", parseJsonStrict( db.callScalar( "SELECT fractal_index_candidates(?, ?, ?, ?)",
                    { a.at( "table_name" ).get<std::string>(), a.at( "vector_col" ).get<std::string>(),
                      vectors::vectorParamToText( a.at( "query" ), "query" ), opts } ) ) } };
            } } );
        t.back().idempotentHint = true;
        t.back().description = "The rowids a Scout pass should look at: every row of the near nearest cells of the index plus per_cell representatives from "
            "the others, plus the rows newer than the index. A shortlist, not an answer: the distances are not computed here.";

        t.push_back( ToolSpec{ "fractal_hybrid_clinical_search", "Discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to scan."), Str("vector_col", true, "Embedding column."),
              Vec("query", true, "Query vector."),
              IntArray("doc_ids", true, "The cohort: rowid locators into table_name."),
              Int("k", false, "Neighbors to return.", 5), RowLimit() },
            std::nullopt, false, true,
            [&db, &rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                return annotatedRowsResult( db, "SELECT fractal_hybrid_clinical_search(?, ?, ?, ?, ?)",
                    { a.at("table_name").get<std::string>(), a.at("vector_col").get<std::string>(),
                      vectors::vectorParamToText( a.at("query"), "query" ),
                      vectors::intArrayToJsonText( a.at("doc_ids"), "doc_ids" ),
                      static_cast<std::int64_t>( bc.passed ) }, bc );
            } } );
        t.back().description = "Cohort-restricted sibling of fractal_search_telemetry: pass an explicit JSON array "
            "of rowid locators to restrict the scan before ranking. Errors 'doc_ids cohort matched no rows' on an "
            "empty cohort. doc_id/scan_pos semantics match fractal_search_telemetry, scan_pos counted within the "
            "cohort-filtered corpus.";

        t.push_back( ToolSpec{ "fractal_search_trajectory", "Discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to scan."), Str("vector_col", true, "Embedding column."),
              Vec("baseline_vector", true, "Baseline state vector."), Vec("current_vector", true, "Current state vector."),
              Int("k", false, "Neighbors to return.", 5), RowLimit() },
            std::nullopt, false, true,
            [&db, &rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                return annotatedRowsResult( db, "SELECT fractal_search_trajectory(?, ?, ?, ?, ?)",
                    { a.at("table_name").get<std::string>(), a.at("vector_col").get<std::string>(),
                      vectors::vectorParamToText( a.at("baseline_vector"), "baseline_vector" ),
                      vectors::vectorParamToText( a.at("current_vector"), "current_vector" ),
                      static_cast<std::int64_t>( bc.passed ) }, bc );
            } } );
        t.back().description = "Drift-vector search: finds the K nearest rows to (current_vector - baseline_vector) "
            ": 'what changed', not 'where am I'. Returns [{doc_id, distance}]. CAUTION: doc_id here is ALWAYS a "
            "0-indexed scan position, never a row locator.";

        t.push_back( ToolSpec{ "fractal_cross_modal_search", "Discovery", ToolClass::Cheap,
            { Str("table_name", true, "Table to scan."), Str("vector_col", true, "Embedding column."),
              Vec("morphology_vector", true, "Morphology modality vector."), Vec("clinical_vector", true, "Clinical modality vector."),
              Num("alpha_weight", true, "Weight given to the morphology vector, in [0,1]."),
              Int("k", false, "Neighbors to return.", 5), RowLimit() },
            std::nullopt, false, true,
            [&db, &rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 5, rowCfg );
                return annotatedRowsResult( db, "SELECT fractal_cross_modal_search(?, ?, ?, ?, ?, ?)",
                    { a.at("table_name").get<std::string>(), a.at("vector_col").get<std::string>(),
                      vectors::vectorParamToText( a.at("morphology_vector"), "morphology_vector" ),
                      vectors::vectorParamToText( a.at("clinical_vector"), "clinical_vector" ),
                      a.at("alpha_weight").get<double>(), static_cast<std::int64_t>( bc.passed ) }, bc );
            } } );
        t.back().description = "Weighted concatenation of two modality vectors (e.g. morphology + clinical) before "
            "the search: [morphology*alpha, clinical*(1-alpha)]. Returns [{doc_id, distance}]; doc_id is a "
            "0-indexed scan position, not a row locator.";

        t.push_back( ToolSpec{ "fractal_diversify_enable", "Discovery", ToolClass::Cheap, {}, std::nullopt, false, false,
            [&db]( const Json&, CallCtx& ) { return parseJsonLenient( db.callScalar( "SELECT fractal_diversify_enable()", {} ) ); } } );
        t.back().description = "Turns on the stateful Diversify/Repulsion layer for THIS session: searches then "
            "avoid the neighbourhoods of negative-reported results ('shadows'). Off by default; session-scoped.";
        t.back().idempotentHint = true;   // re-enabling an enabled session is a no-op

        t.push_back( ToolSpec{ "fractal_diversify_disable", "Discovery", ToolClass::Cheap, {}, std::nullopt, false, false,
            [&db]( const Json&, CallCtx& ) { return parseJsonLenient( db.callScalar( "SELECT fractal_diversify_disable()", {} ) ); } } );
        t.back().description = "Turns the Diversify/Repulsion layer back off for THIS session. "
            "fractal_agent_recommend_diverse leaves it ON; this is that tool's cleanup.";
        t.back().idempotentHint = true;

        t.push_back( ToolSpec{ "fractal_diversify_set_params", "Discovery", ToolClass::Cheap,
            { Int("window_n", false, "Diversify window size."), Num("stall_threshold", false, "Stall threshold."),
              Num("repulsion_sigma", false, "Repulsion sigma."), Num("repulsion_weight", false, "Repulsion weight."),
              Int("max_shadows_considered", false, "Max shadows considered."), Int("tail_buffer_cap", false, "Tail buffer cap.") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                Json body = Json::object();
                for( const char* k : { "window_n", "stall_threshold", "repulsion_sigma", "repulsion_weight",
                                        "max_shadows_considered", "tail_buffer_cap" } )
                    if( a.contains( k ) && !a.at( k ).is_null() ) body[ k ] = a.at( k );
                return parseJsonLenient( db.callScalar( "SELECT fractal_diversify_set_params(?)", { body.dump() } ) );
            } } );
        t.back().description = "Tunes the repulsion layer for THIS session. Every field optional; supplying only "
            "some keys keeps the core's current value for the rest. Takes effect on the next search.";

        t.push_back( ToolSpec{ "fractal_detect_collapse", "Discovery", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) { return parseJsonLenient( db.callScalar( "SELECT fractal_detect_collapse()", {} ) ); } } );
        t.back().description = "Current diversity quotient (D_q) for THIS session from the last search. Returns "
            "null when Diversify is off or nothing has searched yet.";

        t.push_back( ToolSpec{ "fractal_explain_result", "Discovery", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) { return parseJsonStrict( db.callScalar( "SELECT fractal_explain_result()", {} ) ); } } );
        t.back().description = "Session-level Diversify diagnostics JSON: {dq, diversify_enabled, overhead_p99_us}.";

        t.push_back( ToolSpec{ "fractal_feedback_report", "Discovery", ToolClass::Cheap,
            { Int("result_handle", true, "The scan_pos handle a prior search returned."),
              StrEnum("kind", true, "One of 'dwell', 'positive', 'negative'."),
              Int("dwell_ms", false, "Dwell time in milliseconds (omit for a bare negative/positive).") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                const std::string sql = a.contains("dwell_ms") && !a.at("dwell_ms").is_null()
                    ? "SELECT fractal_feedback_report(?, ?, ?)" : "SELECT fractal_feedback_report(?, ?)";
                std::vector<SqlValue> binds{ a.at("result_handle").get<std::int64_t>(), a.at("kind").get<std::string>() };
                if( a.contains("dwell_ms") && !a.at("dwell_ms").is_null() )
                    binds.push_back( a.at("dwell_ms").get<std::int64_t>() );
                return parseJsonLenient( db.callScalar( sql, binds ) );
            } } );
        t.back().description = "Reports dwell/positive/negative engagement on a prior search result, feeding the "
            "shadow store when Diversify is enabled. result_handle is the scan_pos the result came from, NOT its "
            "doc_id. kind must be 'dwell', 'positive' or 'negative'.";

        t.push_back( ToolSpec{ "fractal_isolate_background", "Discovery", ToolClass::Cheap,
            { Int("result_handle", true, "The scan_pos handle to reject outright.") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_isolate_background(?)",
                    { a.at("result_handle").get<std::int64_t>() } ) );
            } } );
        t.back().description = "Convenience wrapper for fractal_feedback_report(result_handle,'negative') with no "
            "dwell time: reject the result's neighbourhood outright.";

        return t;
    }
}