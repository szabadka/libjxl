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

#ifndef TOOLS_CJXL_H_
#define TOOLS_CJXL_H_

#include <stddef.h>

#include <utility>

#include "jxl/base/data_parallel.h"
#include "jxl/base/padded_bytes.h"
#include "jxl/base/status.h"
#include "jxl/base/thread_pool_internal.h"
#include "jxl/codec_in_out.h"
#include "jxl/enc_params.h"
#include "jxl/jxl_inspection.h"
#include "tools/cmdline.h"

namespace jpegxl {
namespace tools {

struct JxlCompressArgs {
  // Initialize non-static default options.
  JxlCompressArgs();

  void SetInspectorImage3F(const jxl::InspectorImage3F& inspector) {
    inspector_image3f = inspector;
  }

  // Add all the command line options to the CommandLineParser. Note that the
  // options are tied to the instance that this was called on.
  jxl::Status AddCommandLineOptions(CommandLineParser* cmdline);

  // Post-processes and validates the passed arguments, checking whether all
  // passed options are compatible. Returns whether the validation was
  // successful.
  jxl::Status ValidateArgs(const CommandLineParser& cmdline);

  jxl::DecoderHints dec_hints;
  size_t override_bitdepth = 0;
  jxl::CompressParams params;
  size_t num_threads = 0;
  size_t num_reps = 1;
  bool got_intensity_target = false;

  // Whether to perform lossless transcoding with kVarDCT or kJPEG encoding.
  // If true, attempts to load JPEG coefficients instead of pixels.
  // Reset to false if input image is not a JPEG.
  bool jpeg_transcode = true;

  float quality = -1001.f;  // Default to lossless if input is already lossy,
                            // q90 (d1) otherwise
  bool progressive = false;
  bool default_settings = true;

  // Will get passed on to AuxOut.
  jxl::InspectorImage3F inspector_image3f;

  // References (ids) of specific options to check if they were matched.
  CommandLineParser::OptionId opt_distance_id = -1;
  CommandLineParser::OptionId opt_target_size_id = -1;
  CommandLineParser::OptionId opt_target_bpp_id = -1;
  CommandLineParser::OptionId opt_near_lossless_id = -1;
  CommandLineParser::OptionId opt_intensity_target_id = -1;

  CommandLineParser::OptionId opt_brotli_id = -1;
  CommandLineParser::OptionId opt_color_id = -1;

  // just for testing: add one extra channel which is a spot color (red)
  const char* spot_in = nullptr;
};

jxl::Status CompressJxl(jxl::ThreadPoolInternal* pool, JxlCompressArgs& args,
                        jxl::PaddedBytes* compressed, bool print_stats = true);

}  // namespace tools
}  // namespace jpegxl

#endif  // TOOLS_CJXL_H_
