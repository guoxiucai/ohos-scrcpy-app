import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const decoder = readFileSync(
  new URL(
    '../scrcpy_client_flutter/windows/runner/h264_d3d11_decoder.cpp',
    import.meta.url,
  ),
  'utf8',
);

test('D3D11 硬解把完整解码帧缩放到协议视频尺寸而不裁剪', () => {
  assert.match(decoder, /visible_w\s*=\s*width_\s*>\s*0\s*\?\s*width_\s*:\s*actual_w/);
  assert.match(decoder, /visible_h\s*=\s*height_\s*>\s*0\s*\?\s*height_\s*:\s*actual_h/);
  assert.match(decoder, /source_rect\s*=\s*\{[\s\S]*?actual_w[\s\S]*?actual_h[\s\S]*?\}/);
  assert.match(decoder, /destination_rect\s*=\s*\{[\s\S]*?visible_w[\s\S]*?visible_h[\s\S]*?\}/);
  assert.match(decoder, /VideoProcessorSetStreamSourceRect\([\s\S]*?&source_rect\)/);
  assert.match(decoder, /VideoProcessorSetStreamDestRect\([\s\S]*?&destination_rect\)/);
  assert.match(decoder, /EnsureOutputTexture\(actual_w,\s*actual_h,\s*visible_w,\s*visible_h\)/);
  assert.match(decoder, /vpDesc\.InputWidth\s*=\s*processor_input_width_/);
  assert.match(decoder, /vpDesc\.InputHeight\s*=\s*processor_input_height_/);
  assert.match(decoder, /vpDesc\.OutputWidth\s*=\s*out_width_/);
  assert.match(decoder, /vpDesc\.OutputHeight\s*=\s*out_height_/);
  assert.match(decoder, /descriptor_\.visible_width\s*=\s*visible_w/);
  assert.match(decoder, /descriptor_\.visible_height\s*=\s*visible_h/);
});
