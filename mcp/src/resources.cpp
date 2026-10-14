// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "resources.h"
#include "db.h"
#include "errors.h"
#include "logging.h"
#include <array>

namespace fsqlmcp
{
    static Db* g_db = nullptr;
    void Resources::init( Db* db ) { g_db = db; }

    // _CONFIG_KEYS: the documented, NON-SECRET config surface. BOTH secrets
    // (http_token, enterprise_ledger_key) are deliberately absent.
    static const std::array<const char*, 15> kConfigKeys{
        "reasoning_plugin", "http_url", "http_model", "http_allow_plaintext",
        "http_embed_url", "http_embed_model", "http_think", "http_think_provider",
        "http_native_url", "http_num_ctx", "text_to_sql_max_attempts",
        "text_to_sql_allowed_statements", "text_to_sql_use_review",
        "enterprise_lib", "enterprise_require_signature"
    };

    static Json contents( const std::string& uri, const std::string& mime, const std::string& text )
    {
        return Json{ { "contents", Json::array( { Json{
            { "uri", uri }, { "mimeType", mime }, { "text", text } } } ) } };
    }

    Json Resources::list()
    {
        return Json{ { "resources", Json::array( {
            Json{ { "uri", "fractalsql://schema" }, { "name", "Schema context" },
                  { "description",
                    "fractal_schema_context()'s own output, live (not cached): the "
                    "plain-text schema description a reasoning call sees. Read it "
                    "before composing a fractal_text_to_sql / fractal_sql_agent "
                    "call, exactly the way the install docs recommend auditing it "
                    "first. Auto-discovery pulls every table; SQLite has no per-"
                    "role grants to hide a table from discovery." },
                  { "mimeType", "text/plain" } },
            Json{ { "uri", "fractalsql://config" }, { "name", "Resolved config (non-secret)" },
                  { "description",
                    "The resolved, non-secret subset of the reasoning / "
                    "text-to-sql / enterprise config surface for THIS session's "
                    "connection. NEVER the reasoning token or the ledger HMAC key "
                    "(those are secrets and are never read back through any "
                    "resource or tool)." },
                  { "mimeType", "application/json" } },
            Json{ { "uri", "fractalsql://ledger/1" },
                  { "name", "Ledger verify report (kind=1, QTL chain)" },
                  { "description",
                    "fractal_ledger_verify(1)'s own JSON audit report, exposed as "
                    "a resource so a periodic-context-refresh flow can pull the "
                    "CISO audit state the same way it pulls the schema. Returns "
                    "the clean 'enterprise tier not loaded' condition on "
                    "Community, same as the tool." },
                  { "mimeType", "application/json" } },
            Json{ { "uri", "fractalsql://ledger/2" },
                  { "name", "Ledger verify report (kind=2, decision-audit chain)" },
                  { "description",
                    "fractal_ledger_verify(2): the general decision-audit chain "
                    "walk (O(n)), same contract as fractalsql://ledger/1." },
                  { "mimeType", "application/json" } },
            Json{ { "uri", "fractalsql://vectorizer/status" }, { "name", "Vectorizer status" },
                  { "description",
                    "The fractal_vectorizer_status view's contents (one row per "
                    "vectorizer_id + status pair, with counts and most-recent "
                    "failure detail): a resource rather than a tool since it is "
                    "pure monitoring state with no arguments. NOTE: the "
                    "registry/queue are TEMP objects on THIS session's connection." },
                  { "mimeType", "application/json" } },
            Json{ { "uri", "fractalsql://agents" }, { "name", "Agent catalog" },
                  { "description",
                    "Static, generated-from-docs catalog: the full 'which agent "
                    "should I use' decision table api-agency.md ships, so a client "
                    "can pull the whole picture in one resource read instead of "
                    "parsing sixteen tool descriptions." },
                  { "mimeType", "application/json" } },
        } ) } };
    }

    Json Resources::read( const std::string& uri )
    {
        if( !g_db )
            throw ToolError( ErrorClass::ServerInternal, "resource layer used before init" );

        if( uri == "fractalsql://schema" )
        {
            const SqlValue v = g_db->callScalar( "SELECT fractal_schema_context()", {} );
            const auto t = asText( v );
            return contents( uri, "text/plain", t.value_or( "" ) );
        }

        if( uri == "fractalsql://config" )
        {
            Json cfg = Json::object();
            for( const char* key : kConfigKeys )
            {
                const SqlValue v = g_db->callScalar( "SELECT fractalsql_get(?)", { std::string( key ) } );
                cfg[ key ] = asScalarJson( v );
            }
            const Json body{ { "scope", "per-connection (THIS MCP session's dedicated connection)" },
                             { "config", cfg },
                             { "secrets", "http_token and enterprise_ledger_key are secrets and "
                                          "are never read back through any resource or tool" } };
            return contents( uri, "application/json", body.dump( 2 ) );
        }

        if( uri == "fractalsql://agents" )
        {
            // Static catalog mirroring 2.3's 16 installable agents: the AGENTS_
            // CATALOG table (problem / agent / recipe), one entry per agent,
            // same content and order as the resource-shaped table in the docs.
            static const Json kAgents{ {
                "agents", Json::array( {
                    Json{ { "problem", "Is this entity's metric series drifting into a new regime? (table-backed)" },
                          { "agent", "fractal_agent_anomaly_triage" },
                          { "recipe", "drift exponent on one entity's series -> LLM triage" } },
                    Json{ { "problem", "Is this single series in a regime change? (array-in, no table)" },
                          { "agent", "fractal_agent_regime_triage" },
                          { "recipe", "DFA + drift over one series -> LLM triage" } },
                    Json{ { "problem", "Did this vessel/host track deviate from the fleet?" },
                          { "agent", "fractal_agent_track_anomaly" },
                          { "recipe", "trajectory deviation + heading DFA -> LLM triage" } },
                    Json{ { "problem", "Did this vehicle detour, and how complex is its GPS trace?" },
                          { "agent", "fractal_agent_detour_classify" },
                          { "recipe", "trajectory deviation + box-counting -> LLM classify" } },
                    Json{ { "problem", "Is my sensor grid's coverage degrading?" },
                          { "agent", "fractal_agent_network_coverage_alert" },
                          { "recipe", "spatial morphology + telemetry drift -> LLM alert" } },
                    Json{ { "problem", "What's the best cardinality-constrained allocation?" },
                          { "agent", "fractal_agent_allocate" },
                          { "recipe", "SFS Sharpe optimizer -> LLM rationale" } },
                    Json{ { "problem", "Rebalance, and compare to the nearest historical allocation?" },
                          { "agent", "fractal_agent_rebalance_sibling" },
                          { "recipe", "optimizer + trajectory search -> LLM rationale" } },
                    Json{ { "problem", "Give me several distinct good portfolios, not just one? (enterprise)" },
                          { "agent", "fractal_agent_diverse_portfolios" },
                          { "recipe", "multimodal optimizer -> LLM tradeoff summary" } },
                    Json{ { "problem", "Which sub-agent should handle this incoming task?" },
                          { "agent", "fractal_agent_route_task" },
                          { "recipe", "nearest-capability search + budget accounting -> LLM rationale" } },
                    Json{ { "problem", "Which node should this workload land on (with vector refinement)?" },
                          { "agent", "fractal_agent_schedule_workload" },
                          { "recipe", "fractal_search refine + nearest node -> LLM rationale" } },
                    Json{ { "problem", "Should I block this proposed action (is it near a known-bad state)?" },
                          { "agent", "fractal_agent_outlier_intercept" },
                          { "recipe", "distance-to-bad-state safety barrier -> LLM justification" } },
                    Json{ { "problem", "Triage a patient against a cohort + baseline->current drift" },
                          { "agent", "fractal_agent_patient_deterioration_triage" },
                          { "recipe", "cohort search + trajectory drift -> LLM triage" } },
                    Json{ { "problem", "Ask a natural-language question over my tables" },
                          { "agent", "fractal_agent_data_analyst" },
                          { "recipe", "NL->SQL->execute -> LLM analysis" } },
                    Json{ { "problem", "Recall similar past memories, restricted by a metadata filter" },
                          { "agent", "fractal_agent_recall_hybrid" },
                          { "recipe", "cohort-restricted vector recall (no LLM)" } },
                    Json{ { "problem", "Recommend diverse items, avoiding recently-rejected ones" },
                          { "agent", "fractal_agent_recommend_diverse" },
                          { "recipe", "repulsion-diverse top-k (no LLM)" } },
                    Json{ { "problem", "Audit my recommender's diversity health" },
                          { "agent", "fractal_agent_feedback_audit" },
                          { "recipe", "diversify loop + collapse detection (no LLM, self-disables)" } },
                } )
            } };
            return contents( uri, "application/json", kAgents.dump( 2 ) );
        }

        if( uri.rfind( "fractalsql://ledger/", 0 ) == 0 )
        {
            const std::string kindStr = uri.substr( std::string( "fractalsql://ledger/" ).size() );
            long kind = 0;
            try
            {
                std::size_t used = 0;
                kind = std::stol( kindStr, &used );
                if( used != kindStr.size() ) throw std::invalid_argument( "trailing" );
            }
            catch( ... )
            {
                throw ToolError( ErrorClass::Schema, "invalid ledger kind '" + kindStr + "' (1 or 2)" );
            }
            const SqlValue v = g_db->callScalar( "SELECT fractal_ledger_verify(?)",
                                                 { static_cast<std::int64_t>( kind ) } );
            const auto t = asText( v );
            return contents( uri, "application/json", t.value_or( "null" ) );
        }

        if( uri == "fractalsql://vectorizer/status" )
        {
            // fractal_vectorizer_status is a VIEW, not a function; read the
            // live rows off this session's connection and json-encode them.
            // The registry/queue are TEMP objects scoped to the connection
            // that created a vectorizer; on a fresh session the view is
            // absent, and the engine's own message (verbatim, 1.6) carries
            // that. Same error shape + class the Python reference used.
            try
            {
                const std::vector<std::string> names = g_db->columnNames( "SELECT * FROM fractal_vectorizer_status" );
                const std::vector<std::vector<SqlValue>> rows =
                    g_db->queryAll( "SELECT * FROM fractal_vectorizer_status", {} );
                Json arr = Json::array();
                for( const auto& row : rows )
                {
                    Json obj = Json::object();
                    for( std::size_t c = 0; c < row.size() && c < names.size(); ++c )
                        obj[ names[ c ] ] = asScalarJson( row[ c ] );
                    arr.push_back( std::move( obj ) );
                }
                return contents( uri, "application/json", arr.dump( 2 ) );
            }
            catch( const ToolError& e )
            {
                if( e.errorClass == ErrorClass::Engine )
                    throw ToolError( ErrorClass::Schema,
                        "fractal_vectorizer_status is empty on this connection; the "
                        "vectorizer registry/queue are TEMP objects scoped to the "
                        "connection that created one (create a vectorizer on this "
                        "session first). Underlying engine note: " + e.message );
                throw;
            }
        }

        throw ToolError( ErrorClass::Schema, "unknown resource uri '" + uri + "'" );
    }
}