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

#include "plugins/gimp/file-j-load.h"

// Defined by both FUIF and glib.
#undef MAX
#undef MIN
#undef CLAMP

#include "jxl/base/file_io.h"
#include "jxl/base/thread_pool_internal.h"
#include "jxl/dec_file.h"
#include "plugins/gimp/common.h"

namespace jxl {

namespace {

template <GimpPrecision precision, bool has_alpha, size_t num_channels>
void FillBuffer(
    const CodecInOut& io,
    std::vector<typename BufferFormat<precision>::Sample>* const pixel_data) {
  pixel_data->reserve(io.xsize() * io.ysize() * (num_channels + has_alpha));
  const float alpha_normalizer =
      has_alpha ? 1.f / ((1u << io.metadata.alpha_bits) - 1.f) : 0.f;
  for (size_t y = 0; y < io.ysize(); ++y) {
    const float* rows[num_channels];
    for (size_t c = 0; c < num_channels; ++c) {
      rows[c] = io.Main().color().ConstPlaneRow(c, y);
    }
    const uint16_t* const alpha_row =
        has_alpha ? io.Main().alpha().ConstRow(y) : nullptr;
    for (size_t x = 0; x < io.xsize(); ++x) {
      const float alpha = has_alpha ? alpha_row[x] * alpha_normalizer : 1.f;
      const float alpha_multiplier =
          has_alpha && io.Main().AlphaIsPremultiplied()
              ? 1.f / std::max(alpha, 1.f / (1u << 16))
              : 1.f;
      for (const float* const row : rows) {
        pixel_data->push_back(BufferFormat<precision>::FromFloat(
            std::max(0.f, std::min(255.f, alpha_multiplier * row[x]))));
      }
      if (has_alpha) {
        pixel_data->push_back(
            BufferFormat<precision>::FromFloat(255.f * alpha));
      }
    }
  }
}

template <GimpPrecision precision>
Status FillGimpLayer(const gint32 layer, const CodecInOut& io,
                     GimpImageType layer_type) {
  std::vector<typename BufferFormat<precision>::Sample> pixel_data;
  switch (layer_type) {
    case GIMP_GRAY_IMAGE:
      FillBuffer<precision, /*has_alpha=*/false, /*num_channels=*/1>(
          io, &pixel_data);
      break;
    case GIMP_GRAYA_IMAGE:
      FillBuffer<precision, /*has_alpha=*/true, /*num_channels=*/1>(
          io, &pixel_data);
      break;
    case GIMP_RGB_IMAGE:
      FillBuffer<precision, /*has_alpha=*/false, /*num_channels=*/3>(
          io, &pixel_data);
      break;
    case GIMP_RGBA_IMAGE:
      FillBuffer<precision, /*has_alpha=*/true, /*num_channels=*/3>(
          io, &pixel_data);
      break;
    default:
      return false;
  }

  GeglBuffer* buffer = gimp_drawable_get_buffer(layer);
  gegl_buffer_set(buffer, GEGL_RECTANGLE(0, 0, io.xsize(), io.ysize()), 0,
                  nullptr, pixel_data.data(), GEGL_AUTO_ROWSTRIDE);
  g_clear_object(&buffer);
  return true;
}

}  // namespace

Status LoadJpegXlImage(const gchar* const filename, gint32* const image_id) {
  PaddedBytes compressed;
  JXL_RETURN_IF_ERROR(ReadFile(filename, &compressed));

  // TODO(deymo): Use C API instead of the ThreadPoolInternal.
  ThreadPoolInternal pool;
  DecompressParams dparams;
  CodecInOut io;
  JXL_RETURN_IF_ERROR(
      DecodeFile(dparams, compressed, &io, /*aux_out=*/nullptr, &pool));

  JXL_RETURN_IF_ERROR(io.TransformTo(io.metadata.color_encoding, &pool));

  const PaddedBytes& icc = io.metadata.color_encoding.ICC();
  GimpColorProfile* profile =
      gimp_color_profile_new_from_icc_profile(icc.data(), icc.size(),
                                              /*error=*/nullptr);
  if (profile == nullptr) {
    return JXL_FAILURE(
        "Failed to create GIMP color profile from %zu bytes of ICC data",
        icc.size());
  }

  GimpImageBaseType image_type;
  GimpImageType layer_type;

  if (io.Main().IsGray()) {
    image_type = GIMP_GRAY;
    if (io.Main().HasAlpha()) {
      layer_type = GIMP_GRAYA_IMAGE;
    } else {
      layer_type = GIMP_GRAY_IMAGE;
    }
  } else {
    image_type = GIMP_RGB;
    if (io.Main().HasAlpha()) {
      layer_type = GIMP_RGBA_IMAGE;
    } else {
      layer_type = GIMP_RGB_IMAGE;
    }
  }

  GimpPrecision precision;
  Status (*fill_layer)(gint32 layer, const CodecInOut& io, GimpImageType);
  if (io.metadata.bits_per_sample <= 8) {
    precision = GIMP_PRECISION_U8_GAMMA;
    fill_layer = &FillGimpLayer<GIMP_PRECISION_U8_GAMMA>;
  } else if (io.metadata.bits_per_sample <= 16) {
    precision = GIMP_PRECISION_U16_GAMMA;
    fill_layer = &FillGimpLayer<GIMP_PRECISION_U16_GAMMA>;
  } else {
    precision = GIMP_PRECISION_FLOAT_GAMMA;
    fill_layer = &FillGimpLayer<GIMP_PRECISION_FLOAT_GAMMA>;
  }

  *image_id = gimp_image_new_with_precision(io.xsize(), io.ysize(), image_type,
                                            precision);
  gimp_image_set_color_profile(*image_id, profile);
  g_clear_object(&profile);
  const gint32 layer = gimp_layer_new(
      *image_id, "image", io.xsize(), io.ysize(), layer_type, /*opacity=*/100,
      gimp_image_get_default_new_layer_mode(*image_id));
  gimp_image_set_filename(*image_id, filename);
  gimp_image_insert_layer(*image_id, layer, /*parent_id=*/-1, /*position=*/0);

  JXL_RETURN_IF_ERROR(fill_layer(layer, io, layer_type));

  return true;
}

}  // namespace jxl
