// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Admin/config tier (SQLite column): 4 tools, thin wrappers over
// the engine's per-connection fractal_config_set/fractal_config_get config surface.
// Per-connection, not global. Secrets (http_token, enterprise_ledger_key)
// are NEVER read back through any tool or resource; every successful
// config change is logged with redacted old + new values.
#include "admin.h"
#include "../db.h"
#include "../logging.h"
#include "../policy.h"
#include "../tool_param_helpers.h"
#include "../vectors.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdio>
#include <functional>
#include <string>

namespace fsqlmcp
{
    // The documented per-connection config surface (reasoning-setup.md,
    // text-to-sql-setup.md, vectorizer-setup.md, enterprise.md), minus the
    // derived internals fractal_config_get doesn't resolve.
    static const std::array<const char*, 17> kKnownKeys{
        "reasoning_plugin", "http_url", "http_model", "http_allow_plaintext",
        "http_embed_url", "http_embed_model", "http_think", "http_think_provider",
        "http_native_url", "http_num_ctx", "text_to_sql_max_attempts",
        "text_to_sql_allowed_statements", "text_to_sql_use_review",
        "enterprise_lib", "enterprise_ledger_key", "enterprise_require_signature",
        "agent_partial_reasoning_fail"
    };

    static bool isSecretKey( const std::string& k )
    { return k == "http_token" || k == "enterprise_ledger_key"; }

    static bool isEnterpriseKey( const std::string& k )
    {
        return k == "enterprise_lib" || k == "enterprise_require_signature" ||
               k == "enterprise_ledger_key";
    }

    static std::string redactedValue( const std::string& key, const std::string& value )
    { return isSecretKey( key ) ? std::string( "***" ) : value; }

    static std::string getConfigValue( Db& db, const std::string& key )
    {
        const auto t = asText( db.callScalar( "SELECT fractal_config_get(?)", { key } ) );
        return t.value_or( "null" );
    }

    // A short, non-reversible tag of the calling client, for the refusal
    // log: enough to tell two clients apart in an incident, never the
    // credential itself.
    static std::string clientTag( const std::string& clientKey )
    {
        if( clientKey.empty() ) return std::string();
        char buf[ 24 ];
        std::snprintf( buf, sizeof buf, "c-%08zx",
                       std::hash<std::string>{}( clientKey ) & 0xffffffffu );
        return buf;
    }

    // The config-writes switch. off: no key may be written through the MCP
    // boundary. safe (the default): only the low-risk keys -- the model
    // names and the think mode -- may be; every other key is refused,
    // including one this build does not know about. all: every key may be
    // (the enterprise keys still need their own per-call consent).
    //
    // The refusal names the key, says what it is set to now, and says where
    // to set it instead: the operator's own configuration, not a tool call a
    // model can make.
    static void refuseConfigWrite( Db& db, const std::string& key, const CallCtx& ctx )
    {
        const std::string current = redactedValue( key, getConfigValue( db, key ) );
        logging::event( "config_write_refused", Json{
            { "key", key },
            { "mode", configWritesModeName() },
            { "client", clientTag( ctx.clientKey ) } } );
        throw ToolError( ErrorClass::Schema,
            "config write refused: '" + key + "' may not be written through this tool while "
            "FSQL_MCP_CONFIG_WRITES=" + std::string( configWritesModeName() ) + ". The safe set is the "
            "chat model name (http_model), the embedding model name (http_embed_model) and the think mode "
            "(http_think); the endpoint URLs, the plaintext flag, the plugin path, the token and the "
            "enterprise keys are not in it. '" + key + "' is currently set to '" + current + "'. Set it in "
            "the server's own configuration -- the bootstrap snippet (FRACTALSQL_BOOTSTRAP_SQL) or the "
            "engine's configuration file -- instead of through this tool, or run the server with "
            "FSQL_MCP_CONFIG_WRITES=all if you really want this tool to write it." );
    }

    // A soft, once-per-process warning carrying the risk statement: the
    // documented admin/operator two-account split is advisory, since SQLite
    // has no role model to check against.
    static void adminSoftWarning()
    {
        static std::atomic<bool> warned{ false };
        if( !warned.exchange( true ) )
            logging::event( "admin_tool_class_warning", Json{
                { "level", "info" },
                { "note", "admin/config tools are running on the same "
                          "connection as ordinary tool traffic; the docs "
                          "recommend a separately-scoped account/connection "
                          "for admin tools in production (SQLite has no "
                          "in-engine role model; bound the database file "
                          "instead)" } } );
    }

    static const char* const kScope =
        "per-connection (THIS MCP session's dedicated SQLite connection only: "
        "fractal_config_set state does not survive connections, and another MCP "
        "client on the same database file inherits nothing)";

    std::vector<ToolSpec> buildAdminTools( Db& db )
    {
        std::vector<ToolSpec> t;

        t.push_back( ToolSpec{ "fractal_version", "Admin", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                return Json{ { "version", asScalarJson( db.callScalar( "SELECT fractal_version()", {} ) ) },
                             { "edition", asScalarJson( db.callScalar( "SELECT fractal_edition()", {} ) ) } };
            } } );
        t.back().description = "Confirms the FractalSQL install is alive and which edition (Community/Enterprise) "
            "is active: calls fractal_version() and fractal_edition(). The one-line sanity check after "
            "installing; expect a real edition/version back (e.g. Community|2.0.13), plus a startup warning if "
            "the engine version differs from what this plugin was built against (the version-skew guard warns, "
            "never hard-fails).";

        t.push_back( ToolSpec{ "fractal_config_set", "Admin", ToolClass::Cheap,
            { StrEnum( "key", true, "One of the documented per-connection config keys (enforced: reasoning_plugin, "
                                    "http_url, http_model, http_allow_plaintext, http_embed_url, "
                                    "http_embed_model, http_think, http_think_provider, http_native_url, "
                                    "http_num_ctx, text_to_sql_max_attempts, text_to_sql_allowed_statements, "
                                    "text_to_sql_use_review, enterprise_lib, enterprise_ledger_key, "
                                    "enterprise_require_signature, agent_partial_reasoning_fail)." ),
              Str("value", true, "The value to set (engine-side type coercion applies)."),
              Bool_("allow_secrets", false,
                    "Must be true to set an enterprise-posture key (enterprise_lib, "
                    "enterprise_require_signature, enterprise_ledger_key) through the MCP boundary: an "
                    "explicit operator intent, never a default.", false) },
            std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ctx ) {
                adminSoftWarning();
                const std::string key = a.at( "key" ).get<std::string>();
                if( isEnterpriseKey( key ) && !a.value( "allow_secrets", false ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + key + "' changes the enterprise tier's library/signature/key "
                        "posture: pass allow_secrets=true to make "
                        "the operator's explicit intent explicit; a client UI "
                        "prompts a human first for these destructive changes" );
                if( std::find_if( kKnownKeys.begin(), kKnownKeys.end(),
                                  [&]( const char* k ) { return key == k; } ) == kKnownKeys.end() )
                    throw ToolError( ErrorClass::Schema,
                        "unknown config key '" + key + "': fractal_config_set accepts the "
                        "documented per-connection keys (reasoning_plugin, http_url, "
                        "http_model, http_allow_plaintext, http_embed_url, "
                        "http_embed_model, http_think, http_think_provider, "
                        "http_native_url, http_num_ctx, text_to_sql_max_attempts, "
                        "text_to_sql_allowed_statements, text_to_sql_use_review, "
                        "enterprise_lib, enterprise_ledger_key, "
                        "enterprise_require_signature, agent_partial_reasoning_fail); "
                        "the fractalsql.-prefixed "
                        "spelling is accepted by the engine too" );
                // The config-writes switch: a key the current mode does not
                // allow is refused before anything is changed.
                if( !configWriteAllowed( key ) )
                    refuseConfigWrite( db, key, ctx );
                const std::string oldVal = getConfigValue( db, key );
                const std::string newVal = a.at( "value" ).get<std::string>();
                const SqlValue setResult = db.callScalar( "SELECT fractal_config_set(?, ?)", { key, newVal } );
                // Every successful admin-config call is logged with old and
                // new value, so a silent endpoint swap (http_url repointed at an
                // attacker endpoint, where every subsequent reasoning call sends
                // prompts and embeddings) is catchable after the fact even if no
                // one watched it live. Secret values are redacted in the log.
                logging::configChange( key, redactedValue( key, oldVal ), redactedValue( key, newVal ) );
                return Json{ { "key", key },
                             { "old", isSecretKey( key ) ? "***" : oldVal },
                             { "new", newVal },
                             { "scope", kScope },
                             { "result", parseJsonLenient( setResult ) } };
            } } );
        t.back().description = "Sets a per-connection config key to a value: the SQLite column's wrapper over "
            "fractal_config_set(key, value) for the documented keys (reasoning plugin path, http_url/http_embed_url, "
            "models, think knobs, text-to-sql keys, enterprise keys). Operates on THIS MCP session's dedicated "
            "connection only. destructiveHint-flagged: repointing http_url/http_embed_url silently redirects every "
            "subsequent reasoning/embedding call, and the enterprise keys change the tier/signature "
            "posture; a client UI that honors annotations will prompt a human first.";
        t.back().secretHint = true;   // touches credential-shaped values

        t.push_back( ToolSpec{ "fractal_config_get", "Admin", ToolClass::Cheap,
            { Str("key", true, "Config key to read back.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                const std::string key = a.at( "key" ).get<std::string>();
                if( isSecretKey( key ) )
                    throw ToolError( ErrorClass::Schema,
                        "'" + key + "' is a secret and is never read back through any "
                        "MCP tool or resource; "
                        "check the bootstrap snippet that set it instead" );
                return Json{ { "key", key },
                             { "value", asScalarJson( db.callScalar( "SELECT fractal_config_get(?)", { key } ) ) },
                             { "scope", "per-connection (THIS MCP session's dedicated connection)" } };
            } } );
        t.back().description = "Reads back a config key's resolved value on THIS session's connection (the SQLite "
            "column's wrapper over fractal_config_get). Secrets (http_token, enterprise_ledger_key) are refused; "
            "they are never read back through any tool or resource.";

        t.push_back( ToolSpec{ "fractal_configure_reasoning", "Admin", ToolClass::Cheap,
            { Str("provider_url", false, "Chat endpoint URL (e.g. http://127.0.0.1:11434/v1/chat/completions for ollama, or an OpenAI-compatible /v1/chat/completions)."),
              Str("embed_url", false, "Embeddings endpoint URL (e.g. .../v1/embeddings); a distinct path from chat."),
              Str("model", false, "Chat model name (e.g. gpt-oss:20b, gpt-4o-mini)."),
              Str("embed_model", false, "Embedding model name (e.g. nomic-embed-text); never reuse a chat model here."),
              ToolParam{ "allow_plaintext", JsonType::Boolean, false, nullptr,
                         "Allow plaintext http:// endpoints (needed for local Ollama).", false },
              Str("think_mode", false, "Reasoning effort for hybrid-thinker models: unset/none (model default), 'off', or any provider-verbatim value (low/medium/high/...).") },
            std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ctx ) {
                adminSoftWarning();
                static const std::vector<std::pair<const char*, const char*>> kFieldMap{
                    { "provider_url", "http_url" }, { "embed_url", "http_embed_url" },
                    { "model", "http_model" }, { "embed_model", "http_embed_model" },
                    { "allow_plaintext", "http_allow_plaintext" }, { "think_mode", "http_think" }
                };
                // Collect first, apply second: a call that names a key the
                // config-writes switch refuses changes nothing at all.
                std::vector<std::pair<std::string, std::string>> pending;
                for( const auto& kv : kFieldMap )
                {
                    if( !a.contains( kv.first ) || a.at( kv.first ).is_null() ) continue;
                    const std::string newVal = std::string( kv.first ) == "allow_plaintext"
                        ? std::string( a.at( kv.first ).get<bool>() ? "on" : "off" )   // CFG_BOOL engine-side spelling
                        : a.at( kv.first ).get<std::string>();
                    pending.emplace_back( kv.second, newVal );
                }
                if( pending.empty() )
                    throw ToolError( ErrorClass::Schema,
                        "nothing to set: pass at least one of provider_url, "
                        "embed_url, model, embed_model, allow_plaintext, think_mode" );
                for( const auto& p : pending )
                    if( !configWriteAllowed( p.first ) )
                        refuseConfigWrite( db, p.first, ctx );
                Json applied = Json::object();
                for( const auto& p : pending )
                {
                    const std::string oldVal = getConfigValue( db, p.first );
                    db.callScalar( "SELECT fractal_config_set(?, ?)", { p.first, p.second } );
                    logging::configChange( p.first, redactedValue( p.first, oldVal ),
                                           redactedValue( p.first, p.second ) );
                    applied[ p.first ] = Json{ { "old", oldVal }, { "new", p.second } };
                }
                return Json{ { "applied", applied }, { "scope", kScope },
                    { "note", "this tool never touches the reasoning provider token "
                              "(http_token) or any enterprise key: the "
                              "token lives in your bootstrap snippet, and "
                              "enterprise-tier config is an operator action." } };
            } } );
        t.back().description = "Configure the reasoning/embedding provider: one unified tool shaped identically "
            "across the engine plugins, adapter-translated underneath (there: GUCs or fsqlctl; on SQLite: the "
            "equivalent fractal_config_set(key, value) calls on this session's connection, in effect immediately; "
            "no reload exists). NEVER touches http_token or any enterprise key on any engine; the token belongs "
            "in your bootstrap snippet, encrypted at rest like a credential. destructiveHint-flagged: repointing "
            "the provider URL silently redirects every subsequent reasoning call; old/new values of "
            "whatever changed are logged.";
        t.back().secretHint = true;

        return t;
    }
}