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

#include "tools/box/box.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "gtest/gtest.h"
#include "jxl/base/file_io.h"
#include "jxl/base/override.h"
#include "jxl/base/padded_bytes.h"
#include "jxl/base/status.h"

TEST(BoxTest, BoxTest) {
  size_t test_size = 256;
  jxl::PaddedBytes exif(test_size);
  jxl::PaddedBytes jumb(test_size);
  jxl::PaddedBytes codestream(test_size);
  // Generate arbitrary data for the codestreams: the test is not testing
  // the contents of them but whether they are preserved in the container.
  uint8_t v = 0;
  for (size_t i = 0; i < test_size; ++i) {
    exif[i] = v++;
    jumb[i] = v++;
    codestream[i] = v++;
  }

  jpegxl::tools::JpegXlContainer container;
  container.exif = exif.data();
  container.exif_size = exif.size();
  container.jumb = jumb.data();
  container.jumb_size = jumb.size();
  container.codestream = codestream.data();
  container.codestream_size = codestream.size();

  jxl::PaddedBytes file;
  EXPECT_EQ(true,
            jpegxl::tools::EncodeJpegXlContainerOneShot(container, &file));

  jpegxl::tools::JpegXlContainer container2;
  EXPECT_EQ(true, jpegxl::tools::DecodeJpegXlContainerOneShot(
                      file.data(), file.size(), &container2));

  EXPECT_EQ(exif.size(), container2.exif_size);
  EXPECT_EQ(0, memcmp(exif.data(), container2.exif, container2.exif_size));
  EXPECT_EQ(jumb.size(), container2.jumb_size);
  EXPECT_EQ(0, memcmp(jumb.data(), container2.jumb, container2.jumb_size));
  EXPECT_EQ(codestream.size(), container2.codestream_size);
  EXPECT_EQ(0, memcmp(codestream.data(), container2.codestream,
                      container2.codestream_size));
}
