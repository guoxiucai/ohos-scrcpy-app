/// 解码后的视频帧（I420 格式）
#[derive(Debug, Clone)]
pub struct DecodedFrame {
    pub width: u32,
    pub height: u32,
    pub y_plane: Vec<u8>,
    pub u_plane: Vec<u8>,
    pub v_plane: Vec<u8>,
}

/// 将 NV12（YUV 4:2:0 semi-planar）转换为 I420（YUV 4:2:0 planar）
///
/// NV12: Y 平面 + 交错 UV 平面 (UVUVUV...)
/// I420: Y 平面 + U 平面 + V 平面（分离）
pub fn nv12_to_i420(
    y_data: &[u8],
    uv_data: &[u8],
    width: u32,
    height: u32,
) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let y_plane = y_data.to_vec();

    let chroma_samples = (width as usize / 2) * (height as usize / 2);
    let mut u_plane = Vec::with_capacity(chroma_samples);
    let mut v_plane = Vec::with_capacity(chroma_samples);

    for chunk in uv_data.chunks_exact(2) {
        u_plane.push(chunk[0]);
        v_plane.push(chunk[1]);
    }

    (y_plane, u_plane, v_plane)
}

#[cfg(target_os = "macos")]
pub mod vtb;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_nv12_to_i420() {
        // 2x2 image: Y=4 bytes, UV=2 bytes
        let y = vec![10u8, 20, 30, 40];
        let uv = vec![100u8, 200]; // U=100, V=200 for the single chroma sample
        let (y_out, u_out, v_out) = nv12_to_i420(&y, &uv, 2, 2);
        assert_eq!(y_out, vec![10, 20, 30, 40]);
        assert_eq!(u_out, vec![100]);
        assert_eq!(v_out, vec![200]);
    }
}
