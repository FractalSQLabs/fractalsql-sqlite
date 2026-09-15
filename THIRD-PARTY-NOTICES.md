Third-Party Notices

This file contains licensing and attribution notices for third-party software components incorporated into FractalSQL.

### 1. SFS (Stochastic Fractal Search) Algorithms
Component: SFS Core Math & Stochastic Convergence Logic
Source: Based on "Stochastic Fractal Search" (Salimi 2014)
License: BSD-2-Clause

Copyright (c) 2014, Hamid Salimi. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in
      the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

-------------------------------------------------------------------------------

### 2. LuaJIT PRNG (lj_prng.c)
Component: Tausworthe-223 pseudo-random number generator, ported to C from LuaJIT's lj_prng.c and baked into the vendored core archive. The LuaJIT runtime itself is not linked.
Source: https://luajit.org/
License: MIT License

Copyright (C) 2005-2023 Mike Pall. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

-------------------------------------------------------------------------------

### 3. libcurl
Component: bundled inside the vendored fractalsql-reasoning-http plugin
(include/<os>-<arch>/fractalsql-reasoning-http.so / .dll), which this
package stages directly into its own deb/rpm/msi output (see package.sh).
Source: https://curl.se/
License: curl license (MIT/X derivative)

Linkage by platform (inherited from fractalsql-reasoning-http's own build):
  - Linux:   dynamically linked against the distro-provided libcurl;
             not bundled into the shipped .so.
  - Windows: statically linked and bundled into the shipped .dll. TLS
             backend is Schannel.
  - Darwin:  dynamically linked against the system-provided libcurl;
             not bundled into the shipped .so.

Copyright (c) 1996 - 2026, Daniel Stenberg, <daniel@haxx.se>, and many
contributors, see the THANKS file.

All rights reserved.

Permission to use, copy, modify, and distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright
notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF THIRD PARTY RIGHTS. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
OR OTHER DEALINGS IN THE SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not
be used in advertising or otherwise to promote the sale, use or other dealings
in this Software without prior written authorization of the copyright holder.

-------------------------------------------------------------------------------

### 4. zlib -- Windows builds only
Component: bundled inside the vendored fractalsql-reasoning-http plugin's
Windows build only, alongside static libcurl in entry 3 above -- curl's
own build depends on zlib for HTTP gzip/deflate Content-Encoding support,
and vcpkg links it transitively into the shipped .dll.
Source: https://zlib.net/
License: zlib License

Copyright notice:

 (C) 1995-2026 Jean-loup Gailly and Mark Adler

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.

  Jean-loup Gailly        Mark Adler
  jloup@gzip.org          madler@alumni.caltech.edu

-------------------------------------------------------------------------------

### 5. Algorithm Attributions (Original Implementations)

The vendored core artifact (v2.x, community-sovereign) includes several
components that are ORIGINAL C implementations of published algorithms/
methods, not ports or incorporations of existing third-party source code
-- so no third-party license text applies. Listed here as academic
attribution for the published method each implementation follows, per
standard practice for algorithm-based (rather than code-derived)
components. Mirrors core's own THIRD-PARTY-NOTICES-COMMUNITY.md.

- **HNSW** -- Malkov, Y. A., & Yashunin, D. A. (2016, revised 2018).
  "Efficient and Robust Approximate Nearest Neighbor Search Using
  Hierarchical Navigable Small World Graphs." Implemented in the vendored
  core for a planned persistent-index feature; not currently used by
  `fractal_search`/`fractal_search_explore`, which do an exact brute-force
  scan (see `bench/README.md`).
- **DFA -- Detrended Fluctuation Analysis** (`fractal_dimension_dfa`,
  `fractal_dimension_drift`) -- Peng, C.-K., Buldyrev, S. V., Havlin, S.,
  Simons, M., Stanley, H. E., & Goldberger, A. L. (1994). "Mosaic
  organization of DNA nucleotides."
- **Box-counting (Minkowski-Bouligand) dimension**
  (`fractal_dimension_boxcount`, and shared by the domain-geometry
  functions below) -- standard, widely-used fractal-dimension estimation
  technique; not attributed to a single originating paper.
- **Lacunarity, fixed-grid variant** (used by
  `fractal_morphological_complexity`) -- Plotnick, R. E., Gardner, R. H.,
  & O'Neill, R. V. (1996). "Lacunarity indices as measures of landscape
  texture."
- **Gyrification Index** (`fractal_cortical_folding`) -- Zilles, K.,
  Armstrong, E., Schleicher, A., & Kretschmann, H. J. (1988). "The human
  pattern of gyrification in the cerebral cortex."
- **Vascular tortuosity (arc-chord ratio) / branch density**
  (`fractal_vascular_network`) -- standard vascular morphometry measures,
  not attributed to a single originating paper.
- **Corneal Nerve Fractal Dimension (CNFrD) convention**
  (`fractal_nerve_plexus_metric`) -- parameter conventions match those
  used by corneal confocal microscopy (CCM) analysis tools such as
  ACCMetrics.
- **Cardinality-constrained portfolio optimization**
  (`fractal_optimize_portfolio`) -- a hardcoded objective template built
  on entry 1's SFS engine (project-then-evaluate against a Sharpe-ratio
  objective); not itself a port of a separate published algorithm.
