// Copyright (c) the JPEG XL Project
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef JXL_BASE_FAST_LOG_H_
#define JXL_BASE_FAST_LOG_H_

#include <stdint.h>
#include <string.h>

#include <cmath>
#include <hwy/static_targets.h>

namespace jxl {

// A lookup table for small values of log2(int) to be used in entropy
// computation.
//
// ", ".join(["%.16ff" % x for x in [0.0]+[log2(x) for x in range(1, 256)]])
static const float kLog2Table[] = {
    0.0000000000000000f, 0.0000000000000000f, 1.0000000000000000f,
    1.5849625007211563f, 2.0000000000000000f, 2.3219280948873622f,
    2.5849625007211561f, 2.8073549220576042f, 3.0000000000000000f,
    3.1699250014423126f, 3.3219280948873626f, 3.4594316186372978f,
    3.5849625007211565f, 3.7004397181410922f, 3.8073549220576037f,
    3.9068905956085187f, 4.0000000000000000f, 4.0874628412503400f,
    4.1699250014423122f, 4.2479275134435852f, 4.3219280948873626f,
    4.3923174227787607f, 4.4594316186372973f, 4.5235619560570131f,
    4.5849625007211570f, 4.6438561897747244f, 4.7004397181410926f,
    4.7548875021634691f, 4.8073549220576037f, 4.8579809951275728f,
    4.9068905956085187f, 4.9541963103868758f, 5.0000000000000000f,
    5.0443941193584534f, 5.0874628412503400f, 5.1292830169449664f,
    5.1699250014423122f, 5.2094533656289501f, 5.2479275134435852f,
    5.2854022188622487f, 5.3219280948873626f, 5.3575520046180838f,
    5.3923174227787607f, 5.4262647547020979f, 5.4594316186372973f,
    5.4918530963296748f, 5.5235619560570131f, 5.5545888516776376f,
    5.5849625007211570f, 5.6147098441152083f, 5.6438561897747244f,
    5.6724253419714961f, 5.7004397181410926f, 5.7279204545631996f,
    5.7548875021634691f, 5.7813597135246599f, 5.8073549220576046f,
    5.8328900141647422f, 5.8579809951275719f, 5.8826430493618416f,
    5.9068905956085187f, 5.9307373375628867f, 5.9541963103868758f,
    5.9772799234999168f, 6.0000000000000000f, 6.0223678130284544f,
    6.0443941193584534f, 6.0660891904577721f, 6.0874628412503400f,
    6.1085244567781700f, 6.1292830169449672f, 6.1497471195046822f,
    6.1699250014423122f, 6.1898245588800176f, 6.2094533656289510f,
    6.2288186904958804f, 6.2479275134435861f, 6.2667865406949019f,
    6.2854022188622487f, 6.3037807481771031f, 6.3219280948873617f,
    6.3398500028846252f, 6.3575520046180847f, 6.3750394313469254f,
    6.3923174227787598f, 6.4093909361377026f, 6.4262647547020979f,
    6.4429434958487288f, 6.4594316186372982f, 6.4757334309663976f,
    6.4918530963296748f, 6.5077946401986964f, 6.5235619560570131f,
    6.5391588111080319f, 6.5545888516776376f, 6.5698556083309478f,
    6.5849625007211561f, 6.5999128421871278f, 6.6147098441152092f,
    6.6293566200796095f, 6.6438561897747253f, 6.6582114827517955f,
    6.6724253419714952f, 6.6865005271832185f, 6.7004397181410917f,
    6.7142455176661224f, 6.7279204545631988f, 6.7414669864011465f,
    6.7548875021634691f, 6.7681843247769260f, 6.7813597135246599f,
    6.7944158663501062f, 6.8073549220576037f, 6.8201789624151887f,
    6.8328900141647422f, 6.8454900509443757f, 6.8579809951275719f,
    6.8703647195834048f, 6.8826430493618416f, 6.8948177633079437f,
    6.9068905956085187f, 6.9188632372745955f, 6.9307373375628867f,
    6.9425145053392399f, 6.9541963103868758f, 6.9657842846620879f,
    6.9772799234999168f, 6.9886846867721664f, 7.0000000000000000f,
    7.0112272554232540f, 7.0223678130284544f, 7.0334230015374501f,
    7.0443941193584534f, 7.0552824355011898f, 7.0660891904577721f,
    7.0768155970508317f, 7.0874628412503400f, 7.0980320829605272f,
    7.1085244567781700f, 7.1189410727235076f, 7.1292830169449664f,
    7.1395513523987937f, 7.1497471195046822f, 7.1598713367783891f,
    7.1699250014423130f, 7.1799090900149345f, 7.1898245588800176f,
    7.1996723448363644f, 7.2094533656289492f, 7.2191685204621621f,
    7.2288186904958804f, 7.2384047393250794f, 7.2479275134435861f,
    7.2573878426926521f, 7.2667865406949019f, 7.2761244052742384f,
    7.2854022188622487f, 7.2946207488916270f, 7.3037807481771031f,
    7.3128829552843557f, 7.3219280948873617f, 7.3309168781146177f,
    7.3398500028846243f, 7.3487281542310781f, 7.3575520046180847f,
    7.3663222142458151f, 7.3750394313469254f, 7.3837042924740528f,
    7.3923174227787607f, 7.4008794362821844f, 7.4093909361377026f,
    7.4178525148858991f, 7.4262647547020979f, 7.4346282276367255f,
    7.4429434958487288f, 7.4512111118323299f, 7.4594316186372973f,
    7.4676055500829976f, 7.4757334309663976f, 7.4838157772642564f,
    7.4918530963296748f, 7.4998458870832057f, 7.5077946401986964f,
    7.5156998382840436f, 7.5235619560570131f, 7.5313814605163119f,
    7.5391588111080319f, 7.5468944598876373f, 7.5545888516776376f,
    7.5622424242210728f, 7.5698556083309478f, 7.5774288280357487f,
    7.5849625007211561f, 7.5924570372680806f, 7.5999128421871278f,
    7.6073303137496113f, 7.6147098441152075f, 7.6220518194563764f,
    7.6293566200796095f, 7.6366246205436488f, 7.6438561897747244f,
    7.6510516911789290f, 7.6582114827517955f, 7.6653359171851765f,
    7.6724253419714952f, 7.6794800995054464f, 7.6865005271832185f,
    7.6934869574993252f, 7.7004397181410926f, 7.7073591320808825f,
    7.7142455176661224f, 7.7210991887071856f, 7.7279204545631996f,
    7.7347096202258392f, 7.7414669864011465f, 7.7481928495894596f,
    7.7548875021634691f, 7.7615512324444795f, 7.7681843247769260f,
    7.7747870596011737f, 7.7813597135246608f, 7.7879025593914317f,
    7.7944158663501062f, 7.8008998999203047f, 7.8073549220576037f,
    7.8137811912170374f, 7.8201789624151887f, 7.8265484872909159f,
    7.8328900141647422f, 7.8392037880969445f, 7.8454900509443757f,
    7.8517490414160571f, 7.8579809951275719f, 7.8641861446542798f,
    7.8703647195834048f, 7.8765169465650002f, 7.8826430493618425f,
    7.8887432488982601f, 7.8948177633079446f, 7.9008668079807496f,
    7.9068905956085187f, 7.9128893362299619f, 7.9188632372745955f,
    7.9248125036057813f, 7.9307373375628867f, 7.9366379390025719f,
    7.9425145053392399f, 7.9483672315846778f, 7.9541963103868758f,
    7.9600019320680806f, 7.9657842846620870f, 7.9715435539507720f,
    7.9772799234999168f, 7.9829935746943104f, 7.9886846867721664f,
    7.9943534368588578f};

// Faster logarithm for small integers, with the property of log2(0) == 0.
static inline float FastLog2(uint32_t v) {
  if (v < (sizeof(kLog2Table) / sizeof(kLog2Table[0]))) {
    return kLog2Table[v];
  }
  return static_cast<float>(log2(v));
}

// L1 error ~9.1E-3 (see fast_log_test).
static inline float FastLog2f(float f) {
  int32_t f_bits;
  memcpy(&f_bits, &f, 4);
  int exp = ((f_bits >> 23) & 0xFF) - 126;
  uint32_t fr_bits = (f_bits & 0x807fffff) | 0x3f000000;
  float fr;
  memcpy(&fr, &fr_bits, 4);
  // TODO(veluca): improve constants.
  return exp + (-1.34752046f * fr + 3.98979143f) * fr - 2.64898502f;
}

// L1 error ~1.6E-4 (see fast_log_test).
template <class V>
HWY_ATTR V FastLog2f_12bits(V x) {
  // Modified from code bearing the following license:
  // https://github.com/etheory/fastapprox/blob/master/fastapprox/src/fastlog.h
  /*=====================================================================*
   *                   Copyright (C) 2011 Paul Mineiro                   *
   * All rights reserved.                                                *
   *                                                                     *
   * Redistribution and use in source and binary forms, with             *
   * or without modification, are permitted provided that the            *
   * following conditions are met:                                       *
   *                                                                     *
   *     * Redistributions of source code must retain the                *
   *     above copyright notice, this list of conditions and             *
   *     the following disclaimer.                                       *
   *                                                                     *
   *     * Redistributions in binary form must reproduce the             *
   *     above copyright notice, this list of conditions and             *
   *     the following disclaimer in the documentation and/or            *
   *     other materials provided with the distribution.                 *
   *                                                                     *
   *     * Neither the name of Paul Mineiro nor the names                *
   *     of other contributors may be used to endorse or promote         *
   *     products derived from this software without specific            *
   *     prior written permission.                                       *
   *                                                                     *
   * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND              *
   * CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,         *
   * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES               *
   * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE             *
   * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER               *
   * OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,                 *
   * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES            *
   * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE           *
   * GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR                *
   * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF          *
   * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT           *
   * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY              *
   * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE             *
   * POSSIBILITY OF SUCH DAMAGE.                                         *
   *                                                                     *
   * Contact: Paul Mineiro <paul@mineiro.com>                            *
   *=====================================================================*/
  HWY_FULL(float) df;
  HWY_FULL(int32_t) di;
  auto x_bits = BitCast(di, x);
  const auto m_bits = (x_bits & Set(di, 0x007FFFFF)) | Set(di, 0x3f000000);
  const auto m = BitCast(df, m_bits);
  auto y = ConvertTo(df, x_bits) * Set(df, 1.1920928955078125e-7f);
  return y - Set(df, 124.22551499f) - Set(df, 1.498030302f) * m -
         Set(df, 1.72587999f) / (Set(df, 0.3520887068f) + m);
}

}  // namespace jxl

#endif  // JXL_BASE_FAST_LOG_H_
