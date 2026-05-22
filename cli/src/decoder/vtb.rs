//! VideoToolbox H.264 硬件解码器（仅 macOS）

#[cfg(not(target_os = "macos"))]
compile_error!("decoder/vtb.rs 仅支持 macOS");

use std::ffi::c_void;
use std::ptr::null;
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::time::Duration;

use anyhow::{anyhow, Result};

use super::DecodedFrame;

// ──────────────────────── FFI 类型 ────────────────────────

type OSStatus = i32;
type Boolean = u8;
type CFAllocatorRef = *const c_void;
type CFTypeRef = *const c_void;
type CMFormatDescriptionRef = *mut c_void;
type CMSampleBufferRef = *mut c_void;
type CMBlockBufferRef = *mut c_void;
type CVPixelBufferRef = *mut c_void;
type VTDecompressionSessionRef = *mut c_void;
type CMItemCount = isize;
type VTDecodeFrameFlags = u32;
type VTDecodeInfoFlags = u32;
type CVOptionFlags = u64;

#[repr(C)]
#[derive(Clone, Copy)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}

const KCM_TIME_ZERO: CMTime    = CMTime { value: 0, timescale: 1, flags: 1, epoch: 0 }; // kCMTimeFlags_Valid=1
const KCM_TIME_INVALID: CMTime = CMTime { value: 0, timescale: 0, flags: 0, epoch: 0 }; // kCMTimeInvalid: flags=0

#[repr(C)]
struct CMSampleTimingInfo {
    duration: CMTime,
    presentation_time_stamp: CMTime,
    decode_time_stamp: CMTime,
}

type VtCallback = unsafe extern "C" fn(
    *mut c_void, *mut c_void, OSStatus, VTDecodeInfoFlags, CVPixelBufferRef, CMTime, CMTime,
);

#[repr(C)]
struct VTDecompressionOutputCallbackRecord {
    callback: VtCallback,
    refcon: *mut c_void,
}

// kCFAllocatorNull is a runtime extern in CF; don't fake it.
// Use null() (kCFAllocatorDefault) together with malloc-allocated data instead.
const KCV_PIXEL_BUFFER_LOCK_READ_ONLY: CVOptionFlags = 0x0000_0001;

// ──────────────────────── Extern 声明 ────────────────────────

extern "C" {
    fn malloc(size: usize) -> *mut c_void;
    fn free(ptr: *mut c_void);
}
// Alias to avoid name collision with CF's own `free` usage
unsafe fn libc_free(ptr: *mut c_void) { free(ptr); }

#[link(name = "CoreMedia", kind = "framework")]
extern "C" {
    fn CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: CFAllocatorRef,
        param_set_count: usize,
        param_set_pointers: *const *const u8,
        param_set_sizes: *const usize,
        nal_unit_header_length: i32,
        format_desc_out: *mut CMFormatDescriptionRef,
    ) -> OSStatus;

    fn CMBlockBufferCreateWithMemoryBlock(
        structure_allocator: CFAllocatorRef,
        memory_block: *mut c_void,
        block_length: usize,
        block_allocator: CFAllocatorRef,
        custom_block_source: *const c_void,
        offset_to_data: usize,
        data_length: usize,
        flags: u32,
        block_buffer_out: *mut CMBlockBufferRef,
    ) -> OSStatus;

    fn CMSampleBufferCreate(
        allocator: CFAllocatorRef,
        data_buffer: CMBlockBufferRef,
        data_ready: Boolean,
        make_data_ready_callback: *const c_void,
        make_data_ready_refcon: *mut c_void,
        format_description: CMFormatDescriptionRef,
        num_samples: CMItemCount,
        num_timing_entries: CMItemCount,
        timing_array: *const CMSampleTimingInfo,
        num_size_entries: CMItemCount,
        size_array: *const usize,
        sample_buffer_out: *mut CMSampleBufferRef,
    ) -> OSStatus;
}

#[link(name = "VideoToolbox", kind = "framework")]
extern "C" {
    fn VTDecompressionSessionCreate(
        allocator: CFAllocatorRef,
        format_description: CMFormatDescriptionRef,
        video_decoder_spec: *const c_void,
        image_buffer_attrs: *const c_void,
        output_callback: *const VTDecompressionOutputCallbackRecord,
        session_out: *mut VTDecompressionSessionRef,
    ) -> OSStatus;

    fn VTDecompressionSessionDecodeFrame(
        session: VTDecompressionSessionRef,
        sample_buffer: CMSampleBufferRef,
        decode_flags: VTDecodeFrameFlags,
        source_frame_ref_con: *mut c_void,
        info_flags_out: *mut VTDecodeInfoFlags,
    ) -> OSStatus;

    fn VTDecompressionSessionInvalidate(session: VTDecompressionSessionRef);
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(cf: CFTypeRef);
}

#[link(name = "CoreVideo", kind = "framework")]
extern "C" {
    fn CVPixelBufferLockBaseAddress(pixel_buffer: CVPixelBufferRef, lock_flags: CVOptionFlags) -> i32;
    fn CVPixelBufferUnlockBaseAddress(pixel_buffer: CVPixelBufferRef, lock_flags: CVOptionFlags) -> i32;
    fn CVPixelBufferGetWidth(pixel_buffer: CVPixelBufferRef) -> usize;
    fn CVPixelBufferGetHeight(pixel_buffer: CVPixelBufferRef) -> usize;
    fn CVPixelBufferGetBaseAddressOfPlane(pixel_buffer: CVPixelBufferRef, plane_index: usize) -> *mut c_void;
    fn CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer: CVPixelBufferRef, plane_index: usize) -> usize;
    fn CVPixelBufferGetPlaneCount(pixel_buffer: CVPixelBufferRef) -> usize;
}

// ──────────────────────── Decoder Context ────────────────────────

struct DecoderCtx {
    tx: SyncSender<Result<DecodedFrame, String>>,
}

/// VT 回调：从 CVPixelBuffer（NV12）提取帧并发送到 Rust 通道
unsafe extern "C" fn vt_callback(
    refcon: *mut c_void,
    _source_ref: *mut c_void,
    status: OSStatus,
    _info_flags: VTDecodeInfoFlags,
    image_buffer: CVPixelBufferRef,
    _pts: CMTime,
    _duration: CMTime,
) {
    let ctx = &*(refcon as *const DecoderCtx);

    if status != 0 {
        ctx.tx.try_send(Err(format!("VTDecode error: {}", status))).ok();
        return;
    }
    if image_buffer.is_null() {
        ctx.tx.try_send(Err("null image buffer".to_string())).ok();
        return;
    }

    // 获取帧尺寸（不锁定像素数据）
    let width = CVPixelBufferGetWidth(image_buffer) as u32;
    let height = CVPixelBufferGetHeight(image_buffer) as u32;
    if width == 0 || height == 0 {
        ctx.tx.try_send(Err(format!("zero dimensions {}x{}", width, height))).ok();
        return;
    }

    CVPixelBufferLockBaseAddress(image_buffer, KCV_PIXEL_BUFFER_LOCK_READ_ONLY);

    let plane_count = CVPixelBufferGetPlaneCount(image_buffer);
    if plane_count < 2 {
        CVPixelBufferUnlockBaseAddress(image_buffer, KCV_PIXEL_BUFFER_LOCK_READ_ONLY);
        ctx.tx.try_send(Err(format!("not NV12: plane_count={}", plane_count))).ok();
        return;
    }

    // Y plane
    let y_stride = CVPixelBufferGetBytesPerRowOfPlane(image_buffer, 0);
    let y_ptr = CVPixelBufferGetBaseAddressOfPlane(image_buffer, 0) as *const u8;
    // UV plane (NV12 interleaved U、V)
    let uv_stride = CVPixelBufferGetBytesPerRowOfPlane(image_buffer, 1);
    let uv_ptr = CVPixelBufferGetBaseAddressOfPlane(image_buffer, 1) as *const u8;

    if y_ptr.is_null() || uv_ptr.is_null() {
        CVPixelBufferUnlockBaseAddress(image_buffer, KCV_PIXEL_BUFFER_LOCK_READ_ONLY);
        ctx.tx.try_send(Err("null plane pointer".to_string())).ok();
        return;
    }

    // Copy Y
    let w = width as usize;
    let h = height as usize;
    let ch = h / 2;
    let cw = w / 2;
    let mut y_plane = Vec::with_capacity(w * h);
    for row in 0..h {
        let row_ptr = y_ptr.add(row * y_stride);
        y_plane.extend_from_slice(std::slice::from_raw_parts(row_ptr, w));
    }

    // Copy UV → split into I420 U/V planes
    let mut u_plane = Vec::with_capacity(cw * ch);
    let mut v_plane = Vec::with_capacity(cw * ch);
    for row in 0..ch {
        let row_ptr = uv_ptr.add(row * uv_stride);
        let uv = std::slice::from_raw_parts(row_ptr, cw * 2);
        for i in 0..cw {
            u_plane.push(uv[i * 2]);
            v_plane.push(uv[i * 2 + 1]);
        }
    }

    CVPixelBufferUnlockBaseAddress(image_buffer, KCV_PIXEL_BUFFER_LOCK_READ_ONLY);

    ctx.tx.try_send(Ok(DecodedFrame { width, height, y_plane, u_plane, v_plane })).ok();
}

// ──────────────────────── Public API ────────────────────────

pub struct VtbDecoder {
    session: VTDecompressionSessionRef,
    format_desc: CMFormatDescriptionRef,
    rx: Receiver<Result<DecodedFrame, String>>,
    // Keep ctx alive for the life of the session
    _ctx: Box<DecoderCtx>,
    // Keep callback record's refcon valid
    _callback_record_storage: Box<VTDecompressionOutputCallbackRecord>,
}

// Safety: VtbDecoder is used from a single thread after construction.
unsafe impl Send for VtbDecoder {}

impl VtbDecoder {
    /// 用 SPS 和 PPS 初始化解码器（来自 0x02 视频配置包）
    pub fn new(sps: &[u8], pps: &[u8]) -> Result<Self> {
        unsafe {
            let sps_ptr = sps.as_ptr();
            let pps_ptr = pps.as_ptr();
            let param_ptrs = [sps_ptr, pps_ptr];
            let param_sizes = [sps.len(), pps.len()];

            let mut format_desc: CMFormatDescriptionRef = null::<c_void>() as *mut _;
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                null(),
                2,
                param_ptrs.as_ptr(),
                param_sizes.as_ptr(),
                4, // AVCC uses 4-byte length prefix
                &mut format_desc,
            );
            if status != 0 || format_desc.is_null() {
                return Err(anyhow!("CMVideoFormatDescriptionCreate failed: {}", status));
            }

            let (tx, rx) = sync_channel::<Result<DecodedFrame, String>>(4);
            let ctx = Box::new(DecoderCtx { tx });
            let ctx_ptr = ctx.as_ref() as *const DecoderCtx as *mut c_void;

            let callback_record = Box::new(VTDecompressionOutputCallbackRecord {
                callback: vt_callback,
                refcon: ctx_ptr,
            });

            let mut session: VTDecompressionSessionRef = null::<c_void>() as *mut _;
            let status = VTDecompressionSessionCreate(
                null(),
                format_desc,
                null(),
                null(),
                callback_record.as_ref() as *const _,
                &mut session,
            );
            if status != 0 {
                CFRelease(format_desc as CFTypeRef);
                return Err(anyhow!("VTDecompressionSessionCreate failed: {}", status));
            }

            Ok(VtbDecoder {
                session,
                format_desc,
                rx,
                _ctx: ctx,
                _callback_record_storage: callback_record,
            })
        }
    }

    /// 解码一帧 Annex-B H.264 NAL 数据，返回 I420 帧
    pub fn decode_frame(&self, annex_b: &[u8]) -> Result<DecodedFrame> {
        let avcc_data = annex_b_to_avcc(annex_b);
        if avcc_data.is_empty() {
            return Err(anyhow!("empty AVCC data after conversion"));
        }

        unsafe {
            let data_len = avcc_data.len();

            // 用 malloc 分配数据，传 null()（kCFAllocatorDefault）作为 block allocator。
            // CF 最终会用 free() 释放该内存，与 malloc 兼容。
            // 不能用 Vec 的原始指针 + 假 kCFAllocatorNull，那会导致 SIGBUS。
            let avcc_ptr = malloc(data_len);
            if avcc_ptr.is_null() {
                return Err(anyhow!("malloc failed for AVCC data ({} bytes)", data_len));
            }
            std::ptr::copy_nonoverlapping(avcc_data.as_ptr(), avcc_ptr as *mut u8, data_len);

            // CMBlockBuffer wrapping malloc'd AVCC bytes
            // null() as blockAllocator = kCFAllocatorDefault → CF will call free() on avcc_ptr
            let mut block_buf: CMBlockBufferRef = null::<c_void>() as *mut _;
            let status = CMBlockBufferCreateWithMemoryBlock(
                null(),     // structureAllocator (default)
                avcc_ptr,   // memoryBlock (malloc-owned)
                data_len,
                null(),     // blockAllocator = kCFAllocatorDefault → CF will free it
                null(),     // customBlockSource
                0,          // offsetToData
                data_len,
                0,          // flags
                &mut block_buf,
            );
            if status != 0 {
                // avcc_ptr was NOT transferred to block_buf; free it manually
                libc_free(avcc_ptr);
                return Err(anyhow!("CMBlockBufferCreate failed: {}", status));
            }

            let timing = CMSampleTimingInfo {
                duration: KCM_TIME_INVALID,
                presentation_time_stamp: KCM_TIME_ZERO,
                decode_time_stamp: KCM_TIME_INVALID,
            };
            let sample_size = data_len;

            let mut sample_buf: CMSampleBufferRef = null::<c_void>() as *mut _;
            let status = CMSampleBufferCreate(
                null(),          // allocator
                block_buf,
                1u8,             // dataReady = true
                null(),          // makeDataReadyCallback
                null::<c_void>() as *mut _,
                self.format_desc,
                1,               // numSamples
                1,               // numSampleTimingEntries
                &timing,
                1,               // numSampleSizeEntries
                &sample_size,
                &mut sample_buf,
            );
            CFRelease(block_buf as CFTypeRef);  // sample_buf now owns block_buf

            if status != 0 {
                return Err(anyhow!("CMSampleBufferCreate failed: {}", status));
            }

            let mut info_flags: VTDecodeInfoFlags = 0;
            let status = VTDecompressionSessionDecodeFrame(
                self.session,
                sample_buf,
                0, // synchronous decode
                null::<c_void>() as *mut _,
                &mut info_flags,
            );
            CFRelease(sample_buf as CFTypeRef);

            if status != 0 {
                return Err(anyhow!("VTDecompressionSessionDecodeFrame failed: {}", status));
            }

            // 同步解码：回调在 DecodeFrame 返回前触发
            self.rx
                .recv_timeout(std::time::Duration::from_millis(500))
                .map_err(|_| anyhow!("decode callback timeout"))?
                .map_err(|e| anyhow!(e))
        }
    }
}

impl Drop for VtbDecoder {
    fn drop(&mut self) {
        unsafe {
            VTDecompressionSessionInvalidate(self.session);
            CFRelease(self.session as CFTypeRef);
            CFRelease(self.format_desc as CFTypeRef);
        }
    }
}

// ──────────────────────── Annex-B → AVCC ────────────────────────

/// 将 Annex-B H.264 字节流转换为 AVCC 格式（替换 start code 为 4B 大端长度）
fn annex_b_to_avcc(data: &[u8]) -> Vec<u8> {
    let mut result = Vec::new();
    let mut pos = 0;
    let len = data.len();

    while pos < len {
        // 跳过前置 start code
        let nal_start = if pos + 3 < len && data[pos..pos + 4] == [0, 0, 0, 1] {
            pos + 4
        } else if pos + 2 < len && data[pos..pos + 3] == [0, 0, 1] {
            pos + 3
        } else {
            pos += 1;
            continue;
        };

        // 找下一个 start code 或数据末尾
        let mut nal_end = len;
        let mut scan = nal_start + 1;
        while scan + 2 < len {
            if data[scan..scan + 3] == [0, 0, 1]
                || (scan + 3 < len && data[scan..scan + 4] == [0, 0, 0, 1])
            {
                nal_end = scan;
                break;
            }
            scan += 1;
        }

        let nal = &data[nal_start..nal_end];
        let nal_len = nal.len() as u32;
        result.extend_from_slice(&nal_len.to_be_bytes());
        result.extend_from_slice(nal);
        pos = nal_end;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_annex_b_to_avcc_4byte_sc() {
        // 4-byte start code + 3 bytes NAL
        let input = vec![0, 0, 0, 1, 0x65, 0xAB, 0xCD];
        let out = annex_b_to_avcc(&input);
        assert_eq!(out, vec![0, 0, 0, 3, 0x65, 0xAB, 0xCD]);
    }

    #[test]
    fn test_annex_b_to_avcc_3byte_sc() {
        let input = vec![0, 0, 1, 0x41, 0x9B];
        let out = annex_b_to_avcc(&input);
        assert_eq!(out, vec![0, 0, 0, 2, 0x41, 0x9B]);
    }

    #[test]
    fn test_annex_b_multiple_nals() {
        let input = vec![
            0, 0, 0, 1, 0x67, 0xAA, // NAL 1: SPS
            0, 0, 0, 1, 0x68, 0xBB, // NAL 2: PPS
        ];
        let out = annex_b_to_avcc(&input);
        assert_eq!(out.len(), 4 + 2 + 4 + 2); // 2 NALs each with 4B length prefix
        assert_eq!(&out[0..4], &[0, 0, 0, 2]);
        assert_eq!(&out[4..6], &[0x67, 0xAA]);
        assert_eq!(&out[6..10], &[0, 0, 0, 2]);
        assert_eq!(&out[10..12], &[0x68, 0xBB]);
    }
}
