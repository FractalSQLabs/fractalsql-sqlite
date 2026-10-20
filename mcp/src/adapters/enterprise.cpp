// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Enterprise/ledger tier: 10 tools, all gated. On a Community
// install the engine itself returns the clean "enterprise tier not loaded"
// error the tools' descriptions promise; the server only surfaces it.
#include "enterprise.h"
#include "../db.h"
#include "../tool_param_helpers.h"
#include "../vectors.h"
#include <string>

namespace fsqlmcp
{
    static const char* const kEnterprise =
        " Enterprise tier: returns a clean 'enterprise tier not loaded' error on a Community install.";

    std::vector<ToolSpec> buildEnterpriseTools( Db& db )
    {
        std::vector<ToolSpec> t;

        t.push_back( ToolSpec{ "fractal_ledger_flush", "Enterprise", ToolClass::Cheap, {}, std::nullopt, true, false,
            [&db]( const Json&, CallCtx& ) { return parseJsonLenient( db.callScalar( "SELECT fractal_ledger_flush()", {} ) ); } } );
        t.back().description = std::string( "Encodes the truth+shadow ledgers into a QTL blob, appends it to the "
            "tamper-evident hash chain. A rewritten row breaks the chain; a deleted row leaves a visible id gap." )
            + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_load", "Enterprise", ToolClass::Cheap, {}, std::nullopt, false, false,
            [&db]( const Json&, CallCtx& ) { return parseJsonLenient( db.callScalar( "SELECT fractal_ledger_load()", {} ) ); } } );
        t.back().description = std::string( "Hydrates in-memory ledgers from the chain's latest entry (tip-only, "
            "O(1)). On an integrity failure, diversify is auto-disabled and ledgers left empty." ) + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_verify", "Enterprise", ToolClass::Cheap,
            { Int("kind", false, "1=QTL chain, 2=decision-audit chain.", 1) }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonStrict( db.callScalar( "SELECT fractal_ledger_verify(?)", { a.value( "kind", 1 ) } ) );
            } } );
        t.back().description = "Walks the ENTIRE chain for the given kind (O(n)). Returns "
            "{'ok':true,'rows_verified':N} or {'ok':false,'first_failure_id':ID,'reason':...}. Pure read-only "
            "forensic query; works even with NO enterprise library loaded, so a CISO audit never needs a license.";

        t.push_back( ToolSpec{ "fractal_ledger_compact", "Enterprise", ToolClass::Cheap, {}, std::nullopt, true, false,
            [&db]( const Json&, CallCtx& ) { return parseJsonLenient( db.callScalar( "SELECT fractal_ledger_compact()", {} ) ); } } );
        t.back().description = std::string( "Defragments/re-packs the in-memory QTL representation. Normally runs "
            "lazily on flush; exposed for a predictable pause." ) + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_reset_soft", "Enterprise", ToolClass::Cheap, {}, std::nullopt, true, false,
            [&db]( const Json&, CallCtx& ) { return parseJsonLenient( db.callScalar( "SELECT fractal_ledger_reset_soft()", {} ) ); } } );
        t.back().description = std::string( "Soft-reset: clears the Shadow Ledger only (truth ledger and current "
            "epoch preserved, diversify state reseeded)." ) + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_reset_hard", "Enterprise", ToolClass::Cheap, {}, std::nullopt, true, false,
            [&db]( const Json&, CallCtx& ) { return parseJsonLenient( db.callScalar( "SELECT fractal_ledger_reset_hard()", {} ) ); } } );
        t.back().description = std::string( "DESTRUCTIVE AND IRREVERSIBLE: hard-reset empties the ledgers "
            "completely (Truth + Shadow, epoch counter back to 1). No key rotation happens here." ) + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_truth_count", "Enterprise", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                return Json{ { "count", asScalarJson( db.callScalar( "SELECT fractal_ledger_truth_count()", {} ) ) } };
            } } );
        t.back().description = std::string( "Truth-side ledger entry count." ) + kEnterprise;

        t.push_back( ToolSpec{ "fractal_ledger_shadow_count", "Enterprise", ToolClass::Cheap, {}, std::nullopt, false, true,
            [&db]( const Json&, CallCtx& ) {
                return Json{ { "count", asScalarJson( db.callScalar( "SELECT fractal_ledger_shadow_count()", {} ) ) } };
            } } );
        t.back().description = std::string( "Shadow-side ledger entry count." ) + kEnterprise;

        t.push_back( ToolSpec{ "fractal_audit_unpack", "Enterprise", ToolClass::Cheap,
            { Str("blob", true, "Hex-encoded QTL blob.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonStrict( db.callScalar( "SELECT fractal_audit_unpack(?)",
                    { vectors::hexToBytes( a.at( "blob" ).get<std::string>(), "blob" ) } ) );
            } } );
        t.back().description = std::string( "Decodes a persisted QTL blob into its audit JSON: one "
            "{'epoch','doc_id','signal':'truth'|'shadow'|'neutral'} entry per ledger record, a top-level array." )
            + kEnterprise;

        t.push_back( ToolSpec{ "fractal_audit_log", "Enterprise", ToolClass::Cheap,
            { Str("entry_type", true, "Decision-audit entry type."),
              Str("payload", true, "Payload, stored verbatim (SQLite has no jsonb).") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_audit_log(?, ?)",
                    { a.at( "entry_type" ).get<std::string>(), a.at( "payload" ).get<std::string>() } ) );
            } } );
        t.back().description = std::string( "General decision-audit append to the kind=2 chain: every "
            "decision-making agent logs here automatically when enterprise is active; exposed directly too for "
            "custom provenance records." ) + kEnterprise;

        return t;
    }
}