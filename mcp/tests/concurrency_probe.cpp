// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// Standalone unit-test probe for mcp/src/concurrency.h's ConcurrencyManager/
// BoundedSemaphore/Token. concurrency.h is header-only (every method inline,
// no concurrency.cpp of its own), so -- like gate 41's db_probe.cpp sibling --
// this probe's own translation unit is the only place its coverage data
// exists at all.
//
// The remaining branches here (per-client-limit-reached throw, global-
// timeout throw, and the Token-destructor release paths each of those
// throws takes on the way out) do NOT need real concurrent threads to
// reach: ConcurrencyManager's limits are plain mutex-guarded counters, and
// Token is a move-only RAII handle. Acquiring Tokens sequentially and
// holding them alive (not letting them go out of scope) saturates the same
// counters a second overlapping thread would -- so a single thread that
// holds a Token open while calling acquire() again exercises the exact
// same "limit already reached" branches, deterministically, with no
// timing dependency at all. Only cfg_.maxQueueWaitMs needs to be small
// (not zero -- tryAcquire's own wait_for must still run its real timeout
// path) to keep this probe fast.
#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <utility>
#include <vector>
#include "concurrency.h"

using fsqlmcp::ConcurrencyConfig;
using fsqlmcp::ConcurrencyManager;
using fsqlmcp::ToolClass;
using fsqlmcp::ToolError;

static int g_ok = 0;

static void check( bool cond, const char* what )
{
    if( !cond )
    {
        std::fprintf( stderr, "FAIL: %s\n", what );
        std::exit( 1 );
    }
    ++g_ok;
}

template <typename Fn>
static bool threw( Fn&& fn, const char* expectSubstr )
{
    try
    {
        fn();
        return false;
    }
    catch( const ToolError& e )
    {
        std::string msg = e.what();
        return msg.find( expectSubstr ) != std::string::npos;
    }
}

int main()
{
    // --- Cheap-tier: plain success path (baseline, already covered by live
    // traffic, kept here as a sanity check the probe itself is wired right).
    {
        ConcurrencyConfig cfg;
        cfg.cheapLimit = 2;
        ConcurrencyManager mgr( cfg );
        auto tok = mgr.acquire( ToolClass::Cheap, "client-cheap" );
        check( true, "cheap acquire succeeds" );
        // tok destructs here: Token::release() with heldGlobal_=true,
        // heldClient_=false (cheap tier never touches the per-client map) --
        // exercises BoundedSemaphore::release()'s normal inUse_>0 path.
    }

    // --- Per-client expensive limit reached (line 99/101's throw, never
    // executed by any live-protocol test: it needs a SECOND expensive call
    // from the SAME client while the per-client slot is still held).
    {
        ConcurrencyConfig cfg;
        cfg.expensiveLimit = 10;           // global limit not the bottleneck here
        cfg.expensivePerClient = 1;
        cfg.maxQueueWaitMs = 50;
        ConcurrencyManager mgr( cfg );
        auto held = mgr.acquire( ToolClass::Expensive, "client-a" );
        bool gotClientLimit = threw(
            [&] { auto tok2 = mgr.acquire( ToolClass::Expensive, "client-a" ); },
            "per-client expensive-tier concurrency limit reached" );
        check( gotClientLimit, "second expensive call from same client hits the per-client limit" );
        // The failed acquire()'s local `tok` (never returned, since the
        // throw happens before acquireClientSlot even runs) destructs with
        // mgr_ set but heldClient_=false, heldGlobal_=false -- exercises
        // Token::release()'s `if(heldGlobal_)` FALSE branch (line 81) and
        // the `if(!mgr_) return;` TRUE-mgr_ branch (line 79) together.
    }

    // --- Global expensive-tier timeout (line 105/107/108's throw: needs
    // the global semaphore already saturated by a DIFFERENT client so the
    // per-client slot check passes but the global tryAcquire times out).
    {
        ConcurrencyConfig cfg;
        cfg.expensiveLimit = 1;
        cfg.expensivePerClient = 5;
        cfg.maxQueueWaitMs = 50;            // small: keeps this probe fast
        ConcurrencyManager mgr( cfg );
        auto held = mgr.acquire( ToolClass::Expensive, "client-holder" );
        bool gotGlobalLimit = threw(
            [&] { auto tok2 = mgr.acquire( ToolClass::Expensive, "client-other" ); },
            "server busy: concurrency limit reached" );
        check( gotGlobalLimit, "a second client's expensive call times out on the saturated global slot" );
        // This throw path explicitly calls releaseClient() itself (line 107)
        // before throwing -- exercises clientCounts_'s it->second>0 TRUE
        // branch a second, independent way (via the manual release-on-
        // failure path rather than Token::release()'s own).
    }

    // --- Sequential reuse: release the holder, then confirm a fresh
    // acquire for the same client succeeds again (the per-client slot
    // really was given back, not leaked) -- exercises clientCounts_'s
    // it!=end() TRUE branch via a second, later release of the same key.
    {
        ConcurrencyConfig cfg;
        cfg.expensiveLimit = 1;
        cfg.expensivePerClient = 1;
        cfg.maxQueueWaitMs = 50;
        ConcurrencyManager mgr( cfg );
        {
            auto tok = mgr.acquire( ToolClass::Expensive, "client-reuse" );
        }   // released here
        auto tok2 = mgr.acquire( ToolClass::Expensive, "client-reuse" );
        check( true, "the same client can re-acquire after its prior token released" );
    }

    std::fprintf( stderr, "concurrency_probe: %d checks passed\n", g_ok );
    return 0;
}
