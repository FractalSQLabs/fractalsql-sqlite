// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <condition_variable>
#include <map>
#include <mutex>
#include <string>
#include "errors.h"
#include "tool_registry.h"
#include "logging.h"

namespace fsqlmcp
{
    struct ConcurrencyConfig
    {
        int cheapLimit         = 50;      // FSQL_MCP_MAX_CONCURRENT_CHEAP
        int expensiveLimit     = 5;       // FSQL_MCP_MAX_CONCURRENT_EXPENSIVE
        int expensivePerClient = 2;       // FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT
        int maxQueueWaitMs     = 900'000; // FSQL_MCP_MAX_QUEUE_WAIT_MS
    };

    // Bounded counting semaphore over std::mutex/condition_variable: a
    // textbook primitive.
    class BoundedSemaphore
    {
    public:
        explicit BoundedSemaphore( int limit ) : limit_( limit ), inUse_( 0 ) {}

        bool tryAcquire( int waitMs )
        {
            std::unique_lock<std::mutex> lk( mu_ );
            if( !cv_.wait_for( lk, std::chrono::milliseconds( waitMs ),
                                [&] { return inUse_ < limit_; } ) )
                return false;
            ++inUse_;
            return true;
        }
        void release()
        {
            std::lock_guard<std::mutex> lk( mu_ );
            if( inUse_ > 0 ) --inUse_;
            cv_.notify_one();
        }
    private:
        std::mutex mu_;
        std::condition_variable cv_;
        int limit_, inUse_;
    };

    class ConcurrencyManager
    {
    public:
        explicit ConcurrencyManager( ConcurrencyConfig cfg )
            : cfg_( cfg ), cheap_( cfg.cheapLimit ), expensive_( cfg.expensiveLimit )
        {
        }

        // RAII token: acquire-order is per-client slot FIRST, then the global
        // expensive slot. Release on any throw path is automatic; the
        // destructor does the unwinding a hand-coded acquire-order
        // try/except would need.
        class Token
        {
        public:
            Token() = default;
            Token( Token&& o ) noexcept { *this = std::move( o ); }
            Token& operator=( Token&& o ) noexcept
            {
                release();
                mgr_ = o.mgr_; cls_ = o.cls_; client_ = std::move( o.client_ );
                heldGlobal_ = o.heldGlobal_; heldClient_ = o.heldClient_;
                o.mgr_ = nullptr; o.heldGlobal_ = o.heldClient_ = false;
                return *this;
            }
            ~Token() { release(); }
            void release()
            {
                if( !mgr_ ) return;
                if( heldClient_ ) mgr_->releaseClient( client_ );
                if( heldGlobal_ ) ( cls_ == ToolClass::Cheap ? mgr_->cheap_ : mgr_->expensive_ ).release();
                mgr_ = nullptr;
            }
        private:
            friend class ConcurrencyManager;
            ConcurrencyManager* mgr_ = nullptr;
            ToolClass   cls_ = ToolClass::Cheap;
            std::string client_;
            bool heldGlobal_ = false, heldClient_ = false;
        };

        Token acquire( ToolClass cls, const std::string& clientKey )
        {
            Token tok; tok.mgr_ = this; tok.cls_ = cls; tok.client_ = clientKey;

            if( cls == ToolClass::Expensive )
            {
                if( !acquireClientSlot( clientKey ) )
                    throw ToolError( ErrorClass::Connectivity,
                        "server busy: per-client expensive-tier concurrency limit reached" );
                tok.heldClient_ = true;
            }
            BoundedSemaphore& sem = ( cls == ToolClass::Cheap ) ? cheap_ : expensive_;
            if( !sem.tryAcquire( cfg_.maxQueueWaitMs ) )
            {
                if( tok.heldClient_ ) { releaseClient( clientKey ); tok.heldClient_ = false; }
                throw ToolError( ErrorClass::Connectivity, "server busy: concurrency limit reached" );
            }
            tok.heldGlobal_ = true;
            return tok;
        }

    private:
        bool acquireClientSlot( const std::string& key )
        {
            std::lock_guard<std::mutex> lk( clientMu_ );
            int& n = clientCounts_[ key ];
            if( n >= cfg_.expensivePerClient ) return false;
            ++n;
            return true;
        }
        void releaseClient( const std::string& key )
        {
            std::lock_guard<std::mutex> lk( clientMu_ );
            auto it = clientCounts_.find( key );
            if( it != clientCounts_.end() && it->second > 0 ) --it->second;
        }

        ConcurrencyConfig cfg_;
        BoundedSemaphore cheap_, expensive_;
        std::mutex clientMu_;
        std::map<std::string, int> clientCounts_;   // small map, not a hot path
    };
}