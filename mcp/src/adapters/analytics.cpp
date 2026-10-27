// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Analytics tier: 21 tools (plus fractal_vector_quantize_int8's
// twin, the quantize-binary/hamming prefilter chain).
#include "analytics.h"
#include "../db.h"
#include "../vectors.h"
#include "../tool_param_helpers.h"

namespace fsqlmcp
{
    std::vector<ToolSpec> buildAnalyticsTools( Db& db, const RowLimitConfig& rowCfg )
    {
        std::vector<ToolSpec> t;

        t.push_back( ToolSpec{ "fractal_dimension_dfa", "Analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return vectors::wrapScalar( asScalarJson( db.callScalar(
                "SELECT fractal_dimension_dfa(?)", { vectors::vectorParamToText( a.at("series"), "series" ) } ) ) ); } } );
        t.back().description = "DFA scaling exponent (alpha): ~0.5 uncorrelated noise, ~1.0 1/f pink noise, ~1.5 "
            "Brownian motion, <0.5 anti-correlated. Documented minimum 16 points; this org's own testing found "
            "~24 is the real floor for a stable estimate.";

        t.push_back( ToolSpec{ "fractal_dimension_boxcount", "Analytics", ToolClass::Cheap,
            { Vec("points", true, "Point cloud."), Int("dim", true, "Spatial dimension.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return vectors::wrapScalar( asScalarJson( db.callScalar(
                "SELECT fractal_dimension_boxcount(?, ?)",
                { vectors::vectorParamToText( a.at("points"), "points" ), a.at("dim").get<std::int64_t>() } ) ) ); } } );
        t.back().description = "Minkowski-Bouligand box-counting dimension of a point cloud. Documented minimum 8 "
            "points; for a STABLE estimate this org's own testing found it needs hundreds.";

        t.push_back( ToolSpec{ "fractal_dimension_drift", "Analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series."), Int("win", false, "Window size (requires n >= win+16, win >= 16).", 48) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_dimension_drift(?, ?)",
                { vectors::vectorParamToText( a.at("series"), "series" ), a.value( "win", 48 ) } ) ); } } );
        t.back().description = "Regime-change detection: DFA exponent of the recent window vs the baseline. "
            "Returns {drift, recent_alpha, baseline_alpha}; drift is a SIGNED numeric (recent - baseline): "
            "positive = increasing complexity/irregularity, negative = approaching a more ordered state. "
            "Requires n >= window + 16, window >= 16.";

        t.push_back( ToolSpec{ "fractal_change_point_detect", "Analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series."),
              Int("window", true, "Sliding window size (n >= 2*window)."),
              Num("threshold", false, "Pooled-stddev units to flag a boundary.", 2.0),
              Int("max_points", false, "Max boundaries returned.", 16) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_change_point_detect(?, ?, ?, ?)",
                { vectors::vectorParamToText( a.at("series"), "series" ),
                  a.at("window").get<std::int64_t>(), a.value( "threshold", 2.0 ),
                  a.value( "max_points", 16 ) } ) ); } } );
        t.back().description = "DFA's complement: localizes WHERE a series' mean and/or variance shifted, via a "
            "sliding two-sample test over adjacent windows. Returns {'indices':[...]}, ascending, up to max_points.";

        t.push_back( ToolSpec{ "fractal_periodogram", "Analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series (>= 4 points)."), Int("max_peaks", false, "Top peaks to return.", 8) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_periodogram(?, ?)",
                { vectors::vectorParamToText( a.at("series"), "series" ), a.value( "max_peaks", 8 ) } ) ); } } );
        t.back().description = "Classical periodogram via exact O(n^2) DFT (not FFT). Returns {'freqs':[...], "
            "'power':[...]}: top max_peaks bins, descending power. Catches network-beaconing/retry-cadence DFA "
            "alone misses.";

        t.push_back( ToolSpec{ "fractal_spectrogram_entropy", "Analytics", ToolClass::Cheap,
            { Vec("series", true, "Time-ordered series (n >= window)."),
              Int("window", false, "Frame length, 8..512.", 64),
              Int("hop", false, "Samples between frame starts, >= 1.", 32),
              Int("max_frames", false, "Max frames returned, 1..4096.", 4096) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                Json frames = parseJsonStrict( db.callScalar(
                    "SELECT fractal_spectrogram_entropy(?, ?, ?, ?)",
                    { vectors::vectorParamToText( a.at("series"), "series" ), a.value( "window", 64 ),
                      a.value( "hop", 32 ), a.value( "max_frames", 4096 ) } ) );
                return Json{ { "entropy", frames } };
            } } );
        t.back().description = "Short-time spectral entropy: slides a window over a series and returns, per frame, "
            "the normalized Shannon entropy (0..1) of its power spectrum (mean removed, Hann tapered). Low = energy "
            "in a few frequencies (beacon, retry loop, locked carrier); high = spread across the band (noise, "
            "jamming, lost structure). A constant frame reports 0.0, never NaN. Returns {'entropy':[...]}, one "
            "value per frame; feed it to fractal_change_point_detect to localize WHEN the structure changed.";

        t.push_back( ToolSpec{ "fractal_tda_persistence_diagram", "Analytics", ToolClass::Cheap,
            { Vec("points", true, "Point cloud (capped at 512 points)."), Int("dim", true, "Spatial dimension."),
              Int("max_dim", false, "0 (H0 only) or 1 (H0 + Betti-1 graph-cycle-rank estimate).", 0),
              Num("max_thresh", true, "Filtration threshold (> 0)."), Int("max_h0_bars", false, "Max H0 bars returned.", 64) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_tda_persistence_diagram(?, ?, ?, ?, ?)",
                { vectors::vectorParamToText( a.at("points"), "points" ), a.at("dim").get<std::int64_t>(),
                  a.value( "max_dim", 0 ), a.at("max_thresh").get<double>(), a.value( "max_h0_bars", 64 ) } ) ); } } );
        t.back().description = "Topological persistence over a point cloud's Vietoris-Rips filtration. Returns "
            "{'n_h0_bars':N,'h0_bars':[{birth,death}...],'betti1':N|null}. betti1 is the underlying GRAPH's cycle "
            "rank, NOT full simplicial H1 (over-counts when a filled triangle exists).";

        t.push_back( ToolSpec{ "fractal_state_fingerprint", "Analytics", ToolClass::Cheap,
            { Vec("vec", true, "State vector."), Int("n_bits", true, "SimHash bits."), Num("seed", false, "SimHash seed.", 0.0) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                SqlValue v = db.callScalar( "SELECT fractal_state_fingerprint(?, ?, ?)",
                    { vectors::vectorParamToText( a.at("vec"), "vec" ),
                      a.at("n_bits").get<std::int64_t>(), a.value( "seed", 0.0 ) } );
                auto blob = asBlob( v );
                if( !blob )
                    throw ToolError( ErrorClass::ServerInternal, "fractal_state_fingerprint did not return a BLOB" );
                return Json( vectors::blobToHex( blob->data(), blob->size() ) );
            } } );
        t.back().description = "Random-hyperplane SimHash (Charikar 2002) of a state vector, returned as a hex "
            "string, (n_bits+7)/8 bytes. Near-identical states collapse to the same or low-Hamming-distance "
            "fingerprint. GOTCHA: encode scalar states one-hot, not 1-dim.";

        t.push_back( ToolSpec{ "fractal_cycle_detect", "Analytics", ToolClass::Cheap,
            { StrArray("fingerprints", true, "Hex fingerprints from fractal_state_fingerprint."),
              Int("n_bits", true, "SimHash bits used to produce them."),
              Int("hamming_threshold", false, "Match tolerance.", 0) },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_cycle_detect(?, ?, ?)",
                { vectors::stringArrayToJsonText( a.at("fingerprints"), "fingerprints" ),
                  a.at("n_bits").get<std::int64_t>(), a.value( "hamming_threshold", 0 ) } ) ); } } );
        t.back().description = "Brent's-algorithm streaming cycle detection over a fingerprint stream. Returns "
            "{'detected':true,'cycle_len':N,'at_index':I} or {'detected':false}. Stops at the FIRST cycle.";

        t.push_back( ToolSpec{ "fractal_vector_lp_distance", "Analytics", ToolClass::Cheap,
            { Vec("a", true, "Vector a."), Vec("b", true, "Vector b."), Num("p", true, "Order (NOT a metric for 0<p<1).") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return vectors::wrapScalar( asScalarJson( db.callScalar(
                "SELECT fractal_vector_lp_distance(?, ?, ?)",
                { vectors::vectorParamToText( a.at("a"), "a" ), vectors::vectorParamToText( a.at("b"), "b" ),
                  a.at("p").get<double>() } ) ) ); } } );
        t.back().description = "Generalized L_p distance, any p > 0. For 0 < p < 1 this is NOT a proper metric; "
            "never substitute silently for cosine/L2.";

        t.push_back( ToolSpec{ "fractal_vector_quantize_int8", "Analytics", ToolClass::Cheap,
            { Vec("v", true, "Vector to quantize.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_vector_quantize_int8(?)",
                { vectors::vectorParamToText( a.at("v"), "v" ) } ) ); } } );
        t.back().description = "Symmetric int8 quantization of one vector (4x compression). Returns "
            "{'scale':S,'codes':[...]}; dequantize via v[i] ~= codes[i]*scale.";

        t.push_back( ToolSpec{ "fractal_vector_quantize_binary", "Analytics", ToolClass::Cheap,
            { Vec("v", true, "Vector to quantize.") }, std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                SqlValue v = db.callScalar( "SELECT fractal_vector_quantize_binary(?)",
                    { vectors::vectorParamToText( a.at("v"), "v" ) } );
                auto blob = asBlob( v );
                if( !blob )
                    throw ToolError( ErrorClass::ServerInternal,
                                     "fractal_vector_quantize_binary did not return a BLOB" );
                return Json( vectors::blobToHex( blob->data(), blob->size() ) );
            } } );
        t.back().description = "1-bit (sign) quantization: 32x compression, (dim+7)/8 bytes, MSB-first, returned "
            "as a hex string. Pairs with fractal_vector_hamming_distance for cheap pre-filtering.";

        t.push_back( ToolSpec{ "fractal_vector_hamming_distance", "Analytics", ToolClass::Cheap,
            { Str("a", true, "Hex string from fractal_vector_quantize_binary."),
              Str("b", true, "Hex string from fractal_vector_quantize_binary.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) {
                return vectors::wrapScalar( asScalarJson( db.callScalar(
                    "SELECT fractal_vector_hamming_distance(?, ?)",
                    { vectors::hexToBytes( a.at("a").get<std::string>(), "a" ),
                      vectors::hexToBytes( a.at("b").get<std::string>(), "b" ) } ) ) );
            } } );
        t.back().description = "Hamming distance between two binary-quantized vectors (hex strings). A cheap "
            "pre-filter ahead of a full-precision re-rank, not a distance substitute.";

        t.push_back( ToolSpec{ "fractal_vascular_network", "Analytics", ToolClass::Cheap,
            { Vec("node_coords", true, "Flat n_nodes x 3."),
              Vec("edges", true, "Flat n_edges x 2 node indices."), Vec("arc_length", true, "Per-edge arc length.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_vascular_network(?, ?, ?)",
                { vectors::vectorParamToText( a.at("node_coords"), "node_coords" ),
                  vectors::vectorParamToText( a.at("edges"), "edges" ),
                  vectors::vectorParamToText( a.at("arc_length"), "arc_length" ) } ) ); } } );
        t.back().description = "Vessel-network tortuosity + branch-density + fractal dimension from PRE-EXTRACTED "
            "graph geometry (not raw imaging). Returns {'mean_tortuosity','branch_density','fractal_dimension'}.";

        t.push_back( ToolSpec{ "fractal_cortical_folding", "Analytics", ToolClass::Cheap,
            { Vec("vertices", true, "Flat n_vertices x 3."), Vec("faces", true, "Flat n_faces x 3 vertex indices.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_cortical_folding(?, ?)",
                { vectors::vectorParamToText( a.at("vertices"), "vertices" ),
                  vectors::vectorParamToText( a.at("faces"), "faces" ) } ) ); } } );
        t.back().description = "Gyrification Index (Zilles et al. 1988) from a pre-extracted brain-surface mesh. "
            "Returns {'mesh_area','hull_area','gyrification_index'}.";

        t.push_back( ToolSpec{ "fractal_nerve_plexus_metric", "Analytics", ToolClass::Cheap,
            { Vec("node_coords", true, "Flat n_nodes x dim."), Int("dim", true, "Spatial dimension (typically 2)."),
              Vec("edges", true, "Skeleton edges.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_nerve_plexus_metric(?, ?, ?)",
                { vectors::vectorParamToText( a.at("node_coords"), "node_coords" ),
                  a.at("dim").get<std::int64_t>(),
                  vectors::vectorParamToText( a.at("edges"), "edges" ) } ) ); } } );
        t.back().description = "Nerve-fiber plexus density + dimension from pre-extracted skeleton geometry "
            "(corneal confocal microscopy convention). Returns {'fiber_length_density','branch_density','fractal_dimension'}.";

        t.push_back( ToolSpec{ "fractal_morphological_complexity", "Analytics", ToolClass::Cheap,
            { Vec("points", true, "Pre-segmented mask's occupied points (~256+ for a stable read)."),
              Int("dim", true, "Spatial dimension.") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_morphological_complexity(?, ?)",
                { vectors::vectorParamToText( a.at("points"), "points" ), a.at("dim").get<std::int64_t>() } ) ); } } );
        t.back().description = "Box-counting dimension + lacunarity of a pre-segmented mask. GOTCHA: wants ~256+ "
            "occupied points for a stable read; smaller clouds fail with rc=-1 rather than a confident wrong "
            "number. Returns {'dimension','lacunarity'}.";

        t.push_back( ToolSpec{ "fractal_optimize_portfolio", "Analytics", ToolClass::Cheap,
            { Vec("mu", true, "Expected returns."), Vec("cov", true, "Flattened 1-D row-major n x n covariance."),
              Int("k", true, "Max nonzero assets."), Num("seed", true, "RNG seed."),
              Bool_("use_obl", false, "Opposition-Based Learning per SFS trial (off by default; doubles the affected step's cost).", false),
              StrEnum("diffusion_mode", false, "'gaussian' or 'levy' (heavy-tailed, can escape local optima).", "gaussian") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_optimize_portfolio(?, ?, ?, ?, ?, ?)",
                { vectors::vectorParamToText( a.at("mu"), "mu" ), vectors::vectorParamToText( a.at("cov"), "cov" ),
                  a.at("k").get<std::int64_t>(), a.at("seed").get<double>(),
                  static_cast<std::int64_t>( a.value( "use_obl", false ) ? 1 : 0 ),
                  a.value( "diffusion_mode", std::string( "gaussian" ) ) } ) ); } } );
        t.back().description = "SFS cardinality-constrained Sharpe-ratio maximizer: the best K assets out of a "
            "large universe without brute-force exponential cost. Returns {'sharpe','weights'} (<=k nonzero, "
            "non-negative, summing to 1.0).";

        t.push_back( ToolSpec{ "fractal_optimize_portfolio_multimodal", "Analytics", ToolClass::Cheap,
            { Vec("mu", true, "Expected returns."), Vec("cov", true, "Flattened covariance."),
              Int("k", true, "Max nonzero assets."), Int("n_restarts", false, "Independent restarts.", 8),
              Num("overlap_threshold", false, "Asset-overlap threshold.", 0.15),
              Num("quality_frac", false, "Quality fraction gate.", 0.90), Num("seed", true, "RNG seed."),
              Bool_("use_obl", false, "Requires an enterprise core build with OBL support.", false),
              StrEnum("diffusion_mode", false, "'gaussian' or 'levy'.", "gaussian") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_optimize_portfolio_multimodal(?, ?, ?, ?, ?, ?, ?, ?, ?)",
                { vectors::vectorParamToText( a.at("mu"), "mu" ), vectors::vectorParamToText( a.at("cov"), "cov" ),
                  a.at("k").get<std::int64_t>(), a.value( "n_restarts", 8 ),
                  a.value( "overlap_threshold", 0.15 ), a.value( "quality_frac", 0.90 ),
                  a.at("seed").get<double>(),
                  static_cast<std::int64_t>( a.value( "use_obl", false ) ? 1 : 0 ),
                  a.value( "diffusion_mode", std::string( "gaussian" ) ) } ) ); } } );
        t.back().description = "Multi-restart diverse-candidate sibling of fractal_optimize_portfolio. Returns "
            "{'candidates':[{'sharpe','weights'}],'n_found':N}. Enterprise tier: clean 'not loaded' error on "
            "Community.";

        t.push_back( ToolSpec{ "fractal_optimize_portfolio_multimodal_pareto", "Analytics", ToolClass::Cheap,
            { Vec("mu", true, "Expected returns."), Vec("cov", true, "Flattened covariance."),
              Int("k", true, "Max nonzero assets."), Int("n_restarts", false, "Independent restarts.", 8),
              Int("max_front", false, "Pareto-front cap (1<=max_front<=n_restarts).", 8),
              Num("seed", true, "RNG seed."), Bool_("use_obl", false, "OBL per trial.", false),
              StrEnum("diffusion_mode", false, "'gaussian' or 'levy'.", "gaussian") },
            std::nullopt, false, true,
            [&db]( const Json& a, CallCtx& ) { return parseJsonStrict( db.callScalar(
                "SELECT fractal_optimize_portfolio_multimodal_pareto(?, ?, ?, ?, ?, ?, ?, ?)",
                { vectors::vectorParamToText( a.at("mu"), "mu" ), vectors::vectorParamToText( a.at("cov"), "cov" ),
                  a.at("k").get<std::int64_t>(), a.value( "n_restarts", 8 ), a.value( "max_front", 8 ),
                  a.at("seed").get<double>(),
                  static_cast<std::int64_t>( a.value( "use_obl", false ) ? 1 : 0 ),
                  a.value( "diffusion_mode", std::string( "gaussian" ) ) } ) ); } } );
        t.back().description = "Pareto-front sibling: same restarts, scored by decomposed (return,risk), NSGA-II "
            "crowding-distance truncated. Returns {'candidates':[{'return','risk','sharpe','weights'}],'n_found':N}. "
            "Enterprise tier.";

        t.push_back( ToolSpec{ "fractal_optimize_subset", "Analytics", ToolClass::Cheap,
            { Vec("item_values", true, "Per-item scores."), Vec("upper_bounds", true, "Per-item weight cap, each in [0,1]."),
              Int("k", true, "Max nonzero items."), Vec("prev_weights", false, "Previous weights (enables turnover_penalty)."),
              Num("turnover_penalty", false, "Only meaningful with prev_weights set.", 0.0),
              Num("seed", true, "RNG seed."), RowLimit() },
            std::nullopt, false, true,
            [&db, &rowCfg]( const Json& a, CallCtx& ) {
                SqlValue prevW = a.contains( "prev_weights" ) && !a.at( "prev_weights" ).is_null()
                    ? SqlValue( vectors::vectorParamToText( a.at( "prev_weights" ), "prev_weights" ) )
                    : SqlValue( nullptr );
                return parseJsonStrict( db.callScalar( "SELECT fractal_optimize_subset(?, ?, ?, ?, ?, ?)",
                    { vectors::vectorParamToText( a.at("item_values"), "item_values" ),
                      vectors::vectorParamToText( a.at("upper_bounds"), "upper_bounds" ),
                      a.at( "k" ).get<std::int64_t>(), prevW, a.value( "turnover_penalty", 0.0 ),
                      a.at( "seed" ).get<double>() } ) );
            } } );
        t.back().description = "Value-weighted k-subset allocation over ANY scored item list: maximize "
            "sum(weight[i]*item_values[i]) with at most k nonzero, each weight<=upper_bounds[i], summing to 1.0. "
            "Returns {'score','weights'}. The sum of the k largest upper_bounds must reach 1.0 or no feasible "
            "subset exists (clean engine error).";

        t.push_back( ToolSpec{ "fractal_store_morphology", "Analytics", ToolClass::Cheap,
            { NullableNum("doc_id", "Feature-store key (nullable bigint)."), Vec("feature_array", true, "Feature vector.") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                SqlValue id = a.contains( "doc_id" ) && !a.at( "doc_id" ).is_null()
                    ? SqlValue( a.at( "doc_id" ).get<std::int64_t>() ) : SqlValue( nullptr );
                SqlValue raw = db.callScalar( "SELECT fractal_store_morphology(?, ?)",
                    { id, vectors::vectorParamToText( a.at("feature_array"), "feature_array" ) } );
                const auto str = asText( raw );
                if( str && *str == "ok" ) return Json{ { "status", "ok" } };
                return parseJsonLenient( raw );
            } } );
        t.back().description = "Upserts a feature vector against a doc_id in the generic per-item feature store "
            "(auto-created on first use). Last-writer-wins. Returns {'status':'ok'}.";

        t.push_back( ToolSpec{ "fractal_mine_topology_negatives", "Analytics", ToolClass::Cheap,
            { Vec("surrogate_vector", true, "Query vector into the feature store."), Int("k", false, "Neighbors to return.", 10), RowLimit() },
            std::nullopt, false, true,
            [&db, &rowCfg]( const Json& a, CallCtx& ) {
                BoundedCount bc = boundedCount( a, "k", 10, rowCfg );
                return annotateRows( parseJsonStrict( db.callScalar( "SELECT fractal_mine_topology_negatives(?, ?)",
                    { vectors::vectorParamToText( a.at("surrogate_vector"), "surrogate_vector" ),
                      static_cast<std::int64_t>( bc.passed ) } ) ), bc );
            } } );
        t.back().description = "Brute-force k-NN (true Euclidean, ascending) over the fractal_store_morphology "
            "feature store. Returns [{'doc_id','distance'}], nearest first. A stored row whose dimension "
            "mismatches the surrogate is skipped, not an error.";

        return t;
    }
}