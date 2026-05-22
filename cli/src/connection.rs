use anyhow::{anyhow, Context, Result};
use byteorder::{BigEndian, ReadBytesExt};
use std::io::{Read, Write};

/// 协议帧类型
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FrameType {
    Heartbeat  = 0x01,
    VideoConfig = 0x02,
    VideoFrame  = 0x03,
    Control     = 0x10,
    DeviceState = 0x20,
}

impl FrameType {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0x01 => Some(Self::Heartbeat),
            0x02 => Some(Self::VideoConfig),
            0x03 => Some(Self::VideoFrame),
            0x10 => Some(Self::Control),
            0x20 => Some(Self::DeviceState),
            _ => None,
        }
    }
}

/// 解析后的视频配置（来自 0x02 包）
#[derive(Debug, Clone)]
pub struct VideoConfig {
    pub codec: u8,   // 0=H264, 1=RawRGBA, 2=JPEG
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
}

/// 解析后的视频帧（来自 0x03 包）
#[derive(Debug, Clone)]
pub struct VideoFrame {
    pub is_keyframe: bool,
    pub pts: u64,
    pub data: Vec<u8>, // Annex-B NAL
}

/// 从 TCP 流读取一个协议帧，返回 (type_byte, payload)
pub fn read_frame<R: Read>(reader: &mut R) -> Result<(u8, Vec<u8>)> {
    // 帧头：type[4B] + length[4B BE]
    let mut header = [0u8; 8];
    reader.read_exact(&mut header).context("reading frame header")?;

    let frame_type = header[3]; // type 是 4B BE，低字节（header[3]）是实际类型值
    // header[1..3] 应为 0，忽略
    let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;

    let mut payload = vec![0u8; length];
    if length > 0 {
        reader.read_exact(&mut payload).context("reading frame payload")?;
    }
    Ok((frame_type, payload))
}

/// 向 TCP 流写入一个协议帧
pub fn write_frame<W: Write>(writer: &mut W, frame_type: u8, payload: &[u8]) -> Result<()> {
    let mut header = [0u8; 8];
    // type 是 4B BE，低字节（header[3]）写入类型值
    header[3] = frame_type;
    let length = payload.len() as u32;
    header[4..8].copy_from_slice(&length.to_be_bytes());
    writer.write_all(&header).context("writing frame header")?;
    if !payload.is_empty() {
        writer.write_all(payload).context("writing frame payload")?;
    }
    Ok(())
}

/// 从 0x02 包 payload 解析视频配置
/// 格式: codec(1) width(4) height(4) fps(4) [spsLen(2) sps ppsLen(2) pps]
pub fn parse_video_config(payload: &[u8]) -> Result<VideoConfig> {
    if payload.len() < 13 {
        return Err(anyhow!("video config payload too short: {} bytes", payload.len()));
    }
    let mut cur = payload;
    let codec  = cur.read_u8()?;
    let width  = cur.read_u32::<BigEndian>()?;
    let height = cur.read_u32::<BigEndian>()?;
    let fps    = cur.read_u32::<BigEndian>()?;

    // RAW RGBA / JPEG 无 SPS/PPS 字段
    if codec == 1 || codec == 2 {
        return Ok(VideoConfig { codec, width, height, fps, sps: vec![], pps: vec![] });
    }

    // H264: spsLen(2) + sps + ppsLen(2) + pps
    let sps_len = cur.read_u16::<BigEndian>()? as usize;
    if cur.len() < sps_len + 2 {
        return Err(anyhow!("video config truncated at SPS"));
    }
    let sps = cur[..sps_len].to_vec();
    cur = &cur[sps_len..];

    let pps_len = cur.read_u16::<BigEndian>()? as usize;
    if cur.len() < pps_len {
        return Err(anyhow!("video config truncated at PPS"));
    }
    let pps = cur[..pps_len].to_vec();

    Ok(VideoConfig { codec, width, height, fps, sps, pps })
}

/// 从 0x03 包 payload 解析视频帧
pub fn parse_video_frame(payload: &[u8]) -> Result<VideoFrame> {
    if payload.len() < 9 {
        return Err(anyhow!("video frame payload too short: {} bytes", payload.len()));
    }
    let flags = payload[0];
    let is_keyframe = (flags & 0x01) != 0;
    let pts = u64::from_be_bytes(payload[1..9].try_into().unwrap());
    let data = payload[9..].to_vec();
    Ok(VideoFrame { is_keyframe, pts, data })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_frame_roundtrip_heartbeat() {
        let mut buf = Vec::new();
        write_frame(&mut buf, 0x01, &[]).unwrap();
        assert_eq!(buf.len(), 8);
        let mut cur = Cursor::new(&buf);
        let (t, p) = read_frame(&mut cur).unwrap();
        assert_eq!(t, 0x01);
        assert_eq!(p, &[] as &[u8]);
    }

    #[test]
    fn test_frame_roundtrip_with_payload() {
        let payload = vec![1u8, 2, 3, 4, 5];
        let mut buf = Vec::new();
        write_frame(&mut buf, 0x10, &payload).unwrap();
        let mut cur = Cursor::new(&buf);
        let (t, p) = read_frame(&mut cur).unwrap();
        assert_eq!(t, 0x10);
        assert_eq!(p, payload);
    }

    #[test]
    fn test_parse_video_frame() {
        let mut p = vec![0x01u8]; // flags: keyframe
        p.extend_from_slice(&100u64.to_be_bytes()); // pts
        p.extend_from_slice(&[0, 0, 0, 1, 0x65]); // NAL data
        let vf = parse_video_frame(&p).unwrap();
        assert!(vf.is_keyframe);
        assert_eq!(vf.pts, 100);
        assert_eq!(vf.data, &[0, 0, 0, 1, 0x65]);
    }

    #[test]
    fn test_parse_video_config() {
        let mut payload = Vec::new();
        payload.push(0x00u8);  // codec: H264
        payload.extend_from_slice(&1080u32.to_be_bytes()); // width
        payload.extend_from_slice(&2340u32.to_be_bytes()); // height
        payload.extend_from_slice(&60u32.to_be_bytes());   // fps
        let sps = vec![0x67u8, 0x42, 0x80, 0x1e]; // fake SPS
        payload.extend_from_slice(&(sps.len() as u16).to_be_bytes());
        payload.extend_from_slice(&sps);
        let pps = vec![0x68u8, 0xce]; // fake PPS
        payload.extend_from_slice(&(pps.len() as u16).to_be_bytes());
        payload.extend_from_slice(&pps);

        let cfg = parse_video_config(&payload).unwrap();
        assert_eq!(cfg.codec, 0);
        assert_eq!(cfg.width, 1080);
        assert_eq!(cfg.height, 2340);
        assert_eq!(cfg.fps, 60);
        assert_eq!(cfg.sps, sps);
        assert_eq!(cfg.pps, pps);
    }
}
