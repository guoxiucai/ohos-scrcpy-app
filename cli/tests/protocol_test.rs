use std::io::Cursor;
use ohscrcpy::connection::*;

#[test]
fn test_heartbeat_roundtrip() {
    let mut buf = Vec::new();
    write_frame(&mut buf, 0x01, &[]).unwrap();
    assert_eq!(buf.len(), 8, "heartbeat frame should be 8 bytes");
    let mut cur = Cursor::new(&buf);
    let (t, p) = read_frame(&mut cur).unwrap();
    assert_eq!(t, 0x01);
    assert!(p.is_empty());
}

#[test]
fn test_control_frame_roundtrip() {
    let payload = vec![0x01u8, 0x3f, 0x80, 0x00, 0x00, 0x3f, 0x80, 0x00, 0x00, 0x00, 0x00];
    let mut buf = Vec::new();
    write_frame(&mut buf, 0x10, &payload).unwrap();
    let mut cur = Cursor::new(&buf);
    let (t, p) = read_frame(&mut cur).unwrap();
    assert_eq!(t, 0x10);
    assert_eq!(p, payload);
}

#[test]
fn test_video_frame_parsing() {
    let mut payload = vec![0x01u8]; // keyframe flag
    payload.extend_from_slice(&12345u64.to_be_bytes());
    payload.extend_from_slice(&[0, 0, 0, 1, 0x65, 0xAA]);
    let vf = parse_video_frame(&payload).unwrap();
    assert!(vf.is_keyframe);
    assert_eq!(vf.pts, 12345);
    assert_eq!(vf.data, &[0, 0, 0, 1, 0x65, 0xAA]);
}

#[test]
fn test_video_config_parsing() {
    let mut p = Vec::new();
    p.push(0x00u8);  // codec: H264
    p.extend_from_slice(&1920u32.to_be_bytes());
    p.extend_from_slice(&1080u32.to_be_bytes());
    p.extend_from_slice(&30u32.to_be_bytes());
    let sps = [0x67u8, 0x64, 0x00, 0x28];
    let pps = [0x68u8, 0xEB, 0xEC, 0xB2];
    p.extend_from_slice(&(sps.len() as u16).to_be_bytes());
    p.extend_from_slice(&sps);
    p.extend_from_slice(&(pps.len() as u16).to_be_bytes());
    p.extend_from_slice(&pps);
    let cfg = parse_video_config(&p).unwrap();
    assert_eq!(cfg.codec, 0);
    assert_eq!(cfg.width, 1920);
    assert_eq!(cfg.height, 1080);
    assert_eq!(cfg.fps, 30);
    assert_eq!(cfg.sps, sps);
    assert_eq!(cfg.pps, pps);
}

#[test]
fn test_frame_type_enum() {
    assert_eq!(FrameType::from_u8(0x01), Some(FrameType::Heartbeat));
    assert_eq!(FrameType::from_u8(0x02), Some(FrameType::VideoConfig));
    assert_eq!(FrameType::from_u8(0x03), Some(FrameType::VideoFrame));
    assert_eq!(FrameType::from_u8(0x10), Some(FrameType::Control));
    assert_eq!(FrameType::from_u8(0xFF), None);
}

#[test]
fn test_large_payload_roundtrip() {
    let payload = vec![0xABu8; 65536];
    let mut buf = Vec::new();
    write_frame(&mut buf, 0x03, &payload).unwrap();
    let mut cur = Cursor::new(&buf);
    let (t, p) = read_frame(&mut cur).unwrap();
    assert_eq!(t, 0x03);
    assert_eq!(p.len(), 65536);
}
